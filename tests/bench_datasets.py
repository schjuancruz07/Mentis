#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_datasets.py -- HumanEval y GSM8K reales contra los modelos de Mentis (2026-08-02).

POR QUE EXISTE
    Los fixtures por rol (nv-fixtures-roles.sh) miden si el modelo emite CODIGO en vez de prosa.
    No miden si el codigo ANDA: para eso hay que ejecutarlo. HumanEval trae 164 problemas con
    sus tests, y esa es la unica forma honesta de puntuar el rol 'code'. GSM8K hace lo mismo con
    aritmetica de varios pasos, que es lo que hacen 'reason', 'deep' y -- esto importa --.

POR QUE EN PYTHON Y NO EN BASH
    El resto de la medicion vive en bash porque reusa nv_respuesta_modelo. Aca no alcanza: hay
    que parsear JSONL con saltos de linea adentro, armar un programa, ejecutarlo con timeout y
    leerle el exit code. En bash eso es un campo minado de comillas; en python son 20 lineas.

SOBRE EJECUTAR CODIGO GENERADO POR UN MODELO
    Es lo que HumanEval exige: sin ejecutar, no hay puntaje. Se acota asi: cada programa corre
    en un directorio temporal propio, con timeout duro de 10 s, y el directorio se borra al
    terminar. Los problemas son los canonicos de HumanEval (algoritmos puros: listas, strings,
    numeros); ninguno pide red, ni archivos, ni instalar nada.

REANUDACION
    Cada resultado se escribe apenas se sabe. Relanzar continua donde quedo. El free tier se
    satura y una corrida de dos horas que pierde todo al cortarse es lo peor que puede pasar.

Uso:
    NVIDIA_API_KEY=... python3 bench_datasets.py humaneval -o salida.jsonl -n 50 -m mod1,mod2
    NVIDIA_API_KEY=... python3 bench_datasets.py gsm8k     -o salida.jsonl -n 50 -m mod1,mod2
"""
import argparse, json, os, re, subprocess, sys, tempfile, time, shutil
import urllib.request, urllib.error

URL = os.environ.get("NV_URL", "https://integrate.api.nvidia.com/v1/chat/completions")
AQUI = os.path.dirname(os.path.abspath(__file__))
PAUSA = float(os.environ.get("BD_PAUSA", "1.5"))
TIMEOUT_HTTP = int(os.environ.get("BD_TIMEOUT", "120"))


def pedir(modelo, key, prompt, max_tokens=1024, temp=0.0):
    """Una llamada al endpoint. Devuelve (texto, error_o_None).

    Se distingue texto vacio de error a proposito: un modelo que contesta vacio reprueba el
    caso, pero un 429 no es una reprobacion del modelo, es el free tier -- y confundirlos
    ensucia la tabla entera.
    """
    cuerpo = json.dumps({
        "model": modelo,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temp,
    }).encode("utf-8")
    req = urllib.request.Request(URL, data=cuerpo, method="POST", headers={
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_HTTP) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return "", "HTTP %s" % e.code
    except Exception as e:
        return "", type(e).__name__
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    # Los modelos de razonamiento dejan content vacio y ponen todo en reasoning_content. Sin
    # este fallback un modelo perfectamente bueno puntuaria 0 en todo (ya paso, ver nv-modelos-lib).
    txt = (msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()
    return txt, None


def sacar_codigo(txt):
    """El codigo de adentro de un bloque markdown, o el texto tal cual si no hay bloque."""
    m = re.search(r"```(?:python|py)?\s*\n(.*?)```", txt, re.S)
    if m:
        return m.group(1)
    # Un bloque abierto sin cerrar es comun cuando se corta por max_tokens: vale la pena
    # rescatarlo igual, porque a veces la funcion ya esta completa antes del corte.
    m = re.search(r"```(?:python|py)?\s*\n(.*)", txt, re.S)
    if m:
        return m.group(1)
    return txt


def correr_python(fuente, segundos=10):
    """Ejecuta el programa en un dir temporal propio. Devuelve (ok, detalle)."""
    d = tempfile.mkdtemp(prefix="bd_he_")
    try:
        ruta = os.path.join(d, "p.py")
        with open(ruta, "w", encoding="utf-8") as f:
            f.write(fuente)
        try:
            r = subprocess.run([sys.executable, ruta], cwd=d, timeout=segundos,
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            return False, "timeout"
        if r.returncode == 0:
            return True, ""
        err = (r.stderr or "").strip().splitlines()
        return False, (err[-1][:200] if err else "exit %s" % r.returncode)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# --------------------------------------------------------------------------------------------
def humaneval(item, modelo, key):
    prompt = (
        "Completa esta funcion de Python. Devolve SOLO el codigo Python completo de la funcion, "
        "incluyendo la linea def y todos los imports que necesites. Sin explicacion, sin texto "
        "antes ni despues.\n\n" + item["prompt"]
    )
    txt, err = pedir(modelo, key, prompt, max_tokens=1024)
    if err:
        return None, err, txt
    codigo = sacar_codigo(txt)
    entry = item["entry_point"]
    # Si el modelo devolvio solo el cuerpo (sin 'def'), se le antepone el prompt original, que ya
    # trae la firma. Es el mismo criterio del harness oficial: se evalua si resuelve el problema,
    # no si obedecio al pie de la letra el formato pedido.
    if ("def " + entry) not in codigo:
        codigo = item["prompt"] + "\n" + codigo
    fuente = codigo + "\n\n" + item["test"] + "\n\ncheck(" + entry + ")\n"
    ok, detalle = correr_python(fuente)
    return ok, detalle, txt


NUM = re.compile(r"-?\d[\d,]*\.?\d*")


def gsm8k(item, modelo, key):
    prompt = (
        "Resolve este problema. Pensa paso a paso si hace falta, pero terminá tu respuesta con "
        "una ultima linea que diga exactamente: RESPUESTA: <numero>\n\n" + item["question"]
    )
    txt, err = pedir(modelo, key, prompt, max_tokens=1024)
    if err:
        return None, err, txt
    esperado = item["answer"].split("####")[-1].strip().replace(",", "")
    # Se busca primero la linea RESPUESTA:. Si el modelo no la puso, se toma el ULTIMO numero del
    # texto -- en un razonamiento paso a paso el resultado esta al final, no al principio (tomar
    # el primero puntuaria el enunciado en vez de la conclusion).
    m = re.search(r"RESPUESTA:\s*(-?[\d,\.]+)", txt, re.I)
    if m:
        cand = m.group(1)
    else:
        todos = NUM.findall(txt)
        cand = todos[-1] if todos else ""
    cand = cand.replace(",", "").rstrip(".")
    try:
        ok = abs(float(cand) - float(esperado)) < 1e-6
    except ValueError:
        ok = False
    return ok, "esperado=%s dio=%s" % (esperado, cand or "-"), txt


BENCHES = {
    "humaneval": (os.path.join(AQUI, "datos", "HumanEval.jsonl"), humaneval),
    "gsm8k": (os.path.join(AQUI, "datos", "gsm8k-test.jsonl"), gsm8k),
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("bench", choices=sorted(BENCHES))
    p.add_argument("-o", "--salida", required=True)
    p.add_argument("-n", "--cantidad", type=int, default=50)
    p.add_argument("-m", "--modelos", required=True)
    args = p.parse_args()

    key = os.environ.get("NVIDIA_API_KEY", "")
    if not key:
        print("Sin NVIDIA_API_KEY.", file=sys.stderr)
        return 1

    ruta, fn = BENCHES[args.bench]
    with open(ruta, encoding="utf-8") as f:
        items = [json.loads(l) for l in f if l.strip()][: args.cantidad]

    hechas = set()
    if os.path.exists(args.salida):
        with open(args.salida, encoding="utf-8") as f:
            for l in f:
                try:
                    hechas.add(json.loads(l)["clave"])
                except Exception:
                    pass

    modelos = [m.strip() for m in args.modelos.split(",") if m.strip()]
    for modelo in modelos:
        bien = tot = 0
        for i, it in enumerate(items):
            clave = "%s|%s|%d" % (args.bench, modelo, i)
            if clave in hechas:
                continue
            t0 = time.time()
            ok, detalle, crudo = fn(it, modelo, key)
            ms = int((time.time() - t0) * 1000)
            tot += 1
            if ok:
                bien += 1
            with open(args.salida, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "clave": clave, "bench": args.bench, "modelo": modelo, "caso": i,
                    "ok": (None if ok is None else int(ok)), "ms": ms,
                    "detalle": detalle, "resp": (crudo or "")[:400],
                }, ensure_ascii=False) + "\n")
            estado = "ERROR" if ok is None else ("OK" if ok else "FALLO")
            print("[%s] %s / caso %d -> %s (%dms) %s" % (args.bench, modelo, i, estado, ms, detalle[:80]),
                  file=sys.stderr, flush=True)
            time.sleep(PAUSA)
        if tot:
            print("[%s] == %s: %d/%d nuevos ==" % (args.bench, modelo, bien, tot), file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
