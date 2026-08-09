#!/usr/bin/env python3
"""nv_index.py -- indexador semantico de Kai Vault (reescrito 2026-07-26).

Por que se reescribio: nv-index.sh/nv-search.sh se perdieron en el decomisionado del ecosistema
`nv` (2026-07-17), pero capabilities/boveda.sh los siguio llamando. Resultado: Kai Vault paso 8
dias devolviendo "no encontre nada" y reportando "Listo" cada vez que el watcher lo reindexaba.
El indice viejo que sobrevivio no se pudo reusar: apuntaba a rutas de antes de la migracion
(mentis-app\\renderer\\...) y tenia 112 chunks de package-lock.json, puro ruido.

Va en un.py aparte (y no embebido en el.sh como el resto del ecosistema) porque el chunking,
el batching y el indice incremental no entran de forma sana en un `python3 -c`, y porque asi se
puede testear la logica directamente.

Formato del indice (JSONL, una linea por chunk):
    {"file": "ruta/relativa", "line": 12, "text": "...", "fhash": "sha1", "vec": [1024 floats]}

`fhash` es lo que hace posible el modo incremental: si el archivo no cambio, sus chunks se
copian tal cual y no se vuelve a pagar el embedding.
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

EMB_URL = os.environ.get("NV_EMB_URL", "https://integrate.api.nvidia.com/v1/embeddings")

# Extensiones que vale la pena indexar. Todo lo demas se ignora: un.png o un.zip no aportan
# nada a una busqueda semantica y solo hacen mas lento el recorrido.
EXT_DEFECTO = {
    ".sh", ".bash", ".py", ".js", ".mjs", ".cjs", ".ts", ".json", ".md", ".txt",
    ".html", ".css", ".ps1", ".yml", ".yaml", ".jsonl", ".ino", ".sql",
}

# Carpetas que NUNCA se indexan. node_modules es 624 de los 629 MB de Mentis;.git ya no existe
# pero se deja por si vuelve; los respaldos se excluyen para no indexar copias de uno mismo.
DIRS_EXCLUIDOS = {
    "node_modules", ".git", "__pycache__", ".venv", "venv", "dist", "build",
    "index", "logs", "Mentis-Respaldos", ".pytest_cache", "browser-server",
}

# Archivos concretos que son ruido puro. package-lock.json es el caso testigo: 112 chunks del
# indice viejo eran de ese archivo, y ninguna busqueda util lo necesita.
ARCHIVOS_EXCLUIDOS = {
    "package-lock.json", "location-cache.json", "kai-vault-watch.log",
    ".nv-secrets", ".secrets.env", "quality.jsonl", "nv.jsonl",
    # El banco de pruebas contiene las 15 consultas de evaluacion en texto plano. Indexarlo
    # contamina la medicion (gana siempre por coincidencia lexica perfecta consigo mismo) y
    # tambien ensucia las busquedas reales, porque son frases muy "consultables" que no
    # describen ninguna funcionalidad. Detectado midiendo: el bench se ganaba a si mismo.
    "bench-embeddings.sh", "bench-embeddings-resultado.md",
}

MAX_BYTES_ARCHIVO = 1_000_000   # un archivo de mas de 1 MB es generado o datos, no algo a buscar


def _es_secreto(nombre: str) -> bool:
    """Nunca indexar secretos: irian a parar al endpoint de embeddings en texto plano."""
    bajo = nombre.lower()
    return (
        bajo.endswith(".env")
        or bajo.startswith(".env")
        or "secret" in bajo
        or bajo.endswith(".pem")
        or bajo.endswith(".key")
    )


def listar_archivos(raices, extensiones):
    vistos = set()
    for raiz in raices:
        raiz = os.path.abspath(raiz)
        if not os.path.isdir(raiz):
            continue
        for dirpath, dirnames, filenames in os.walk(raiz):
            dirnames[:] = [d for d in dirnames if d not in DIRS_EXCLUIDOS and not d.startswith(".")]
            for fn in filenames:
                if fn in ARCHIVOS_EXCLUIDOS or _es_secreto(fn):
                    continue
                ext = os.path.splitext(fn)[1].lower()
                if ext not in extensiones:
                    continue
                full = os.path.join(dirpath, fn)
                try:
                    if os.path.getsize(full) > MAX_BYTES_ARCHIVO:
                        continue
                except OSError:
                    continue
                if full not in vistos:
                    vistos.add(full)
                    yield full, raiz


def hash_archivo(ruta):
    h = hashlib.sha1()
    try:
        with open(ruta, "rb") as f:
            for bloque in iter(lambda: f.read(65536), b""):
                h.update(bloque)
    except OSError:
        return None
    return h.hexdigest()


def chunkear(texto, max_chars=1800, lineas_solape=8):
    """Trocea por lineas, no por caracteres sueltos, para que un chunk nunca corte una linea al
    medio y el numero de linea que se reporta sea real y clickeable.

    El solape existe para que una funcion que cae justo en el borde entre dos chunks siga siendo
    encontrable: sin el, la mitad de su cuerpo queda en un chunk y la firma en otro."""
    lineas = texto.splitlines()
    chunks, actual, inicio, tam = [], [], 1, 0
    for i, ln in enumerate(lineas, start=1):
        if actual and tam + len(ln) > max_chars:
            chunks.append((inicio, "\n".join(actual)))
            solape = actual[-lineas_solape:] if lineas_solape else []
            inicio = max(1, i - len(solape))
            actual = list(solape)
            tam = sum(len(x) for x in actual)
        if not actual:
            inicio = i
        actual.append(ln)
        tam += len(ln)
    if actual and "".join(actual).strip():
        chunks.append((inicio, "\n".join(actual)))
    return [(n, t) for n, t in chunks if t.strip()]


def embeber(textos, modelo, api_key, input_type="passage", reintentos=3):
    """Un lote de textos -> lista de vectores.

    Si el lote entero falla por culpa de UN texto, se reintenta de a uno y el problematico se
    reemplaza por un vector nulo en vez de tumbar el indexado completo. Caso real que motivo
    esto: nemotron-3-embed-1b es multimodal y algun chunk de Mentis (el protocolo de tools usa
    base64) lo hizo responder "image inputs require VLM serving", matando la corrida entera a
    mitad de camino."""
    try:
        return _embeber_lote(textos, modelo, api_key, input_type, reintentos)
    except RuntimeError:
        if len(textos) == 1:
            raise
        salida = []
        for t in textos:
            try:
                salida.extend(_embeber_lote([t], modelo, api_key, input_type, reintentos))
            except RuntimeError as e:
                print("AVISO: se saltea un fragmento que la API rechazo (%s)" % str(e)[:90],
                      file=sys.stderr)
                salida.append(None)
        return salida


def _embeber_lote(textos, modelo, api_key, input_type="passage", reintentos=3):
    """Reintenta con espera creciente: la API corta con 429 si se le pega muy seguido, y un
    indexado completo son cientos de llamadas."""
    payload = {"model": modelo, "input": textos, "input_type": input_type,
               "encoding_format": "float", "truncate": "END"}
    datos = json.dumps(payload).encode("utf-8")
    ultimo_error = ""
    for intento in range(reintentos):
        req = urllib.request.Request(
            EMB_URL, data=datos,
            headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json",
                     "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                cuerpo = json.loads(resp.read().decode("utf-8"))
            return [d["embedding"] for d in cuerpo["data"]]
        except urllib.error.HTTPError as e:
            try:
                ultimo_error = e.read().decode("utf-8")[:200]
            except Exception:
                ultimo_error = str(e)
            if e.code in (429, 500, 502, 503, 504) and intento < reintentos - 1:
                time.sleep(2 ** intento * 2)
                continue
            raise RuntimeError("la API de embeddings respondio %s: %s" % (e.code, ultimo_error))
        except Exception as e:
            ultimo_error = str(e)
            if intento < reintentos - 1:
                time.sleep(2 ** intento * 2)
                continue
            raise RuntimeError("no se pudo hablar con la API de embeddings: %s" % ultimo_error)
    raise RuntimeError("embeddings fallaron tras %d intentos: %s" % (reintentos, ultimo_error))


def ruta_vecs(ruta_jsonl):
    """Los vectores van en un binario aparte, no dentro del JSONL.

    Medido: con los vectores embebidos, cada busqueda tardaba ~3.9 s, y casi todo era parsear
    20 MB de JSON para leer 905 chunks. Con numpy el mismo indice se carga de una y el coseno
    se hace vectorizado contra toda la matriz. El JSONL queda liviano y legible (sirve para
    inspeccionarlo a mano), y el.npy guarda lo pesado en float32."""
    return os.path.splitext(ruta_jsonl)[0] + ".vecs.npy"


def cargar_indice_previo(ruta):
    """Devuelve {(file, fhash): [(meta, vec)]} de lo ya indexado, para no re-embeber lo que no
    cambio. Si el.npy y el.jsonl no coinciden en cantidad, se descarta el indice previo entero
    (es preferible pagar un reindexado completo a mezclar vectores con metadatos equivocados)."""
    por_hash = {}
    if not os.path.exists(ruta):
        return por_hash
    metas = []
    try:
        with open(ruta, encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    metas.append(json.loads(ln))
                except Exception:
                    return {}   # una linea corrupta invalida el pareo por posicion
    except OSError:
        return {}

    vecs = None
    pv = ruta_vecs(ruta)
    if os.path.exists(pv):
        try:
            import numpy as np
            vecs = np.load(pv)
        except Exception:
            vecs = None
    if vecs is None or len(vecs) != len(metas):
        return {}

    for i, d in enumerate(metas):
        clave = (d.get("file"), d.get("fhash"))
        if clave[0] and clave[1]:
            por_hash.setdefault(clave, []).append((d, vecs[i]))
    return por_hash


def main():
    ap = argparse.ArgumentParser(description="Indexa carpetas para la busqueda semantica de Kai Vault")
    ap.add_argument("raices", nargs="+", help="carpetas a indexar")
    ap.add_argument("-o", "--salida", required=True, help="archivo.jsonl del indice")
    ap.add_argument("-m", "--modelo", default="nvidia/nv-embedqa-e5-v5")
    ap.add_argument("-x", "--extensiones", default="", help='extensiones extra, ej: "md txt"')
    ap.add_argument("-b", "--lote", type=int, default=16)
    ap.add_argument("--completo", action="store_true", help="ignora el indice previo y re-embebe todo")
    args = ap.parse_args()

    api_key = os.environ.get("NVIDIA_API_KEY", "").strip()
    if not api_key:
        print("ERROR: falta NVIDIA_API_KEY en el entorno", file=sys.stderr)
        return 2

    extensiones = set(EXT_DEFECTO)
    for e in args.extensiones.split():
        extensiones.add(e if e.startswith(".") else "." + e)

    try:
        import numpy as np
    except ImportError:
        print("ERROR: falta numpy (pip install numpy)", file=sys.stderr)
        return 2

    previo = {} if args.completo else cargar_indice_previo(args.salida)
    os.makedirs(os.path.dirname(os.path.abspath(args.salida)) or ".", exist_ok=True)

    metas = []        # dicts sin vector, en el MISMO orden que la matriz
    vectores = []
    reusados = nuevos = archivos = salteados = 0
    pendientes = []   # (file_rel, linea, texto, fhash)

    def volcar(lote):
        nonlocal nuevos, salteados
        if not lote:
            return
        vecs = embeber([t for _, _, t, _ in lote], args.modelo, api_key)
        for (rel, linea, texto, fh), vec in zip(lote, vecs):
            if vec is None:      # la API rechazo ese fragmento puntual
                salteados += 1
                continue
            metas.append({"file": rel, "line": linea, "text": texto, "fhash": fh})
            vectores.append(vec)
            nuevos += 1

    for full, raiz in listar_archivos(args.raices, extensiones):
        fh = hash_archivo(full)
        if not fh:
            continue
        archivos += 1
        rel = os.path.relpath(full, raiz).replace("\\", "/")
        cacheados = previo.get((rel, fh))
        if cacheados:
            for meta, vec in cacheados:
                metas.append(meta)
                vectores.append(vec)
                reusados += 1
            continue
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                contenido = f.read()
        except OSError:
            continue
        for linea, texto in chunkear(contenido):
            pendientes.append((rel, linea, texto, fh))
            if len(pendientes) >= args.lote:
                volcar(pendientes)
                pendientes = []
    volcar(pendientes)

    if not metas:
        print("ERROR: no se indexo ningun chunk (revisa las rutas)", file=sys.stderr)
        return 1

    # Reemplazo ATOMICO de los DOS archivos. Si el proceso muere a mitad, el indice viejo sigue
    # entero y consistente. Sin esto, un corte dejaba a Kai Vault con un indice truncado -- roto
    # en silencio, que es exactamente el bug que este trabajo viene a cerrar. El.npy se escribe
    # y renombra primero: si algo falla entre medio, el.jsonl viejo con su.npy viejo sigue
    # siendo un par valido, y la validacion por cantidad de cargar_indice_previo lo detecta.
    salida_tmp = args.salida + ".tmp"
    vecs_tmp = ruta_vecs(args.salida) + ".tmp"
    np.save(vecs_tmp, np.asarray(vectores, dtype="float32"), allow_pickle=False)
    with open(salida_tmp, "w", encoding="utf-8") as out:
        for d in metas:
            out.write(json.dumps(d, ensure_ascii=False) + "\n")
    os.replace(vecs_tmp + ".npy" if os.path.exists(vecs_tmp + ".npy") else vecs_tmp,
               ruta_vecs(args.salida))
    os.replace(salida_tmp, args.salida)

    extra = " salteados=%d" % salteados if salteados else ""
    print("OK indice=%s archivos=%d chunks=%d nuevos=%d reusados=%d%s modelo=%s"
          % (args.salida, archivos, len(metas), nuevos, reusados, extra, args.modelo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
