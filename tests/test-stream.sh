#!/usr/bin/env bash
# test-stream.sh -- nv_stream.py: streaming y presupuestos de vida (2026-08-03).
#
# QUE SE PRUEBA Y POR QUE ASI:
#   nv_stream.py reemplaza tres procesos (armar JSON + curl + parsear) por uno, y cambia el
#   criterio de corte: de "cuanto tardo en total" a "hace cuanto que no da senales de vida".
#   Eso ultimo es lo que permite que 'code' piense 30 segundos sin que nadie lo corte, y que un
#   modelo colgado caiga al fallback en 6 en vez de en 120.
#
#   El grueso de la suite corre contra un SERVIDOR FALSO local, no contra NVIDIA. No es por
#   ahorrar llamadas: es la unica forma de provocar a voluntad los casos que importan -- un
#   modelo que no manda nunca el primer token, uno que escribe y se calla a la mitad, uno que
#   contesta 429. Contra el endpoint real esos casos aparecen cuando quieren.
#
#   Los ultimos dos chequeos SI van contra NVIDIA de verdad (detras de -v), porque un servidor
#   falso puede hacerme creer que el formato es el que yo supongo.
set -uo pipefail
TS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_ROOT="$(cd "$TS_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TS_VIVO=0; [ "${1:-}" = "-v" ] && TS_VIVO=1
TS_OK=0; TS_MAL=0
_ok()  { TS_OK=$((TS_OK+1));  echo "  OK   $1"; }
_mal() { TS_MAL=$((TS_MAL+1)); echo "  MAL  $1  ($2)"; }

TS_TMP="$(mktemp -d)"
case "$TS_TMP" in
  "$TS_ROOT"|"$TS_ROOT"/*) echo "ABORTA: el temporal cae dentro de Mentis" >&2; exit 1 ;;
esac

SERVIDOR_PID=""
_limpiar() {
  [ -n "$SERVIDOR_PID" ] && MSYS_NO_PATHCONV=1 taskkill /F /PID "$SERVIDOR_PID" >/dev/null 2>&1
  rm -rf "$TS_TMP" 2>/dev/null
}
trap _limpiar EXIT

STREAM="$TS_ROOT/engine/nv_stream.py"
[ -f "$STREAM" ] || { echo "ABORTA: no existe $STREAM" >&2; exit 1; }

# --- servidor falso: provoca cada modo de falla a pedido -----------------------------------------
cat > "$TS_TMP/servidor.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _sse(self, trozos, pausas):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for t, p in zip(trozos, pausas):
            if p: time.sleep(p)
            d = {"choices": [{"delta": {"content": t}}]}
            self.wfile.write(("data: " + json.dumps(d) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()

    def do_POST(self):
        largo = int(self.headers.get("Content-Length") or 0)
        pedido = json.loads(self.rfile.read(largo) or b"{}")
        modo = pedido.get("model", "")

        if modo == "ok":
            self._sse(["Hola", " mundo", "!"], [0, 0.05, 0.05])
        elif modo == "mudo":                       # nunca manda el primer token
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            time.sleep(30)
        elif modo == "se-calla":                   # escribe y se cuelga a la mitad
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for t in ["empiezo", " bien"]:
                self.wfile.write(("data: " + json.dumps({"choices":[{"delta":{"content":t}}]}) + "\n\n").encode())
                self.wfile.flush()
            time.sleep(30)
        elif modo == "lento-pero-vivo":            # pausas largas PERO sigue emitiendo
            self._sse(["pen", "san", "do", " listo"], [0, 1.2, 1.2, 1.2])
        elif modo == "razona":                     # solo reasoning_content, sin content
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for t in ["primero esto", " despues aquello"]:
                d = {"choices": [{"delta": {"reasoning_content": t}}]}
                self.wfile.write(("data: " + json.dumps(d) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        elif modo == "429":
            self.send_response(429); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({"error":{"code":"429","message":"rate"}}).encode())
        elif modo == "404":
            self.send_response(404); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({"error":{"code":"404","message":"no existe"}}).encode())
        else:
            self.send_response(500); self.end_headers()

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

python3 "$TS_TMP/servidor.py" > "$TS_TMP/puerto.txt" 2>"$TS_TMP/servidor.err" &
for _ in $(seq 1 40); do [ -s "$TS_TMP/puerto.txt" ] && break; sleep 0.25; done
PUERTO="$(tr -d '\r\n ' < "$TS_TMP/puerto.txt")"
[ -n "$PUERTO" ] || { echo "ABORTA: el servidor falso no arranco" >&2; exit 1; }
SERVIDOR_PID="$(MSYS_NO_PATHCONV=1 powershell -NoProfile -Command "
  (Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -like '*servidor.py*' } | Select-Object -First 1).ProcessId" 2>/dev/null | tr -d '\r\n ')"
FALSO="http://127.0.0.1:$PUERTO/v1/chat/completions"

_correr() {
  local modelo="$1"; shift
  # NV_META_STDERR / NV_THINK_STDERR van explicitos porque estan APAGADOS por defecto:
  # mentis-chat.sh reenvia cada linea de stderr al panel de la app sin filtrar, asi que
  # prenderlas por defecto seria ruido visible para el usuario en cada turno. El test las prende
  # porque son justo lo que quiere inspeccionar.
  env NVURL="$FALSO" NVKEY="x" NVMODEL="$modelo" NVPROMPT="hola" NVMAX=100 NVTEMP=0.6 \
      NVEXTRA="{}" NVSYS="" NVSKILL="" NVIMAGES="" NV_META_STDERR=1 NV_THINK_STDERR=1 "$@" \
      python3 "$STREAM" 2>"$TS_TMP/err.txt"
}

echo "== nv_stream.py =="
echo "-- A. lo basico"

SALIDA="$(_correr ok)"; RC=$?
[ "$RC" = "0" ] && [ "$SALIDA" = "Hola mundo!" ] \
  && _ok "A1 junta los trozos y devuelve el texto entero" \
  || _mal "A1 junta los trozos" "rc=$RC salida='$SALIDA'"

grep -q '^NVMETA ' "$TS_TMP/err.txt" \
  && _ok "A2 emite una linea NVMETA con las metricas" \
  || _mal "A2 emite NVMETA" "no aparece"

python3 -c "
import json,sys,io
for l in io.open(r'$(cygpath -w "$TS_TMP/err.txt")',encoding='utf-8'):
    if l.startswith('NVMETA '):
        d=json.loads(l[7:]); sys.exit(0 if isinstance(d.get('ttft_ms'),int) and d.get('exit')==0 else 1)
sys.exit(1)" \
  && _ok "A3 el NVMETA trae ttft_ms y exit=0" \
  || _mal "A3 NVMETA con ttft_ms" "$(grep '^NVMETA' "$TS_TMP/err.txt" | head -c 120)"

echo "-- B. presupuestos de vida (el corazon del cambio)"

# B1: el que NUNCA manda el primer token cae rapido, no espera el techo.
T0=$(date +%s%3N)
_correr mudo NV_TTFT=2 NV_SILENCIO=30 NV_TECHO=60 >/dev/null; RC=$?
MS=$(( $(date +%s%3N) - T0 ))
[ "$RC" = "3" ] && [ "$MS" -lt 8000 ] \
  && _ok "B1 sin primer token: corta en ${MS} ms con exit 3 (no espera el techo)" \
  || _mal "B1 sin primer token" "rc=$RC tardo ${MS} ms"

# B2: EL CHEQUEO QUE DEFINE TODO EL DISENO. Un modelo que hace pausas de 1,2 s pero SIGUE
# emitiendo NO se corta, aunque el total supere cualquier timeout corto que uno pondria.
# Es el caso de glm-5.2, que se calla hasta 9,8 s en respuestas perfectamente sanas.
SALIDA="$(_correr lento-pero-vivo NV_TTFT=3 NV_SILENCIO=4 NV_TECHO=60)"; RC=$?
[ "$RC" = "0" ] && [ "$SALIDA" = "pensando listo" ] \
  && _ok "B2 lento pero vivo: NO se corta (piensa tranquilo mientras emita)" \
  || _mal "B2 lento pero vivo" "rc=$RC salida='$SALIDA'"

# B3: el que escribe y se calla SI se corta, y conserva lo que alcanzo a decir.
T0=$(date +%s%3N)
SALIDA="$(_correr se-calla NV_TTFT=10 NV_SILENCIO=2 NV_TECHO=60)"; RC=$?
MS=$(( $(date +%s%3N) - T0 ))
[ "$RC" = "3" ] && [ "$SALIDA" = "empiezo bien" ] && [ "$MS" -lt 9000 ] \
  && _ok "B3 se callo a la mitad: corta en ${MS} ms y conserva el texto parcial" \
  || _mal "B3 se callo a la mitad" "rc=$RC salida='$SALIDA' tardo ${MS} ms"

grep -q '"parcial": *true' "$TS_TMP/err.txt" \
  && _ok "B4 avisa en NVMETA que la respuesta quedo parcial" \
  || _mal "B4 avisa parcial" "$(grep '^NVMETA' "$TS_TMP/err.txt" | head -c 140)"

# B5: el techo absoluto existe como ultima red.
T0=$(date +%s%3N)
_correr lento-pero-vivo NV_TTFT=5 NV_SILENCIO=10 NV_TECHO=2 >/dev/null; RC=$?
MS=$(( $(date +%s%3N) - T0 ))
[ "$MS" -lt 7000 ] \
  && _ok "B5 el techo absoluto corta igual al que emite (${MS} ms)" \
  || _mal "B5 techo absoluto" "tardo ${MS} ms"

echo "-- C. contrato de exit codes (lo usa el fallback de ask-nvidia.sh)"
_correr 429 >/dev/null; RC=$?
[ "$RC" = "2" ] && _ok "C1 429 -> exit 2 (reintentable)" || _mal "C1 429 -> exit 2" "rc=$RC"
_correr 404 >/dev/null; RC=$?
[ "$RC" = "4" ] && _ok "C2 404 -> exit 4 (definitivo)" || _mal "C2 404 -> exit 4" "rc=$RC"

echo "-- D. razonamiento"
SALIDA="$(_correr razona)"; RC=$?
[ "$RC" = "0" ] && [ "$SALIDA" = "primero esto despues aquello" ] \
  && _ok "D1 sin content pero con reasoning: devuelve el razonamiento" \
  || _mal "D1 solo reasoning" "rc=$RC salida='$SALIDA'"
grep -q '^NVTHINK ' "$TS_TMP/err.txt" \
  && _ok "D2 el razonamiento sale por NVTHINK, no mezclado en la respuesta" \
  || _mal "D2 NVTHINK" "no aparece"

echo "-- G. guarda de privacidad (se movio de nv-lib.sh a nv_stream.py: hay que probar que sigue)"
# El servidor falso escribe lo que RECIBE. Es la unica forma de comprobar que el secreto no salio
# de la maquina: mirar la salida del helper solo diria que el helper no lo imprimio.
cat > "$TS_TMP/espia.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DESTINO = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        largo = int(self.headers.get("Content-Length") or 0)
        crudo = self.rfile.read(largo)
        open(DESTINO, "wb").write(crudo)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(('data: ' + json.dumps({"choices":[{"delta":{"content":"ok"}}]}) + '\n\n').encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 "$TS_TMP/espia.py" "$TS_TMP/recibido.json" > "$TS_TMP/puerto2.txt" 2>/dev/null &
for _ in $(seq 1 40); do [ -s "$TS_TMP/puerto2.txt" ] && break; sleep 0.25; done
PUERTO2="$(tr -d '\r\n ' < "$TS_TMP/puerto2.txt")"
SECRETO='mi clave es nvapi-ABCDEFGH12345678 y mi mail usuario@ejemplo.com y el CBU 1234567890123456789012'
env NVURL="http://127.0.0.1:$PUERTO2/v1/chat/completions" NVKEY="x" NVMODEL="ok" \
    NVPROMPT="$SECRETO" NVMAX=50 NVTEMP=0.6 NVEXTRA="{}" NVSYS="" NVSKILL="" NVIMAGES="" \
    python3 "$STREAM" >/dev/null 2>"$TS_TMP/priv.err"
RECIBIDO="$(cat "$TS_TMP/recibido.json" 2>/dev/null)"
if [ -z "$RECIBIDO" ]; then
  _mal "G1 el secreto no viaja" "el espia no recibio nada"
elif echo "$RECIBIDO" | grep -q "nvapi-ABCDEFGH12345678"; then
  _mal "G1 el secreto no viaja" "LA API KEY LLEGO AL ENDPOINT"
elif echo "$RECIBIDO" | grep -q "usuario@ejemplo.com"; then
  _mal "G1 el secreto no viaja" "el mail llego al endpoint"
elif echo "$RECIBIDO" | grep -q "1234567890123456789012"; then
  _mal "G1 el secreto no viaja" "el CBU llego al endpoint"
else
  _ok "G1 clave, mail y CBU quedaron enmascarados antes de salir"
fi
echo "$RECIBIDO" | grep -q "NVAPI_KEY" \
  && _ok "G2 el reemplazo esta en el cuerpo enviado (se enmascaro, no se borro)" \
  || _mal "G2 marca de reemplazo" "no aparece [NVAPI_KEY] en lo recibido"
grep -q "^PRIVACIDAD: " "$TS_TMP/priv.err" \
  && _ok "G3 avisa por stderr cuantos datos enmascaro" \
  || _mal "G3 aviso de privacidad" "no aparece"
# Y que el interruptor siga funcionando, o seria una guarda que no se puede apagar para depurar.
env NVURL="http://127.0.0.1:$PUERTO2/v1/chat/completions" NVKEY="x" NVMODEL="ok" NV_REDACT=0 \
    NVPROMPT="nvapi-ABCDEFGH12345678" NVMAX=50 NVTEMP=0.6 NVEXTRA="{}" NVSYS="" NVSKILL="" NVIMAGES="" \
    python3 "$STREAM" >/dev/null 2>/dev/null
grep -q "nvapi-ABCDEFGH12345678" "$TS_TMP/recibido.json" \
  && _ok "G4 NV_REDACT=0 la apaga (mismo contrato que nv_redact)" \
  || _mal "G4 NV_REDACT=0" "enmascaro igual con la guarda apagada"

echo "-- H. lo que NO tiene que aparecer"
# mentis-chat.sh manda stderr crudo al panel de la app (tee al FIFO, sin filtrar). Una linea de
# metricas por llamada seria ruido visible en cada turno, y el monologo interno del modelo
# volcado entre los pasos seria peor. Por eso van apagadas salvo que alguien las pida.
env NVURL="$FALSO" NVKEY="x" NVMODEL="razona" NVPROMPT="hola" NVMAX=100 NVTEMP=0.6 \
    NVEXTRA="{}" NVSYS="" NVSKILL="" NVIMAGES="" python3 "$STREAM" >/dev/null 2>"$TS_TMP/limpio.err"
if grep -qE '^(NVMETA|NVTHINK) ' "$TS_TMP/limpio.err"; then
  _mal "H1 stderr limpio por defecto" "sale '$(head -c 40 "$TS_TMP/limpio.err")' sin pedirlo"
else
  _ok "H1 sin pedirlas, NVMETA/NVTHINK no ensucian el panel de la app"
fi

echo "-- E. emision incremental"
_correr ok NV_EMITIR=1 > "$TS_TMP/emitido.txt"; RC=$?
[ "$RC" = "0" ] && [ "$(cat "$TS_TMP/emitido.txt")" = "Hola mundo!" ] \
  && _ok "E1 con NV_EMITIR=1 el texto sale igual de completo" \
  || _mal "E1 NV_EMITIR" "rc=$RC '$(cat "$TS_TMP/emitido.txt")'"

# E2: que EMPIECE a salir antes de terminar. Sin esto, "streaming" es solo una palabra.
python3 - "$STREAM" "$FALSO" <<'PY'
import os, subprocess, sys, time
stream, url = sys.argv[1], sys.argv[2]
env = dict(os.environ, NVURL=url, NVKEY="x", NVMODEL="lento-pero-vivo", NVPROMPT="hola",
           NVMAX="100", NVTEMP="0.6", NVEXTRA="{}", NVSYS="", NVSKILL="", NVIMAGES="",
           NV_EMITIR="1", NV_TTFT="5", NV_SILENCIO="10", NV_TECHO="60", PYTHONUNBUFFERED="1")
t0 = time.time()
p = subprocess.Popen([sys.executable, "-u", stream], env=env,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
primero = None
while True:
    b = p.stdout.read(1)
    if not b: break
    if primero is None: primero = time.time() - t0
p.wait()
total = time.time() - t0
# El servidor falso tarda ~3,6 s en total y manda el primer trozo enseguida.
print("PRIMERO=%.2f TOTAL=%.2f" % (primero if primero else -1, total))
sys.exit(0 if (primero is not None and total - primero > 1.5) else 1)
PY
if [ $? -eq 0 ]; then
  _ok "E2 el primer caracter sale MUCHO antes que el ultimo (streaming de verdad)"
else
  _mal "E2 streaming real" "el primer caracter no se adelanto al final"
fi

if [ "$TS_VIVO" = "1" ]; then
  echo "-- F. contra NVIDIA de verdad (un servidor falso puede mentirme sobre el formato)"
  KEY="$(python3 -c "
import json,io,os
d=json.load(io.open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8'))
e=d.get('env',{})
print(e.get('NVIDIA_API_KEY') or e.get('NVIDIA_KEY') or '')")"
  if [ -z "$KEY" ]; then
    _mal "F1 llamada real" "no hay API key en settings.json"
  else
    SALIDA="$(env NVKEY="$KEY" NVMODEL="meta/llama-3.1-8b-instruct" NVPROMPT="Deci solamente: listo" \
      NVMAX=30 NVTEMP=0.2 NVEXTRA="{}" NVSYS="" NVSKILL="" NVIMAGES="" \
      NV_TTFT=20 NV_SILENCIO=30 NV_TECHO=90 NV_META_STDERR=1 python3 "$STREAM" 2>"$TS_TMP/real.err")"; RC=$?
    [ "$RC" = "0" ] && [ -n "$SALIDA" ] \
      && _ok "F1 el endpoint real contesta y se parsea ($(echo "$SALIDA" | head -c 30))" \
      || _mal "F1 endpoint real" "rc=$RC salida='$SALIDA'"
    python3 -c "
import json,sys,io
for l in io.open(r'$(cygpath -w "$TS_TMP/real.err")',encoding='utf-8'):
    if l.startswith('NVMETA '):
        d=json.loads(l[7:])
        sys.exit(0 if isinstance(d.get('ttft_ms'),int) and d['ttft_ms']>0 else 1)
sys.exit(1)" \
      && _ok "F2 mide el primer token real contra NVIDIA" \
      || _mal "F2 ttft real" "$(grep '^NVMETA' "$TS_TMP/real.err" | head -c 140)"
  fi
else
  echo "-- F. (chequeos contra NVIDIA salteados; corre con -v para incluirlos)"
fi

# --- I. La respuesta final saliendo por chunks (streaming visible, 2026-08-06) ----------------
# El motor emitia por chunks desde el 2026-08-03, pero la app mostraba todo de golpe: la respuesta
# viaja adentro de {"tool":"done","answer":"..."} y pintar los tokens crudos habria mostrado el
# JSON. answer_incremental va sacando el campo answer YA DES-ESCAPADO, aunque el JSON este cortado
# a la mitad de un "\uXXXX".
echo "-- I. la respuesta final, des-escapada, mientras llega"
if python3 "$TS_HERE/answer_incremental_casos.py" > "$TS_TMP/answer.out" 2>&1; then
  _ok "I1 reconstruye el answer trozo a trozo ($(grep -o 'casos: [0-9]*' "$TS_TMP/answer.out"))"
else
  _mal "I1 reconstruccion incremental del answer" "$(head -3 "$TS_TMP/answer.out" | tr '\n' ' ')"
fi

# Que el canal este CABLEADO de punta a punta. Sin esto, la funcion puede estar perfecta y no
# emitir nunca: fue exactamente el estado anterior (el motor streameaba hacia el vacio).
grep -q 'NV_ANSWER_STDERR' "$TS_ROOT/engine/ask-nvidia.sh" \
  && _ok "I2 ask-nvidia.sh le pasa NV_ANSWER_STDERR al helper" \
  || _mal "I2 ask-nvidia.sh no reenvia NV_ANSWER_STDERR" "el helper nunca lo prende"
grep -q 'NVANSWER ' "$TS_ROOT/engine/nv-agent.sh" \
  && _ok "I3 nv-agent.sh deja pasar las lineas NVANSWER en vivo" \
  || _mal "I3 nv-agent.sh manda todo el stderr al archivo temporal" "los chunks llegan cuando el turno ya termino"
grep -q "NV_ANSWER_STDERR: '1'" "$TS_ROOT/app/lib/mentis-process.js" \
  && _ok "I4 la app lo prende al arrancar el motor" \
  || _mal "I4 la app no prende NV_ANSWER_STDERR" "el streaming queda apagado en produccion"
grep -q "mentis:answer-chunk" "$TS_ROOT/app/main.js" && grep -q "onAnswerChunk" "$TS_ROOT/app/preload.js" \
  && grep -q "onAnswerChunk" "$TS_ROOT/app/renderer/renderer.js" \
  && _ok "I5 main -> preload -> renderer: el canal llega a la pantalla" \
  || _mal "I5 el canal se corta antes de la pantalla" "revisar main.js/preload.js/renderer.js"

# --- K. el canal EMITE de verdad (2026-08-18) ------------------------------------------------
#
# I2..I5 de arriba verifican el cableado con grep sobre el fuente. Estuvieron los cuatro en verde
# mientras el streaming NO mostraba nada en pantalla, y no es culpa de como estan escritos: un
# grep no puede ver que el cierre forzado mandaba su stderr a /dev/null, ni que el unico extractor
# que habia buscaba el campo "answer" de un JSON cuando los dos caminos mas frecuentes -- el
# cierre forzado y la charla directa -- devuelven prosa. Los de abajo EJECUTAN.
if python3 "$TS_HERE/stream_modo_auto_casos.py" > "$TS_TMP/modoauto.out" 2>&1; then
  _ok "K1 elige bien entre JSON y prosa ($(grep -o 'casos: [0-9]*' "$TS_TMP/modoauto.out"))"
else
  _mal "K1 la decision JSON/prosa" "$(head -3 "$TS_TMP/modoauto.out" | tr '
' ' ')"
fi
if node "$TS_HERE/stream-app-chunks.js" > "$TS_TMP/appchunks.out" 2>&1; then
  _ok "K2 la app arma las lineas aunque el chunk corte al medio ($(grep -o 'casos: [0-9]*' "$TS_TMP/appchunks.out"))"
else
  _mal "K2 la app pierde texto con chunks partidos" "$(head -3 "$TS_TMP/appchunks.out" | tr '
' ' ')"
fi
# Los dos caminos de prosa tienen que PEDIR el modo crudo. Esto si es cableado, pero es cableado
# que los tests de ejecucion de arriba no pueden alcanzar (dependen de que conteste el modelo).
grep -q 'NV_ANSWER_RAW=1 bash' "$TS_ROOT/engine/nv-agent.sh" \
  && _ok "K3 el cierre forzado pide modo crudo" \
  || _mal "K3 el cierre forzado no pide modo crudo" "vuelve a quedar mudo cuando contesta en prosa"
grep -q 'NV_ANSWER_RAW=1 bash' "$TS_ROOT/mentis-chat.sh" \
  && _ok "K4 la charla directa pide modo crudo" \
  || _mal "K4 la charla directa no pide modo crudo" "el turno mas comun vuelve a quedar mudo"
grep -q 'NV_ANSWER_RAW' "$TS_ROOT/engine/ask-nvidia.sh" \
  && _ok "K5 ask-nvidia.sh propaga el modo crudo al helper" \
  || _mal "K5 ask-nvidia.sh no propaga NV_ANSWER_RAW" "el helper nunca lo ve"

# --- J. Los presupuestos alcanzan para los modelos que estan cableados (2026-08-06) -----------
# Los valores viejos (12 s interactivo) salieron de medir el peor primer token de los modelos de un
# el mejor de todos -- quedaba descartado por TRES SEGUNDOS, y el rol caia al fallback en el 100%
# de los turnos. Un presupuesto no es un numero de estilo: decide que modelos puede usar el sistema.
#
# Este chequeo es un piso, no una medicion: si alguien baja los plazos sin volver a medir, avisa.
echo "-- J. los presupuestos dejan pasar a los modelos cableados"
TS_ASK="$TS_ROOT/engine/ask-nvidia.sh"
source "$TS_ROOT/engine/nv-lib.sh" 2>/dev/null
source "$TS_ROOT/engine/nv-modelos-lib.sh" 2>/dev/null
if type -t nv_ttft_rol >/dev/null 2>&1; then
  # Peor primer token medido (8 rondas x 2 tipos de prompt, 2026-08-06), en segundos:
  #   interactivo: glm-5.2 13,1   |   deliberativo: nemotron-3-ultra 39,4
  TS_INT="$(nv_ttft_rol "$TS_ASK")"
  TS_DEL="$(nv_ttft_rol code "$TS_ASK")"
  if [ "${TS_INT:-0}" -ge 14 ]; then
    _ok "J1 el presupuesto interactivo (${TS_INT}s) deja pasar a glm-5.2 (13,1 s medidos)"
  else
    _mal "J1 presupuesto interactivo demasiado corto (${TS_INT}s)" "glm-5.2 tarda hasta 13,1 s: con esto vuelve a caer al fallback siempre"
  fi
  if [ "${TS_DEL:-0}" -ge 40 ]; then
    _ok "J2 el presupuesto deliberativo (${TS_DEL}s) deja pasar a nemotron-3-ultra (39,4 s medidos)"
  else
    _mal "J2 presupuesto deliberativo demasiado corto (${TS_DEL}s)" "nemotron-3-ultra tarda hasta 39,4 s en dar señal"
  fi
else
  _mal "J no pude leer los presupuestos" "falta nv_ttft_rol"
fi

# La instrumentacion que permitio decidir todo esto: sin separar "primera señal de vida" de "primer
# contenido", no se puede distinguir un modelo que piensa de uno que no contesta.
grep -q "ttfc_ms" "$TS_ROOT/engine/nv_stream.py" \
  && _ok "J3 el motor reporta el primer contenido aparte de la primera señal" \
  || _mal "J3 se perdio la instrumentacion de ttfc_ms" "sin eso no se pueden recalibrar los presupuestos"

echo
echo "== $TS_OK OK, $TS_MAL MAL =="
[ "$TS_MAL" -eq 0 ]
