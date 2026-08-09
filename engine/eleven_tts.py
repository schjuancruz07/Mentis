"""eleven_tts.py -- voz por ElevenLabs en UN solo proceso (2026-08-03, D del plan).

POR QUE UN SOLO PROCESO Y NO UN SCRIPT DE BASH: la primera version hacia el chequeo de cuota, el
armado del JSON y la contabilidad en tres invocaciones separadas de python, mas curl, mas mktemp,
mas grep, mas awk. Resultado medido: 3.401 ms de punta a punta para una frase que ElevenLabs
entrega en 491 ms. El andamiaje se comio siete octavos del beneficio -- que es la unica razon por
la que se estaba integrando ElevenLabs.

Arrancar el interprete en esta maquina cuesta ~446 ms. Uno solo es aceptable; cuatro no.

LA CUOTA SE LLEVA ACA Y NO SE LE PREGUNTA A LA API. Esta key no tiene los permisos 'user_read'
ni 'voices_read' (verificado: contesta missing_permissions), asi que no hay forma de consultar
cuanto queda. Pero cada respuesta trae la cabecera 'character-cost', que es el gasto REAL de esa
llamada. Se suma en un JSON local con reinicio mensual.

Medido: flash v2.5 cuesta 0,5 creditos por caracter (30 caracteres -> character-cost: 15). Con
10.000 creditos gratis por mes son 20.000 caracteres. El volumen real de voz del usuario es de
48.681 caracteres mensuales: alcanza para el 41%, y por eso el uso es SELECTIVO.

Uso:  eleven_tts.py --texto "..." --salida x.mp3 [--voz ID] [--modelo M] [--presupuesto N]
      eleven_tts.py --cuota
Salidas: 0 ok | 2 falta texto | 3 sin cuota | 4 error de la API | 5 sin key
"""
import argparse
import datetime
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

BASE = "https://api.elevenlabs.io/v1/text-to-speech"

# Las tres que funcionan en el plan gratuito. El resto son de la biblioteca compartida y dan 402
# ('Free users cannot use library voices via the API') -- probadas una por una, no supuestas.
VOCES_LIBRES = {
    "EXAVITQu4vr4xnSDxMaL": "Sarah",
    "pNInz6obpgDQGcFmaJgB": "Adam",
    "ErXwobaYiN019PkySvjV": "Antoni",
}


def leer_key():
    """Busca la key en los tres lugares donde puede estar, en orden de prioridad.

    LOS TRES, y no solo el entorno: este helper se llama tanto desde mentis-tts.sh -- que sourcea
    nv-lib.sh y por lo tanto ya tiene la variable cargada desde.nv-secrets -- como directamente,
    desde un test o a mano. Si solo mirara el entorno, funcionaria en produccion y fallaria suelto,
    que es la peor combinacion: el test da rojo y el codigo esta bien, o al reves.
    """
    k = os.environ.get("ELEVENLABS_API_KEY")
    if k:
        return k
    #.nv-secrets es un archivo de shell; se lee la linea, no se ejecuta nada.
    aqui = os.path.dirname(os.path.abspath(__file__))
    try:
        with io.open(os.path.join(aqui, ".nv-secrets"), encoding="utf-8", errors="replace") as f:
            for linea in f:
                if "ELEVENLABS_API_KEY" not in linea or linea.lstrip().startswith("#"):
                    continue
                # export ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-sk_...}"
                m = re.search(r'ELEVENLABS_API_KEY:-([^}"\']+)', linea) or \
                    re.search(r'ELEVENLABS_API_KEY=["\']?([^"\'\s}]+)', linea)
                if m and not m.group(1).startswith("$"):
                    return m.group(1)
    except Exception:
        pass
    try:
        with io.open(os.path.expanduser("~/.claude/settings.json"), encoding="utf-8") as f:
            return (json.load(f).get("env") or {}).get("ELEVENLABS_API_KEY", "")
    except Exception:
        return ""


def _mes():
    return datetime.date.today().strftime("%Y-%m")


def leer_cuota(ruta):
    try:
        with io.open(ruta, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def sumar_cuota(ruta, costo):
    d = leer_cuota(ruta)
    m = _mes()
    d[m] = int(d.get(m, 0)) + int(costo)
    for k in sorted(d)[:-6]:      # es un contador, no un historial
        del d[k]
    try:
        with io.open(ruta, "w", encoding="utf-8") as f:
            json.dump(d, f)
    except Exception:
        pass
    return d[m]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--texto", default="")
    ap.add_argument("--salida", default="")
    ap.add_argument("--voz", default=os.environ.get("MENTIS_EL_VOZ", "EXAVITQu4vr4xnSDxMaL"))
    ap.add_argument("--modelo", default=os.environ.get("MENTIS_EL_MODELO", "eleven_flash_v2_5"))
    ap.add_argument("--presupuesto", type=int,
                    default=int(os.environ.get("MENTIS_EL_PRESUPUESTO", "9000")))
    ap.add_argument("--cuota-archivo", default=os.environ.get("MENTIS_EL_CUOTA", ""))
    ap.add_argument("--cuota", action="store_true")
    args = ap.parse_args()

    ruta_cuota = args.cuota_archivo or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "eleven-cuota.json")

    if args.cuota:
        g = int(leer_cuota(ruta_cuota).get(_mes(), 0))
        print("Creditos usados en %s: %d de %d" % (_mes(), g, args.presupuesto))
        print("Quedan para unos %d caracteres con esta voz." % max(0, (args.presupuesto - g) * 2))
        return 0

    if not (args.texto or "").strip():
        sys.stderr.write("falta --texto\n")
        return 2
    key = leer_key()
    if not key:
        sys.stderr.write("falta ELEVENLABS_API_KEY\n")
        return 5

    largo = len(args.texto)
    # Estimacion previa con la regla medida (0,5 creditos por caracter en flash): asi nunca se
    # arranca una llamada que se va a pasar del presupuesto.
    est = (largo + 1) // 2
    gastado = int(leer_cuota(ruta_cuota).get(_mes(), 0))
    if gastado + est > args.presupuesto:
        sys.stderr.write("SIN_CUOTA: quedan %d creditos y esta frase necesita ~%d\n"
                         % (args.presupuesto - gastado, est))
        return 3

    salida = args.salida or os.path.join(os.path.dirname(ruta_cuota), "eleven-%d.mp3" % int(time.time()))
    cuerpo = json.dumps({"text": args.texto, "model_id": args.modelo}).encode("utf-8")
    req = urllib.request.Request(BASE + "/" + args.voz + "/stream", data=cuerpo, method="POST",
                                 headers={"xi-api-key": key, "Content-Type": "application/json"})
    t0 = time.time()
    primero = None
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            costo = r.headers.get("character-cost")
            with io.open(salida, "wb") as f:
                while True:
                    b = r.read(8192)
                    if not b:
                        break
                    if primero is None:
                        primero = time.time() - t0
                    f.write(b)
    except urllib.error.HTTPError as e:
        detalle = ""
        try:
            detalle = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        sys.stderr.write("ElevenLabs contesto %s. %s\n" % (e.code, detalle))
        return 4
    except Exception as e:
        sys.stderr.write("fallo la llamada: %s: %s\n" % (type(e).__name__, str(e)[:120]))
        return 4

    try:
        costo = int(costo)
    except (TypeError, ValueError):
        costo = est
    total = sumar_cuota(ruta_cuota, costo)

    print(salida)
    sys.stderr.write("[eleven] %d caracteres, %d creditos (van %d de %d). "
                     "primer byte %d ms, total %d ms.\n"
                     % (largo, costo, total, args.presupuesto,
                        round((primero or 0) * 1000), round((time.time() - t0) * 1000)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
