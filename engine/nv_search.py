#!/usr/bin/env python3
"""nv_search.py -- busqueda semantica sobre el indice de Kai Vault (reescrito 2026-07-26).

Score HIBRIDO a proposito (denso + lexico). El buscador viejo era solo denso, y eso falla justo
en lo que mas se busca dentro de un repo: nombres exactos. Preguntar por "FAIL_SIG_MAX" con
similitud puramente semantica devuelve "cosas que hablan de reintentos y limites" -- todas
parecidas, ninguna la correcta. La senal lexica arregla eso sin perder lo bueno del denso
(preguntar "donde decido que modelo usa cada rol" y que encuentre el `case` sin que la frase
aparezca literal en ningun lado).
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

EMB_URL = os.environ.get("NV_EMB_URL", "https://integrate.api.nvidia.com/v1/embeddings")


def embeber_consulta(texto, modelo, api_key):
    payload = {"model": modelo, "input": [texto], "input_type": "query",
               "encoding_format": "float", "truncate": "END"}
    req = urllib.request.Request(
        EMB_URL, data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))["data"][0]["embedding"]
    except urllib.error.HTTPError as e:
        detalle = ""
        try:
            detalle = e.read().decode("utf-8")[:200]
        except Exception:
            pass
        raise RuntimeError("la API de embeddings respondio %s: %s" % (e.code, detalle))
    except Exception as e:
        raise RuntimeError("no se pudo hablar con la API de embeddings: %s" % e)


def ruta_vecs(ruta_jsonl):
    return os.path.splitext(ruta_jsonl)[0] + ".vecs.npy"


def tokens(texto):
    # Se parte tambien por guion bajo y camelCase para que "FAIL_SIG_MAX" matchee con "fail",
    # "sig" y "max", y "runKaiReindex" con "kai" y "reindex".
    crudo = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+", texto)
    salida = set()
    for t in crudo:
        bajo = t.lower()
        salida.add(bajo)
        for parte in bajo.split("_"):
            if len(parte) > 2:
                salida.add(parte)
        for parte in re.findall(r"[a-z]+|\d+", re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", t).lower()):
            if len(parte) > 2:
                salida.add(parte)
    return salida


def score_lexico(consulta_tokens, texto):
    """Proporcion de terminos de la consulta que aparecen en el chunk. Simple a proposito:
    lo unico que tiene que aportar es 'este fragmento menciona literalmente lo que pediste'."""
    if not consulta_tokens:
        return 0.0
    tt = tokens(texto)
    if not tt:
        return 0.0
    comunes = len(consulta_tokens & tt)
    return comunes / len(consulta_tokens)


def cargar_indice(ruta):
    """Devuelve (metadatos, matriz_de_vectores). Los vectores viven en un.npy aparte: leerlos
    desde JSON costaba ~3.9 s por busqueda (medido), casi todo en parsear 20 MB de texto."""
    import numpy as np
    if not os.path.exists(ruta):
        return [], None
    metas = []
    with open(ruta, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                metas.append(json.loads(ln))
            except Exception:
                return [], None    # el pareo con la matriz es por posicion: no se puede saltear
    pv = ruta_vecs(ruta)
    if not os.path.exists(pv):
        return [], None
    try:
        vecs = np.load(pv)
    except Exception:
        return [], None
    if len(vecs) != len(metas):
        return [], None            # par inconsistente: mejor decir "no hay indice" que mentir
    return metas, vecs


def main():
    ap = argparse.ArgumentParser(description="Busca en el indice semantico de Kai Vault")
    ap.add_argument("consulta", nargs="+")
    ap.add_argument("-i", "--indice", action="append", required=True, help="archivo.jsonl (repetible)")
    ap.add_argument("-k", "--topk", type=int, default=5)
    ap.add_argument("-m", "--modelo", default="nvidia/nv-embedqa-e5-v5")
    ap.add_argument("--peso-lexico", type=float, default=0.35)
    ap.add_argument("--max-por-archivo", type=int, default=1,
                    help="cuantos fragmentos como maximo puede aportar un mismo archivo al top-k")
    ap.add_argument("--json", action="store_true", help="salida JSON en vez de texto")
    args = ap.parse_args()

    consulta = " ".join(args.consulta).strip()
    api_key = os.environ.get("NVIDIA_API_KEY", "").strip()
    if not api_key:
        print("ERROR: falta NVIDIA_API_KEY en el entorno", file=sys.stderr)
        return 2

    import numpy as np

    metas, matriz = [], None
    for ruta in args.indice:
        m, v = cargar_indice(ruta)
        if not m or v is None:
            continue
        if matriz is None:
            metas, matriz = list(m), v
        elif v.shape[1] == matriz.shape[1]:
            metas.extend(m)
            matriz = np.vstack([matriz, v])
    if not metas or matriz is None:
        # Se distingue "no hay indice" de "no hubo resultados": son problemas distintos, y el
        # mensaje viejo los mezclaba mandando a reindexar cuando reindexar tampoco andaba.
        print("ERROR: el indice esta vacio, no existe o esta inconsistente (%s)"
              % ", ".join(args.indice), file=sys.stderr)
        return 3

    try:
        qvec = np.asarray(embeber_consulta(consulta, args.modelo, api_key), dtype="float32")
    except RuntimeError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 4

    if qvec.shape[0] != matriz.shape[1]:
        print("ERROR: el indice fue creado con otro modelo de embeddings (%d dims vs %d)"
              % (matriz.shape[1], qvec.shape[0]), file=sys.stderr)
        return 5

    # Coseno vectorizado contra TODA la matriz de una: una sola operacion de numpy en vez de un
    # bucle Python por chunk.
    normas = np.linalg.norm(matriz, axis=1)
    normas[normas == 0] = 1e-9
    densos = (matriz @ qvec) / (normas * (np.linalg.norm(qvec) or 1e-9))

    qtok = tokens(consulta)
    peso = max(0.0, min(1.0, args.peso_lexico))
    # El score lexico solo se calcula sobre los mejores candidatos densos: recorrer los ~900
    # textos completos en Python es justamente lo que se quiere evitar. Se toma un margen amplio
    # (topk * 20) para que la senal lexica todavia pueda reordenar de verdad.
    margen = min(len(metas), max(args.topk * 20, 100))
    candidatos = np.argpartition(-densos, margen - 1)[:margen] if len(metas) > margen else range(len(metas))

    puntuados = []
    for i in candidatos:
        d = metas[i]
        denso = float(densos[i])
        lex = score_lexico(qtok, d.get("text", ""))
        puntuados.append(((1 - peso) * denso + peso * lex, denso, lex, d))

    puntuados.sort(key=lambda x: -x[0])

    # DIVERSIDAD POR ARCHIVO. Medido: sin esto, el top-3 eran casi siempre tres chunks
    # CONSECUTIVOS del mismo archivo (nv-agent.sh tiene 98 chunks y su prompt describe todas las
    # capacidades, asi que matchea con cualquier consulta). Devolver tres pedazos del mismo lugar
    # desperdicia dos de las tres respuestas y esconde el archivo que de verdad hace la tarea.
    # Se permite un maximo por archivo y recien se completa con repetidos si falta cupo.
    por_archivo = {}
    mejores, sobrantes = [], []
    for fila in puntuados:
        arch = fila[3].get("file")
        usados = por_archivo.get(arch, 0)
        if usados < args.max_por_archivo:
            por_archivo[arch] = usados + 1
            mejores.append(fila)
            if len(mejores) >= args.topk:
                break
        else:
            sobrantes.append(fila)
    if len(mejores) < args.topk:
        mejores.extend(sobrantes[: args.topk - len(mejores)])

    if args.json:
        print(json.dumps([
            {"file": d["file"], "line": d["line"], "score": round(s, 4),
             "denso": round(dn, 4), "lexico": round(lx, 4), "text": d["text"][:600]}
            for s, dn, lx, d in mejores
        ], ensure_ascii=False))
    else:
        for s, dn, lx, d in mejores:
            print("%s:%s  (score %.3f | denso %.3f | lexico %.3f)" % (d["file"], d["line"], s, dn, lx))
            for linea in d["text"].splitlines()[:6]:
                print("    " + linea[:160])
            print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
