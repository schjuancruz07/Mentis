"""calibrar-streaming.py -- de donde salen los presupuestos de vida (Bloque 0.2 del plan).

EL PROBLEMA QUE RESUELVE: un timeout total no distingue "esta pensando" de "esta colgado" --
solo mide reloj. Por eso el timeout de 120 s de hoy deja colgado al usuario dos minutos antes de
caer al fallback, y por eso bajarlo a 25 s cortaria respuestas sanas (glm-5.2 tardo 30,9 s en una
respuesta perfectamente buena).

Con streaming se puede medir lo que importa de verdad:
  - TIEMPO HASTA EL PRIMER TOKEN: si no llega, no va a llegar.
  - SILENCIO MAXIMO ENTRE TOKENS: si venia escribiendo y se callo, se colgo.

Los presupuestos del plan salen de estos numeros, no de una regla del pulgar. Primera medicion
(2 modelos): nemotron-3-super callaba como maximo 366 ms, glm-5.2 hasta 9.813 ms en una respuesta
sana. Un presupuesto de silencio de 5 s habria matado llamadas buenas.

Uso:  python3 tests/calibrar-streaming.py [modelo...]
      sin argumentos mide todos los modelos cableados hoy.
"""
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

URL = "https://integrate.api.nvidia.com/v1/chat/completions"

# Los modelos que hoy estan cableados como principal o fallback de algun rol.
MODELOS = [
    "meta/llama-3.1-8b-instruct",
    "z-ai/glm-5.2",
    "deepseek-ai/deepseek-v4-flash",
    "deepseek-ai/deepseek-v4-pro",
    "nvidia/nemotron-3-super-120b-a12b",
    "nvidia/nemotron-3-ultra-550b-a55b",
    "mistralai/mistral-medium-3.5-128b",
    "minimaxai/minimax-m3",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
    "openai/gpt-oss-120b",
]

CORTO = "Deci hola y nada mas."
LARGO = ("Un tren sale de A hacia B a 60 km/h y otro sale de B hacia A a 90 km/h al mismo tiempo. "
         "La distancia AB es 300 km. Una mosca vuela a 120 km/h yendo y viniendo entre los frentes "
         "de los dos trenes hasta que chocan. Cuanta distancia recorre la mosca? Explica tu "
         "razonamiento paso a paso.")

TECHO = 180          # nada corre mas de 3 minutos en la calibracion


def leer_key():
    ruta = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
    with io.open(ruta, encoding="utf-8") as f:
        env = (json.load(f).get("env") or {})
    for k in ("NVIDIA_API_KEY", "NVIDIA_KEY", "NVIDIA_API_KEY_NEMOTRON"):
        if env.get(k):
            return env[k]
    raise SystemExit("no encontre la API key de NVIDIA en ~/.claude/settings.json")


def medir(key, modelo, pregunta, max_tokens):
    cuerpo = {"model": modelo, "messages": [{"role": "user", "content": pregunta}],
              "max_tokens": max_tokens, "temperature": 0.6, "stream": True}
    req = urllib.request.Request(URL, data=json.dumps(cuerpo).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key,
                                          "Content-Type": "application/json"})
    t0 = time.time()
    ttft = None
    ultimo = t0
    silencios = []
    chunks = 0
    razonando = False
    try:
        with urllib.request.urlopen(req, timeout=TECHO) as r:
            for cruda in r:
                linea = cruda.decode("utf-8", "replace").strip()
                if not linea.startswith("data:"):
                    continue
                carga = linea[5:].strip()
                if carga == "[DONE]":
                    break
                try:
                    d = json.loads(carga)
                except Exception:
                    continue
                delta = (d.get("choices") or [{}])[0].get("delta") or {}
                if delta.get("reasoning_content"):
                    razonando = True
                if not (delta.get("content") or delta.get("reasoning_content")):
                    continue
                ahora = time.time()
                if ttft is None:
                    ttft = ahora - t0
                else:
                    silencios.append(ahora - ultimo)
                ultimo = ahora
                chunks += 1
    except urllib.error.HTTPError as e:
        return {"error": "HTTP %s" % e.code}
    except Exception as e:
        return {"error": type(e).__name__}
    if ttft is None:
        return {"error": "sin tokens"}
    return {"ttft_ms": round(ttft * 1000), "total_s": round(time.time() - t0, 1),
            "chunks": chunks, "razona": razonando,
            "silencio_max_ms": round(max(silencios) * 1000) if silencios else 0,
            "silencio_p95_ms": round(sorted(silencios)[int(len(silencios) * 0.95)] * 1000) if silencios else 0}


def main():
    key = leer_key()
    modelos = sys.argv[1:] or MODELOS
    resultados = {}
    print("%-46s %-8s %9s %9s %11s %8s" % ("MODELO", "caso", "1er tok", "total", "silen.max", "razona"))
    print("-" * 96)
    for m in modelos:
        resultados[m] = {}
        for etiqueta, pregunta, tope in (("corto", CORTO, 80), ("largo", LARGO, 1500)):
            r = medir(key, m, pregunta, tope)
            resultados[m][etiqueta] = r
            if "error" in r:
                print("%-46s %-8s %9s" % (m[:46], etiqueta, r["error"]))
            else:
                print("%-46s %-8s %7d ms %7.1f s %9d ms %8s"
                      % (m[:46], etiqueta, r["ttft_ms"], r["total_s"], r["silencio_max_ms"],
                         "si" if r["razona"] else "no"))
            time.sleep(1)      # de a uno: dos bancos en paralelo dan 429 en todo (leccion 2026-08-02)

    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    salida = os.path.join(raiz, "docs", "calibracion-streaming-%s.json" % datetime.now().strftime("%Y%m%d-%H%M"))
    with io.open(salida, "w", encoding="utf-8") as f:
        json.dump(resultados, f, ensure_ascii=False, indent=2)

    print()
    # UN MODELO SANO ES EL QUE CONTESTO LOS DOS CASOS. Con "al menos uno" no alcanza, y esto no
    # es un detalle: en la primera corrida gpt-oss-120b contesto el caso corto en 158 SEGUNDOS y
    # fallo el largo, y como contaba de vivo envenenó la sugerencia -- salio "presupuesto de
    # 476 s", que es exactamente el problema que este trabajo viene a arreglar. Un presupuesto
    # calculado sobre un modelo agonizante no es un presupuesto, es el sintoma.
    sanos = {m: v for m, v in resultados.items()
             if all("error" not in r for r in v.values())}
    enfermos = {m: v for m, v in resultados.items() if m not in sanos}

    print("=== PRESUPUESTOS SUGERIDOS (solo modelos que contestaron TODOS los casos) ===")
    if sanos:
        peor_ttft = max(r["ttft_ms"] for v in sanos.values() for r in v.values())
        peor_sil = max(r["silencio_max_ms"] for v in sanos.values() for r in v.values())
        quien_ttft = max(((m, r["ttft_ms"]) for m, v in sanos.items() for r in v.values()),
                         key=lambda t: t[1])[0]
        quien_sil = max(((m, r["silencio_max_ms"]) for m, v in sanos.items() for r in v.values()),
                        key=lambda t: t[1])[0]
        print("  peor primer token.. %6d ms  (%s)  -> presupuesto %d s" %
              (peor_ttft, quien_ttft, max(12, round(peor_ttft * 3 / 1000))))
        print("  peor silencio...... %6d ms  (%s)  -> presupuesto %d s" %
              (peor_sil, quien_sil, max(20, round(peor_sil * 3 / 1000))))
    else:
        print("  ningun modelo contesto los dos casos -- no hay de donde sacar presupuestos")

    if enfermos:
        print()
        print("=== MODELOS QUE NO ESTAN PARA ATENDER (sacar del cableado) ===")
        for m, v in enfermos.items():
            detalle = " · ".join("%s: %s" % (k, r.get("error") or ("%d ms al primer token" % r["ttft_ms"]))
                                 for k, r in v.items())
            print("  %-46s %s" % (m[:46], detalle))
    print()
    print("  crudo en %s" % salida)
    return 0


if __name__ == "__main__":
    sys.exit(main())
