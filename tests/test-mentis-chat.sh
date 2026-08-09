#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DIR/mentis-chat.sh"
fail=0

_norm_path() {
  # Normalize path using Python to handle escaping correctly
  python3 -c "
import sys, re
p = sys.argv[1]
# Convert C:/ or C:\ to /c/
p = re.sub(r'^[cC]:', '/c', p)
# Convert backslashes to forward slashes
p = p.replace('\\\\', '/')
# Remove redundant slashes
p = re.sub(r'/+', '/', p)
print(p)
" "$1"
}

chk() {
  local got="$1" want="$2" msg="$3"
  got="$(_norm_path "$got")"
  want="$(_norm_path "$want")"
  [ "$got" = "$want" ] && echo "ok: $msg" || { echo "FAIL: $msg (got: $got / want: $want)"; fail=1; }
}

TMPENV="$(mktemp -d)"
trap 'rm -rf "$TMPENV"' EXIT
STATEFILE="$TMPENV/state.json"
WORKSPACE_DEFAULT="$TMPENV/workspace"

# --- sin state.json y sin -d: usa el default y lo crea ---
r="$(_mc_resolve_root "")"
chk "$r" "$(cd "$TMPENV/workspace" && pwd)" "resuelve al default cuando no hay state ni -d"
[ -d "$TMPENV/workspace" ] && echo "ok: crea la carpeta workspace por defecto" || { echo "FAIL: no creo workspace"; fail=1; }

# --- con -d explicito: usa ese, y lo persiste ---
mkdir -p "$TMPENV/otro"
r="$(_mc_resolve_root "$TMPENV/otro")"
chk "$r" "$(cd "$TMPENV/otro" && pwd)" "usa -d cuando se pasa explicito"

# --- sin -d pero con state.json ya guardado: reusa el ultimo root ---
r2="$(_mc_resolve_root "")"
chk "$r2" "$(cd "$TMPENV/otro" && pwd)" "reusa el ultimo root guardado en state.json cuando no hay -d"

# --- state.json corrupto: cae al default sin abortar ---
echo "esto no es json" > "$STATEFILE"
r3="$(_mc_resolve_root "")"
chk "$r3" "$(cd "$TMPENV/workspace" && pwd)" "state.json corrupto -> cae al default sin abortar"

# --- -d con ruta inexistente: rechaza con error, NUNCA cae al cwd ni al default ---
if r_bad="$(_mc_resolve_root "$TMPENV/esta-carpeta-no-existe" 2>/dev/null)"; then
  echo "FAIL: -d con ruta inexistente deberia fallar (return 1), pero devolvio: $r_bad"; fail=1
else
  echo "ok: -d con ruta inexistente rechaza con return 1 (no cae a cwd ni a default)"
fi

# Se verifica aca (no junto a los demas tests de -H, mas abajo) porque el bloque de
# "historial: append + tail + to-context" que sigue reasigna HISTFILE a mano sin
# subshell para probar _mc_append_history/_mc_tail_history -- si este chk se insertara
# despues de eso (como sugiere literalmente la ubicacion del brief), siempre fallaria
# por contaminacion ajena a esta task, no por un problema real del flag -H.
chk "$HISTFILE" "$DIR/history.jsonl" "sin -H, HISTFILE por defecto sigue siendo el global de siempre"

# --- historial: append + tail + to-context ---
HISTFILE="$TMPENV/history.jsonl"
_mc_append_history "usuario" "hola mentis"
_mc_append_history "mentis" "hola usuario, como puedo ayudar"
tail_out="$(_mc_tail_history 20)"
lines="$(printf '%s\n' "$tail_out" | grep -c '.')"
chk "$lines" "2" "tail_history devuelve las lineas escritas"

ctx="$(_mc_history_to_context "$tail_out")"
case "$ctx" in *"Vos: hola mentis"*"Mentis: hola usuario, como puedo ayudar"*) echo "ok: history_to_context arma el texto legible en orden";; *) echo "FAIL: history_to_context ($ctx)"; fail=1;; esac

ctx_empty="$(_mc_history_to_context "")"
chk "$ctx_empty" "(sin historial previo)" "history_to_context con historial vacio da placeholder"

# --- regresion ERR-014/017/020/021: tildes/acentos no deben corromperse (mojibake cp1252 / CRLF) ---
HISTFILE_UTF8="$TMPENV/history-utf8.jsonl"
MSG_TILDES="¿qué archivo creaste antes? áéíóúñ"
HISTFILE="$HISTFILE_UTF8" _mc_append_history "usuario" "$MSG_TILDES"
HISTFILE="$HISTFILE_UTF8" _mc_append_history "mentis" "Creé config.json con ñ y tildes: café, acción"

# nivel de bytes: el archivo en disco debe ser UTF-8 valido, sin el caracter de reemplazo (mojibake)
if grep -qP '\xef\xbf\xbd' "$HISTFILE_UTF8" 2>/dev/null; then
  echo "FAIL: history.jsonl contiene el caracter de reemplazo unicode (mojibake cp1252)"; fail=1
else
  echo "ok: history.jsonl no contiene mojibake (append_history escribe UTF-8 real)"
fi
if file -i "$HISTFILE_UTF8" 2>/dev/null | grep -qi 'charset=utf-8'; then
  echo "ok: history.jsonl es UTF-8 valido segun 'file -i'"
else
  echo "FAIL: history.jsonl no fue detectado como UTF-8 por 'file -i'"; fail=1
fi

tail_utf8="$(HISTFILE="$HISTFILE_UTF8" _mc_tail_history 20)"
case "$tail_utf8" in *"$MSG_TILDES"*) echo "ok: tail_history devuelve el mensaje con tildes sin corromper";; *) echo "FAIL: tail_history corrompio tildes ($tail_utf8)"; fail=1;; esac

ctx_utf8="$(_mc_history_to_context "$tail_utf8")"
case "$ctx_utf8" in *"Vos: $MSG_TILDES"*"Mentis: Creé config.json con ñ y tildes: café, acción"*) echo "ok: history_to_context devuelve tildes/acentos sin corromper";; *) echo "FAIL: history_to_context corrompio tildes ($ctx_utf8)"; fail=1;; esac

# nivel de bytes: el texto armado por history_to_context no debe tener CRLF (0d0a) entre lineas
if printf '%s' "$ctx_utf8" | xxd | grep -q '0d0a'; then
  echo "FAIL: history_to_context introduce CRLF (0d0a) en vez de LF"; fail=1
else
  echo "ok: history_to_context no introduce CRLF, solo LF"
fi

for i in 1 2 3 4 5; do _mc_append_history "usuario" "mensaje $i"; done
tail3="$(_mc_tail_history 3)"
n3="$(printf '%s\n' "$tail3" | grep -c '.')"
chk "$n3" "3" "tail_history respeta el limite N pedido"

# --- build_task combina persona + historial + mensaje nuevo ---
task="$(_mc_build_task "Vos: hola" "que hora es")"
case "$task" in *"$MC_PERSONA"*"Vos: hola"*"que hora es"*) echo "ok: build_task combina persona + historial + mensaje";; *) echo "FAIL: build_task"; fail=1;; esac

# --- fecha/hora reales en el prompt (bug 2026-07-28: Mentis INVENTABA la hora) ---
# Se compara contra `date` en el momento, no contra un valor fijo: lo que se prueba es que el
# prompt lleve el reloj REAL de la maquina, que es exactamente lo que faltaba.
HORA_REAL="$(date '+%H:%M')"
case "$task" in *"CUANDO ES AHORA"*) echo "ok: build_task incluye la seccion de fecha/hora";; *) echo "FAIL: build_task no inyecta la fecha/hora (Mentis va a inventarla)"; fail=1;; esac
case "$task" in *"$HORA_REAL"*) echo "ok: build_task inyecta la hora REAL del reloj, no una inventada";; *) echo "FAIL: la hora del prompt no coincide con el reloj ($HORA_REAL)"; fail=1;; esac
case "$(nv_ahora_texto)" in *"$(date '+%Y')"*) echo "ok: nv_ahora_texto arma la fecha en castellano con el anio real";; *) echo "FAIL: nv_ahora_texto no devuelve el anio real"; fail=1;; esac
# El rol 'fast' saltea build_task (llamada directa a ask-nvidia.sh), asi que su system prompt
# tiene que traer la hora por su cuenta -- si no, vuelve el bug por el camino del cerebro rapido.
if grep -q 'SYS_FAST=".*\${SYS_AHORA}"' "$DIR/engine/ask-nvidia.sh"; then
  echo "ok: el rol fast tambien lleva la fecha/hora en su system prompt"
else
  echo "FAIL: SYS_FAST no incluye SYS_AHORA -- el cerebro rapido vuelve a inventar la hora"; fail=1
fi
# nv-lib.sh cargado de verdad: si falta, nv_track_bg_pid no existe y los procesos de fondo del
# chat quedan huerfanos de MENTIS_PIDFILE ("Frenar ya" no los mata). Bug real, 2026-07-28.
if [ "$(type -t nv_track_bg_pid)" = "function" ]; then
  echo "ok: nv-lib.sh esta cargado (nv_track_bg_pid disponible para 'Frenar ya')"
else
  echo "FAIL: nv_track_bg_pid no existe -- los PIDs de fondo no se registran"; fail=1
fi

# --- count_actions cuenta writes/execs de un log simulado (intentos, no solo exitos) ---
FAKELOG="[nv-agent] tarea: x
[nv-agent] iter 1: write archivo.txt
[nv-agent] iter 2: exec RECHAZADO (sin -w)
[nv-agent] iter 3: exec (exit 0)
[nv-agent] iter 4: read algo.txt
[nv-agent] iter 5: done"
read -r W E <<< "$(_mc_count_actions "$FAKELOG")"
chk "$W" "1" "count_actions cuenta 1 write"
chk "$E" "2" "count_actions cuenta 2 exec (exitoso + rechazado, son intentos)"

# --- /stats y salir funcionan sin llamar a NIM (regresion de plomeria, no de red) ---
TESTROOT="$TMPENV/testroot-loop"
mkdir -p "$TESTROOT"
OUT="$(printf '/stats\nsalir\n' | HISTFILE="$TMPENV/history-loop.jsonl" STATEFILE="$TMPENV/state-loop.json" WORKSPACE_DEFAULT="$TMPENV/workspace-loop" bash "$DIR/mentis-chat.sh" -d "$TESTROOT" 2>&1)"
case "$OUT" in *"turnos: 0"*) echo "ok: /stats funciona sin llamar a nv-agent.sh (0 turnos antes de cualquier mensaje real)";; *) echo "FAIL: /stats no mostro turnos: 0 ($OUT)"; fail=1;; esac
case "$OUT" in *"root: $(cd "$TESTROOT" && pwd)"*) echo "ok: el loop reporta el root correcto";; *) echo "FAIL: root incorrecto en /stats"; fail=1;; esac

# --- Task capabilities: carga, match, run (capability fake) ---
CAPDIR1="$TMPENV/capabilities-unit"
mkdir -p "$CAPDIR1"
cat > "$CAPDIR1/fake.sh" <<'EOF'
# CAPABILITY: /fake | capability de prueba
printf 'resultado fake: %s' "$1"
EOF

CAPABILITIES_DIR="$CAPDIR1"
_mc_load_capabilities
rc="$?"
chk "$rc" "0" "load_capabilities carga sin error con un capability valido"
chk "${MC_CAPS[/fake]:-}" "$CAPDIR1/fake.sh" "load_capabilities registra la ruta del capability /fake"
chk "${MC_CAP_DESC[/fake]:-}" "capability de prueba" "load_capabilities registra la descripcion del capability /fake"

m="$(_mc_match_capability "/fake hola")"
chk "$m" "/fake" "match_capability matchea /fake con resto"

m2="$(_mc_match_capability "/fake")"
chk "$m2" "/fake" "match_capability matchea /fake exacto (sin resto)"

m3="$(_mc_match_capability "/fakefoo")"
chk "$m3" "" "match_capability NO matchea /fakefoo (exige espacio o fin de string, no substring)"

m4="$(_mc_match_capability "hola")"
chk "$m4" "" "match_capability no matchea un mensaje sin ningun prefijo registrado"

r="$(_mc_run_capability "$CAPDIR1/fake.sh" "algo")"
chk "$r" "resultado fake: algo" "run_capability ejecuta el capability y devuelve su output"

# --- colision de prefijos: dos capabilities con el mismo prefijo ---
CAPDIR2="$TMPENV/capabilities-collision"
mkdir -p "$CAPDIR2"
printf '# CAPABILITY: /dup | uno\n' > "$CAPDIR2/a.sh"
printf '# CAPABILITY: /dup | dos\n' > "$CAPDIR2/b.sh"
CAPABILITIES_DIR="$CAPDIR2"
_mc_load_capabilities 2>/dev/null
rc2="$?"
chk "$rc2" "1" "load_capabilities rechaza dos capabilities con el mismo prefijo"

# --- prefijo reservado: un capability declara /stats ---
CAPDIR3="$TMPENV/capabilities-reserved"
mkdir -p "$CAPDIR3"
printf '# CAPABILITY: /stats | pisa el reservado\n' > "$CAPDIR3/bad.sh"
CAPABILITIES_DIR="$CAPDIR3"
_mc_load_capabilities 2>/dev/null
rc3="$?"
chk "$rc3" "1" "load_capabilities rechaza un capability que usa un prefijo reservado (/stats)"

# --- carpeta de capabilities vacia o inexistente: no rompe, deja MC_CAPS vacio ---
CAPABILITIES_DIR="$TMPENV/no-existe-esta-carpeta"
MC_CAPS=(); MC_CAP_DESC=()
_mc_load_capabilities
rc4="$?"
chk "$rc4" "0" "load_capabilities no falla si la carpeta de capabilities no existe"
m5="$(_mc_match_capability "/recall algo")"
chk "$m5" "" "match_capability no matchea nada si no se cargo ningun capability"

# --- integracion: el loop dispatchea un capability sin llamar a nv-agent.sh ---
CAPDIR_LOOP="$TMPENV/capabilities-loop"
mkdir -p "$CAPDIR_LOOP"
cat > "$CAPDIR_LOOP/fake.sh" <<'EOF'
# CAPABILITY: /fake | capability de prueba para el loop
printf 'resultado fake: %s' "$1"
EOF
TESTROOT_CAP="$TMPENV/testroot-cap"
mkdir -p "$TESTROOT_CAP"
OUT_CAP="$(printf '/fake hola\n/stats\nsalir\n' | CAPABILITIES_DIR="$CAPDIR_LOOP" HISTFILE="$TMPENV/history-cap.jsonl" STATEFILE="$TMPENV/state-cap.json" WORKSPACE_DEFAULT="$TMPENV/workspace-cap" bash "$DIR/mentis-chat.sh" -d "$TESTROOT_CAP" 2>&1)"
case "$OUT_CAP" in *"Mentis: resultado fake: hola"*) echo "ok: el loop dispatchea el capability /fake y muestra su output";; *) echo "FAIL: el loop no mostro el output del capability ($OUT_CAP)"; fail=1;; esac
case "$OUT_CAP" in *"turnos: 0"*) echo "ok: dispatchear un capability NO cuenta como turno de nv-agent.sh";; *) echo "FAIL: el capability conto como turno real ($OUT_CAP)"; fail=1;; esac
case "$OUT_CAP" in *"/fake"*"capability de prueba para el loop"*) echo "ok: el mensaje de bienvenida lista el capability cargado dinamicamente";; *) echo "FAIL: la ayuda dinamica no listo /fake ($OUT_CAP)"; fail=1;; esac

# --- capability con carpeta invalida (colision) aborta el arranque del script ---
CAPDIR_BAD="$TMPENV/capabilities-loop-bad"
mkdir -p "$CAPDIR_BAD"
printf '# CAPABILITY: /dup | uno\n' > "$CAPDIR_BAD/a.sh"
printf '# CAPABILITY: /dup | dos\n' > "$CAPDIR_BAD/b.sh"
OUT_BAD="$(printf 'salir\n' | CAPABILITIES_DIR="$CAPDIR_BAD" HISTFILE="$TMPENV/history-bad.jsonl" STATEFILE="$TMPENV/state-bad.json" WORKSPACE_DEFAULT="$TMPENV/workspace-bad" bash "$DIR/mentis-chat.sh" -d "$TESTROOT_CAP" 2>&1)"
RC_BAD="$?"
chk "$RC_BAD" "1" "el script aborta el arranque si hay capabilities con prefijo duplicado"

# --- los 3 capabilities reales cargan sin error y quedan registrados (no se ejecutan) ---
CAPABILITIES_DIR="$DIR/capabilities"
MC_CAPS=(); MC_CAP_DESC=()
_mc_load_capabilities
rc5="$?"
chk "$rc5" "0" "los 3 capabilities reales cargan sin error (sin colision, sin prefijo reservado)"
chk "${MC_CAPS[/recall]:+registrado}" "registrado" "capability real /recall registrado"
chk "${MC_CAPS[/where]:+registrado}" "registrado" "capability real /where registrado"
chk "${MC_CAPS[/aprender]:+registrado}" "registrado" "capability real /aprender registrado"

# --- al salir, si hay un daemon de navegador vivo (simulado), se le pide /shutdown ---
FAKE_BROWSER_PORT_FILE="$TMPENV/fake-browser-port.txt"
node -e '
const http = require("http");
let shutdownCalled = false;
const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, {"Content-Type": "application/json"});
    res.end(JSON.stringify({ok: true}));
    return;
  }
  if (req.method === "POST" && req.url === "/shutdown") {
    shutdownCalled = true;
    res.writeHead(200, {"Content-Type": "application/json"});
    res.end(JSON.stringify({ok: true}));
    require("fs").writeFileSync(process.argv[2], "CALLED");
    setTimeout(() => process.exit(0), 50);
    return;
  }
  res.writeHead(404); res.end();
});
server.listen(0, "127.0.0.1", () => {
  const {port} = server.address();
  require("fs").writeFileSync(process.argv[1], JSON.stringify({pid: process.pid, port}));
});
' "$TMPENV/fake-browser-state.json" "$FAKE_BROWSER_PORT_FILE" &
FAKE_SERVER_PID=$!
sleep 1

TESTROOT_BROWSE="$TMPENV/testroot-browse"
mkdir -p "$TESTROOT_BROWSE"
printf 'salir\n' | BROWSER_STATE_FILE="$TMPENV/fake-browser-state.json" HISTFILE="$TMPENV/history-browse.jsonl" STATEFILE="$TMPENV/state-browse.json" WORKSPACE_DEFAULT="$TMPENV/workspace-browse" CAPABILITIES_DIR="$DIR/capabilities" bash "$DIR/mentis-chat.sh" -d "$TESTROOT_BROWSE" >/dev/null 2>&1

sleep 0.3
if [ -f "$FAKE_BROWSER_PORT_FILE" ] && [ "$(cat "$FAKE_BROWSER_PORT_FILE")" = "CALLED" ]; then
  echo "ok: mentis-chat.sh pide /shutdown al daemon de navegador al salir"
else
  echo "FAIL: mentis-chat.sh no pidio /shutdown al salir"; fail=1
fi
kill "$FAKE_SERVER_PID" 2>/dev/null || true

# --- al salir, si hay un puente MCP vivo (simulado), se le pide /shutdown ---
FAKE_MCP_PORT_FILE="$TMPENV/fake-mcp-port.txt"
node -e '
const http = require("http");
const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, {"Content-Type": "application/json"});
    res.end(JSON.stringify({ok: true}));
    return;
  }
  if (req.method === "POST" && req.url === "/shutdown") {
    res.writeHead(200, {"Content-Type": "application/json"});
    res.end(JSON.stringify({ok: true}));
    require("fs").writeFileSync(process.argv[2], "CALLED");
    setTimeout(() => process.exit(0), 50);
    return;
  }
  res.writeHead(404); res.end();
});
server.listen(0, "127.0.0.1", () => {
  const {port} = server.address();
  require("fs").writeFileSync(process.argv[1], JSON.stringify({pid: process.pid, port}));
});
' "$TMPENV/fake-mcp-state.json" "$FAKE_MCP_PORT_FILE" &
FAKE_MCP_SERVER_PID=$!
sleep 1

TESTROOT_MCP="$TMPENV/testroot-mcp"
mkdir -p "$TESTROOT_MCP"
printf 'salir\n' | MCP_BRIDGE_STATE_FILE="$TMPENV/fake-mcp-state.json" HISTFILE="$TMPENV/history-mcp.jsonl" STATEFILE="$TMPENV/state-mcp.json" WORKSPACE_DEFAULT="$TMPENV/workspace-mcp" CAPABILITIES_DIR="$DIR/capabilities" bash "$DIR/mentis-chat.sh" -d "$TESTROOT_MCP" >/dev/null 2>&1

sleep 0.3
if [ -f "$FAKE_MCP_PORT_FILE" ] && [ "$(cat "$FAKE_MCP_PORT_FILE")" = "CALLED" ]; then
  echo "ok: mentis-chat.sh pide /shutdown al puente MCP al salir"
else
  echo "FAIL: mentis-chat.sh no pidio /shutdown al puente MCP al salir"; fail=1
fi
kill "$FAKE_MCP_SERVER_PID" 2>/dev/null || true

# --- Task app: flag -H redirige el historial a una ruta custom ---
# (el chk de "sin -H, HISTFILE por defecto" se movio mas arriba, antes del bloque de
# "historial: append + tail + to-context" -- ver comentario ahi)

# Con -H, un turno real completo escribe en la ruta custom (no en el archivo global)
TESTROOT_H="$TMPENV/testroot-histflag"
mkdir -p "$TESTROOT_H"
CUSTOM_HIST="$TMPENV/conversacion-custom.jsonl"
OUT_H="$(printf 'decime "ok flag H" y nada mas\nsalir\n' | STATEFILE="$TMPENV/state-histflag.json" WORKSPACE_DEFAULT="$TMPENV/workspace-histflag" CAPABILITIES_DIR="$DIR/capabilities" bash "$DIR/mentis-chat.sh" -d "$TESTROOT_H" -H "$CUSTOM_HIST" 2>&1)"

if [ -f "$CUSTOM_HIST" ]; then
  n_lineas="$(grep -c '.' "$CUSTOM_HIST" 2>/dev/null || echo 0)"
  chk "$n_lineas" "2" "-H hace que un turno real escriba exactamente 2 lineas (usuario+mentis) en la ruta custom"
  if grep -q '"role": "usuario"' "$CUSTOM_HIST" && grep -q '"role": "mentis"' "$CUSTOM_HIST"; then
    echo "ok: la ruta custom tiene una entrada de usuario y una de mentis"
  else
    echo "FAIL: la ruta custom no tiene las entradas esperadas ($CUSTOM_HIST)"; fail=1
  fi
else
  echo "FAIL: -H no genero el archivo en la ruta custom ($OUT_H)"; fail=1
fi

exit $fail
