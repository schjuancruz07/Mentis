#!/usr/bin/env bash
# mentis-chat.sh — loop de chat en terminal con Mentis como asistente principal.
# Reusa nv-agent.sh -w como motor de ejecución por turno (sin modificarlo).
#
# Uso: mentis-chat.sh [-d <root>] [-i <presupuesto>] [-m <rol>] [-H <ruta_historial>]
#   -d  directorio raíz (default: el usado la última vez, o ~/Mentis/workspace/)
#   -i  presupuesto de iteraciones por turno de nv-agent.sh (default 10)
#   -m  rol/modelo de ask-nvidia (default reason)
#   -H  ruta de archivo de historial a usar en vez del global (para conversaciones separadas,
#       ej. la app de escritorio le da un archivo propio a cada conversación). Sin -H, usa el
#       archivo global de siempre ($MENTIS_ENV_DIR/history.jsonl).
set -uo pipefail
MENTIS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTFILE="$MENTIS_ENV_DIR/history.jsonl"
STATEFILE="$MENTIS_ENV_DIR/state.json"
WORKSPACE_DEFAULT="$MENTIS_ENV_DIR/workspace"
CAPABILITIES_DIR="${CAPABILITIES_DIR:-$MENTIS_ENV_DIR/capabilities}"
BROWSER_STATE_FILE="${BROWSER_STATE_FILE:-$MENTIS_ENV_DIR/browser-daemon-state.json}"
# Modelos personalizados por rol (pedido del usuario, 2026-07-13): exportado ACA para que
# ask-nvidia.sh lo vea sin importar si lo llama nv-agent.sh, nv-verify.sh, o mentis-chat.sh
# directo (auto-memoria) -- todos son subprocesos de esta sesion, heredan el export.
export MENTIS_SETTINGS_FILE="$MENTIS_ENV_DIR/mentis-settings.json"

# nv-lib.sh FALTABA por completo (bug encontrado 2026-07-28): este script ya llamaba
# nv_track_bg_pid en 4 lugares (Kai Vault, nv-verify x2, el tee de progreso) sin tener la
# libreria cargada. Como aca corre `set -uo pipefail` SIN -e, cada llamada tiraba
# "command not found" (rc=127) a stderr y el turno seguia como si nada -- asi que los PIDs de
# fondo del CHAT nunca se anotaron en MENTIS_PIDFILE y "Frenar ya" no podia matarlos (justo el
# agujero que ERR-034 vino a tapar). Tambien provee nv_ahora_texto, que usa _mc_build_task.
# Va ACA ARRIBA y no junto al source de nv-classify-lib.sh (mucho mas abajo) a proposito: cuando
# los tests hacen `source mentis-chat.sh` la ejecucion no llega hasta alla, asi que un source
# tardio dejaria a _mc_build_task sin la funcion justo en el entorno donde se lo prueba.
# shellcheck source=/dev/null
source "$MENTIS_ENV_DIR/engine/nv-lib.sh"
# Modos (2026-08-10). Va acá arriba por el mismo motivo que el de nv-lib.sh: los tests sourcean
# este archivo y nunca llegan al cuerpo, así que un source tardío dejaría sin funciones justo al
# entorno donde se prueba.
# shellcheck source=/dev/null
source "$MENTIS_ENV_DIR/engine/nv-modos-lib.sh"

_mc_shutdown_browser_daemon() {
  [ -f "$BROWSER_STATE_FILE" ] || return 0
  local port
  port="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("port",""), end="")
except Exception:
    print("", end="")
' "$BROWSER_STATE_FILE" 2>/dev/null)"
  [ -n "$port" ] || return 0
  curl -s -m 3 -X POST "http://127.0.0.1:$port/shutdown" >/dev/null 2>&1 || true
}
MCP_BRIDGE_STATE_FILE="${MCP_BRIDGE_STATE_FILE:-$MENTIS_ENV_DIR/mcp-bridge-state.json}"

_mc_shutdown_mcp_bridge() {
  [ -f "$MCP_BRIDGE_STATE_FILE" ] || return 0
  local port
  port="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("port",""), end="")
except Exception:
    print("", end="")
' "$MCP_BRIDGE_STATE_FILE" 2>/dev/null)"
  [ -n "$port" ] || return 0
  curl -s -m 3 -X POST "http://127.0.0.1:$port/shutdown" >/dev/null 2>&1 || true
}
declare -A MC_CAPS=()
declare -A MC_CAP_DESC=()
MC_RESERVED_PREFIXES=("/stats" "salir" "exit")

_mc_load_state_root() {
  [ -f "$STATEFILE" ] || { printf ''; return 0; }
  python3 -c '
import json, sys
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("last_root",""), end="")
except Exception:
    print("", end="")
' "$STATEFILE" 2>/dev/null
}

_mc_save_state_root() {
  local root="$1"
  MC_ROOT_TO_SAVE="$root" python3 -c '
import json, os, sys
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
d = {"last_root": os.environ.get("MC_ROOT_TO_SAVE","")}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False)
' "$STATEFILE"
}

_mc_resolve_root() {
  local cli_root="$1" root
  if [ -n "$cli_root" ]; then
    root="$(cd "$cli_root" 2>/dev/null && pwd)" || { echo "ERROR: directorio no existe: $cli_root" >&2; return 1; }
  else
    root="$(_mc_load_state_root)"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
      mkdir -p "$WORKSPACE_DEFAULT"
      root="$(cd "$WORKSPACE_DEFAULT" && pwd)"
    fi
  fi
  _mc_save_state_root "$root"
  printf '%s' "$root"
}

_mc_append_history() {
  local role="$1" text="$2" artifacts="${3:-}" steps="${4:-}" model="${5:-}"
  # EL MODO QUEDA GUARDADO EN CADA ENTRADA (2026-08-12, pedido del usuario: un historial por modo para
  # no tener que buscar entre todos los chats). Se guarda por ENTRADA y no una vez por
  # conversacion porque el modo se puede cambiar en el medio de una charla: asi la conversacion
  # queda clasificada por el modo en el que arranco, y el dato del cambio no se pierde.
  # Las conversaciones anteriores a hoy no tienen este campo -- por eso la app las agrupa aparte
  # en vez de asumirles un modo que nadie eligio.
  MC_ROLE="$role" MC_TEXT="$text" MC_ARTIFACTS="$artifacts" MC_STEPS="$steps" MC_MODEL="$model" \
  MC_MODO_ENTRADA="${MC_MODO_TURNO:-$(nv_modo_actual 2>/dev/null || echo '')}" python3 -c '
import json, os, sys, datetime
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
arts = [a for a in os.environ.get("MC_ARTIFACTS","").split("\n") if a.strip()]
steps = [s for s in os.environ.get("MC_STEPS","").split("\n") if s.strip()]
model = os.environ.get("MC_MODEL","").strip()
d = {"role": os.environ.get("MC_ROLE",""), "text": os.environ.get("MC_TEXT",""), "ts": datetime.datetime.now().isoformat()}
if arts:
    d["artifacts"] = arts
if steps:
    d["steps"] = steps
# Panel de estadisticas (pedido del usuario, 2026-07-13, "modelo favorito"): que cerebro atendio ESTE
# turno -- no existia antes, entradas viejas del historial no van a tener este campo.
if model:
    d["model"] = model
modo = os.environ.get("MC_MODO_ENTRADA","").strip()
if modo:
    d["modo"] = modo
print(json.dumps(d, ensure_ascii=False))
' >> "$HISTFILE"
}

# Formacion automatica de memoria (2026-07-12, "memoria a la par de la tuya" -- pedido de
# el usuario): despues de cada turno, un modelo barato (rol 'extract', temp baja) evalua si el
# intercambio trae algo digno de recordar PERMANENTEMENTE (preferencia, correccion, decision de
# proyecto, dato de referencia) -- igual que Claude Code guarda memoria proactivamente sin que
# se lo pidan. Corre en BACKGROUND (no bloquea el turno del usuario); si no hay nada memorable, el
# modelo responde "NADA" y no se guarda nada.
# REEMPLAZADO POR mentis-aprender.sh (2026-07-27) -- ver ERR-082.
# Esta version destilaba memorias pasandole al modelo el mensaje del usuario Y la respuesta de
# Mentis, sin mirar si el turno habia salido bien y guardando el resultado como verdad
# definitiva. En un solo dia produjo tres memorias falsas sobre el usuario (una nacida de una
# transcripcion rota, otra del propio mensaje de error de Mentis, y una tercera que era una
# memoria de esa memoria). Se conserva el nombre de la funcion porque el bucle de turnos la
# llama, pero ahora delega en el destilador con frenos.
_mc_auto_memory() {
  local msg="$1" answer="$2"
  local fallo="" confianza=""
  # REGLA 2: un turno que no llego a 'done' no ensena nada. nv-agent lo dice en su salida cruda
  # (STATUS=...) y mentis-chat ya la reescribe para el usuario, asi que se mira el texto reescrito.
  case "$answer" in
    "No pude terminar del todo esta tarea"*) fallo="--turno-fallo" ;;
  esac
  # REGLA 3: si el mensaje entro por voz, la confianza de la transcripcion viaja en esta
  # variable (la escribe la app antes de mandar el turno). Vacia = vino escrito, sin dudas.
  [ -n "${MENTIS_TURNO_CONFIANZA:-}" ] && confianza="--confianza ${MENTIS_TURNO_CONFIANZA}"
  (
    local archivo
    archivo="$(mktemp 2>/dev/null || echo "/tmp/aprender-$$")"
    printf '%s' "$msg" > "$archivo"
    bash "$MENTIS_ENV_DIR/mentis-aprender.sh" destilar "$archivo" $fallo $confianza >/dev/null 2>&1
    rm -f "$archivo"
  ) &
}

_mc_auto_memory_VIEJA_SIN_FRENOS() {
  local msg="$1" answer="$2"
  (
    local prompt resp tipo nombre contenido slugs_existentes
    slugs_existentes="$(grep -o '^- \[[a-z0-9-]*\]' "$MEMORIA_INDEX" 2>/dev/null | sed 's/^- \[//;s/\]$//' | tr '\n' ',' | sed 's/,$//')"
    prompt="Analizá este intercambio entre el usuario y Mentis. ¿Hay algo que valga la pena RECORDAR PERMANENTEMENTE sobre el usuario o el proyecto (una preferencia suya, una correccion de como trabajar, una decision de proyecto importante, un dato de referencia util) -- algo que Mentis deba saber en conversaciones FUTURAS, no solo en esta?

Mensaje del usuario: $msg

Respuesta de Mentis: $answer

Si NO hay nada memorable (charla casual, pregunta puntual sin info nueva para el futuro, etc.), respondé EXACTAMENTE: NADA

Si SI hay algo memorable, respondé en EXACTAMENTE 3 lineas, sin texto extra ni explicaciones:
TIPO: user|feedback|project|reference
NOMBRE: slug-corto-en-minusculas-con-guiones
CONTENIDO: una o dos oraciones con el hecho concreto a recordar. Si esta memoria esta relacionada con una ya existente, referenciala con [[slug-existente]] en el texto (NO inventes un slug que no este en esta lista de memorias ya guardadas: ${slugs_existentes:-ninguna todavia})"
    resp="$(printf '%s' "$prompt" | bash "$TOOLSDIR/ask-nvidia.sh" -r extract 2>/dev/null)"
    [ -z "$resp" ] && exit 0
    printf '%s' "$resp" | grep -qi '^NADA' && exit 0
    tipo="$(printf '%s' "$resp" | grep -i '^TIPO:' | head -1 | sed 's/^[Tt][Ii][Pp][Oo]: *//')"
    nombre="$(printf '%s' "$resp" | grep -i '^NOMBRE:' | head -1 | sed 's/^[Nn][Oo][Mm][Bb][Rr][Ee]: *//')"
    contenido="$(printf '%s' "$resp" | grep -i '^CONTENIDO:' | head -1 | sed 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Ii][Dd][Oo]: *//')"
    [ -z "$tipo" ] || [ -z "$nombre" ] || [ -z "$contenido" ] && exit 0
    bash "$MENTIS_ENV_DIR/mentis-memory.sh" save "$tipo" "auto-$nombre" "$contenido" "$contenido" >/dev/null 2>&1
  ) &
}

_mc_tail_history() {
  local n="${1:-20}"
  [ -f "$HISTFILE" ] || { printf ''; return 0; }
  tail -n "$n" "$HISTFILE"
}

# --- COMPACTACION DE CONTEXTO (2026-08-02, revision total) --------------------------------------
#
# EL PROBLEMA: arriba se mandan las ultimas 20 entradas y punto. Lo que queda mas atras NO se
# comprime: se CORTA. En una conversacion larga, lo que el usuario dijo en el mensaje 3 desaparece sin
# dejar rastro, y Mentis vuelve a preguntar cosas que ya le contaron. Habia un boton manual
# ("Resumir y empezar de nuevo") pero eso abre una conversacion NUEVA: sirve para arrancar limpio,
# no para seguir la misma charla con memoria.
#
# COMO SE RESUELVE: se mantiene un resumen corrido de todo lo que ya salio de la ventana. Se
# inyecta como un bloque aparte, rotulado como resumen y no como transcripcion, para que el modelo
# sepa que es una sintesis y no palabras textuales.
#
# LAS TRES DECISIONES QUE HACEN QUE ESTO NO CUESTE CARO:
#   1. Se compacta POR LOTES (cada 10 entradas que caen), no en cada turno. Si no, seria una
#      llamada extra al modelo por turno, que es exactamente el precio que hace que estas cosas
#      terminen apagadas (paso con la escalera de verificacion: 25 s -> 373 s, ver la memoria
#      mentis-kai-vault-y-voz).
#   2. Corre EN SEGUNDO PLANO despues del turno, como el aprendizaje. el usuario nunca lo espera.
#   3. El resumen vive en un archivo al lado del historial. Leerlo cuesta un 'cat', no un modelo.
#
# Si el resumen falla o no existe, el comportamiento es identico al de antes: las ultimas 20 y
# nada mas. Degradar bien importa mas que comprimir.
MC_COMPACTAR_CADA="${MC_COMPACTAR_CADA:-10}"   # cuantas entradas caidas se juntan antes de resumir
MC_VENTANA=20                                   # cuantas entradas van textuales (las de _mc_tail_history)

_mc_resumen_file() {
  [ -n "${HISTFILE:-}" ] || { printf ''; return 0; }
  printf '%s.resumen' "$HISTFILE"
}

# Lo que se le inyecta al modelo. Barato: es leer un archivo.
_mc_load_resumen() {
  local f; f="$(_mc_resumen_file)"
  [ -n "$f" ] && [ -f "$f" ] || { printf ''; return 0; }
  tail -c 3000 "$f" 2>/dev/null || printf ''
}

# Se llama DESPUES de responderle al usuario. No bloquea nada.
_mc_compactar_bg() {
  [ -f "${HISTFILE:-/nonexistent}" ] || return 0
  (
    # Variables prefijadas MC_ a proposito (ERR-002): en Windows/Git Bash los nombres genericos
    # pisan variables del entorno. 'prompt' es el caso obvio, pero la regla se aplica a todas.
    local MC_TOT MC_HASTA MC_DESDE MC_NUEVAS MC_TROZO MC_PROMPT MC_RESP MC_F MC_META
    MC_F="$(_mc_resumen_file)"; MC_META="$MC_F.hasta"
    MC_TOT="$(wc -l < "$HISTFILE" 2>/dev/null | tr -d ' ')"
    [ -n "$MC_TOT" ] || exit 0
    # El :-0 va sobre la MISMA variable que se acaba de leer. Escribirlo sobre otra (paso al
    # renombrar las variables por ERR-002) deja MC_HASTA en 0 SIEMPRE: la compactacion cree que
    # nunca resumio nada y vuelve a resumir el mismo tramo en cada turno, gastando una llamada
    # cada vez. El sintoma era silencioso -- el resumen igual salia bien.
    MC_HASTA="$(cat "$MC_META" 2>/dev/null | tr -d ' \r\n')"; MC_HASTA="${MC_HASTA:-0}"
    # Entradas que YA salieron de la ventana textual y todavia no estan resumidas.
    MC_DESDE=$((MC_HASTA + 1))
    MC_NUEVAS=$(( MC_TOT - MC_VENTANA - MC_HASTA ))
    [ "$MC_NUEVAS" -ge "$MC_COMPACTAR_CADA" ] 2>/dev/null || exit 0

    # Se toma el tramo exacto: de 'desde' hasta 'total - ventana'.
    MC_TROZO="$(sed -n "${MC_DESDE},$((MC_TOT - MC_VENTANA))p" "$HISTFILE" 2>/dev/null \
             | python3 -c '
import json, sys
sys.stdin.reconfigure(encoding="utf-8", errors="replace")
for l in sys.stdin:
    l = l.strip()
    if not l: continue
    try: d = json.loads(l)
    except Exception: continue
    quien = "el usuario" if (d.get("role") or d.get("rol")) in ("user", "usuario") else "Mentis"
    txt = (d.get("content") or d.get("texto") or d.get("mensaje") or "")
    if txt: print("%s: %s" % (quien, str(txt)[:600]))
' 2>/dev/null | tr -d '\r')"
    [ -n "${MC_TROZO// }" ] || exit 0

    MC_PROMPT="Este es un tramo de una conversacion entre el usuario y su asistente Mentis que ya quedo fuera de la ventana de contexto.

RESUMEN DE LO ANTERIOR (puede estar vacio si es el primer tramo):
$(cat "$MC_F" 2>/dev/null | tail -c 2000)

TRAMO NUEVO A INCORPORAR:
$MC_TROZO

Devolve UN SOLO resumen actualizado que incorpore el tramo nuevo al resumen anterior, en 10 lineas como maximo. Guardate SOLO lo que sirva mas adelante: decisiones tomadas, datos concretos que el usuario dio sobre si mismo o su trabajo, cosas que quedaron pendientes, y preferencias que expreso. Tira la charla intrascendente y los detalles de ejecucion. No inventes nada que no este en el texto. Sin encabezados ni explicaciones: solo el resumen."

    MC_RESP="$(printf '%s' "$MC_PROMPT" | bash "$TOOLSDIR/ask-nvidia.sh" -r -q extract 2>/dev/null | tr -d '\r')"
    [ -n "${MC_RESP// }" ] || exit 0
    # Escritura atomica: un resumen a medias es peor que ninguno, porque se inyecta igual.
    printf '%s\n' "$MC_RESP" > "$MC_F.tmp" 2>/dev/null && mv -f "$MC_F.tmp" "$MC_F" 2>/dev/null
    printf '%s' "$((MC_TOT - MC_VENTANA))" > "$MC_META" 2>/dev/null
  ) &
}

# Memoria tipada (2026-07-12, ver mentis-memory.sh): se inyecta el INDICE completo (liviano,
# una linea por memoria) en cada turno -- el contenido completo de cada memoria individual
# (memoria/<slug>.md) NO se manda entero para no inflar el prompt; si Mentis necesita el detalle
# de una memoria puntual, puede leerla con la tool 'read' (memoria/<slug>.md esta dentro de su
# raiz de trabajo? NO -- vive en la raiz de Mentis, fuera de ROOT. Por eso el indice ya trae la
# descripcion completa de cada una, pensada para alcanzar sin tener que abrir el archivo).
MEMORIA_INDEX="$MENTIS_ENV_DIR/memoria/indice.md"

_mc_load_memory() {
  [ -f "$MEMORIA_INDEX" ] || { printf '(sin notas guardadas -- usa /recordar para guardar algo)'; return 0; }
  # REGLA 5 del learning loop (2026-07-27): al modelo SOLO le llegan las memorias FIRMES.
  # Las provisionales existen, se pueden ver y confirmar, pero no influyen en lo que Mentis
  # cree hasta que se confirmen. Esta linea es la que convierte las cinco reglas en una
  # garantia real: sin ella, una observacion suelta seguiria pesando igual que un hecho.
  # Las memorias sin campo 'estado' son anteriores a este sistema y se tratan como firmes.
  local salida
  salida="$(python3 "$MENTIS_ENV_DIR/engine/memorias_firmes.py" \
              --indice "$MEMORIA_INDEX" --memorias "$MENTIS_ENV_DIR/memoria" 2>/dev/null)"
  if [ -n "${salida// }" ]; then
    printf '%s' "$salida" | tail -c 4000
  else
    # Si el filtro falla por lo que sea, es preferible el indice completo a dejar a Mentis sin
    # ninguna memoria: perder contexto rompe mas que incluir una provisional de mas.
    tail -c 4000 "$MEMORIA_INDEX"
  fi
}

# Ubicacion real en CADA turno (pedido del usuario, 2026-07-25: "que sepa donde estoy en el saludo
# y en cualquier momento"). Antes esto no existia del lado del motor: la unica ubicacion vivia
# hardcodeada en el saludo de la app, asi que si el usuario le preguntaba a Mentis donde estaba, no
# tenia forma de saberlo.
#
# NUNCA bloquea el turno: se lee el cache que dejo mentis-location.sh (aunque este vencido) y,
# si hace falta refrescar, se dispara la medicion en SEGUNDO PLANO para el turno siguiente. Una
# medicion real tarda ~3 s (PowerShell + WiFi + Nominatim) y hacer esperar eso en cada mensaje
# seria pagar un impuesto de latencia por un dato que casi nunca cambia entre turno y turno.
LOCATION_CACHE_FILE="$MENTIS_ENV_DIR/location-cache.json"
_mc_load_location() {
  local edad=999999
  if [ -f "$LOCATION_CACHE_FILE" ]; then
    edad="$(LOC_F="$LOCATION_CACHE_FILE" python3 -c '
import json, os, time
try:
    d = json.load(open(os.environ["LOC_F"], encoding="utf-8"))
    print(int(time.time() - float(d.get("medido_en", 0))))
except Exception:
    print(999999)
' 2>/dev/null || echo 999999)"
  fi
  # Refresco en background si el dato pasa los 15 min (o si nunca se midio).
  if [ "$edad" -gt 900 ] 2>/dev/null; then
    # OJO con el patron `( cmd & )`: el `$!` del shell padre NO ve el proceso lanzado dentro del
    # subshell -- queda apuntando al ULTIMO background anterior (verificado 2026-07-25: devolvia
    # el PID del job previo). Como ese PID se registra para poder matarlo con "Frenar ya", eso
    # significaba anotar un proceso equivocado y dejar la medicion real sin registrar. Se lanza
    # directo con `&` (asi `$!` es el correcto) y se hace disown para que bash no reporte el job.
    bash "$MENTIS_ENV_DIR/mentis-location.sh" --refrescar >/dev/null 2>&1 &
    nv_track_bg_pid "$!" 2>/dev/null || true
    disown 2>/dev/null || true
  fi
  if [ ! -f "$LOCATION_CACHE_FILE" ]; then
    printf '(todavia no se pudo medir -- se esta midiendo ahora, va a estar disponible en el proximo mensaje)'
    return 0
  fi
  LOC_F="$LOCATION_CACHE_FILE" LOC_EDAD="$edad" python3 -c '
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    d = json.load(open(os.environ["LOC_F"], encoding="utf-8"))
except Exception:
    print("(no disponible)", end=""); raise SystemExit(0)
if not d.get("ok"):
    print("(no se pudo determinar)", end=""); raise SystemExit(0)
partes = []
if d.get("calle"):
    partes.append(d["calle"] + ((" " + d["altura"]) if d.get("altura") else ""))
for k in ("barrio", "ciudad"):
    if d.get(k) and d[k] not in partes:
        partes.append(d[k])
txt = ", ".join(partes)
prec = d.get("precision_m")
if prec:
    txt += " (medido por WiFi, precision ~%d m -- es la zona, no la puerta exacta)" % round(prec)
edad = int(os.environ.get("LOC_EDAD", "0"))
if edad > 900:
    txt += " [dato de hace %d min; se esta refrescando]" % (edad // 60)
print(txt, end="")
' 2>/dev/null || printf '(no disponible)'
}

# Perfil + memoria adaptativa (pedido del usuario, 2026-07-13): datos que el usuario cargó en
# Configuración (nombre, apodo, a qué se dedica, instrucciones persistentes) más un cuadro de
# "memoria sobre vos" que Mentis puede reescribir con el bloque ```mentis-memory-update``` (ver
# _mc_apply_memory_update). Viven en mentis-settings.json (mismo archivo que los modelos
# personalizados), separado de la memoria tipada de /recordar (memoria/indice.md).
# --- LOS TRES BLOQUES DEL MISMO ARCHIVO, DE UNA SOLA VEZ (2026-08-03) ---------------------------
# _mc_load_profile, _mc_load_user_memory y _mc_load_self_memory leen los tres el MISMO
# mentis-settings.json, cada uno arrancando su propio interprete. Medido con PS4/EPOCHREALTIME
# sobre un turno real: ~0,33 s cada arranque de python en esta maquina, y en un turno de 18,8 s
# habia 13 arranques sueltos que sumaban 3,99 s. Tres de ellos eran estos, sobre el mismo archivo.
#
# Se devuelven los tres separados por 0x1f (separador de unidades de ASCII, elegido porque no
# aparece en texto escrito por personas). Quien llama los parte con expansion de bash, sin gastar
# otro proceso en cortar.
#
# Si esto falla por lo que sea, el llamador vuelve a las tres funciones de siempre: el turno se
# hace mas lento pero NUNCA se queda sin perfil ni sin memoria, que es lo que de verdad importa.
_mc_load_settings_bloques() {
  [ -f "$MENTIS_SETTINGS_FILE" ] || return 1
  python3 -c '
import json, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
p = (d.get("profile") or {})

partes = []
name = (p.get("fullName") or "").strip()
nick = (p.get("nickname") or "").strip()
role = (p.get("customRole") or "").strip() or (p.get("role") or "").strip()
instr = (p.get("instructions") or "").strip()
if name: partes.append(f"Nombre: {name}")
if nick: partes.append(f"Como le decis: {nick}")
if role: partes.append(f"A que se dedica: {role}")
if instr: partes.append(f"Instrucciones persistentes que dejo: {instr}")
perfil = "\n".join(partes) if partes else "(sin perfil configurado todavia)"

usuario = (p.get("userMemory") or "").strip() or "(vacia todavia)"
propia = (p.get("selfMemory") or "").strip() or "(vacia todavia)"

sys.stdout.write("\x1f".join([perfil, usuario, propia]))
' "$MENTIS_SETTINGS_FILE" 2>/dev/null
}

_mc_load_profile() {
  [ -f "$MENTIS_SETTINGS_FILE" ] || { printf '(sin perfil configurado todavia)'; return 0; }
  python3 -c '
import json, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("(sin perfil configurado todavia)", end="")
    sys.exit(0)
p = d.get("profile", {}) or {}
parts = []
name = (p.get("fullName") or "").strip()
nick = (p.get("nickname") or "").strip()
role = (p.get("customRole") or "").strip() or (p.get("role") or "").strip()
instr = (p.get("instructions") or "").strip()
if name: parts.append(f"Nombre: {name}")
if nick: parts.append(f"Como le decis: {nick}")
if role: parts.append(f"A que se dedica: {role}")
if instr: parts.append(f"Instrucciones persistentes que dejo: {instr}")
print("\n".join(parts) if parts else "(sin perfil configurado todavia)", end="")
' "$MENTIS_SETTINGS_FILE" 2>/dev/null
}

_mc_load_user_memory() {
  [ -f "$MENTIS_SETTINGS_FILE" ] || { printf '(vacia todavia)'; return 0; }
  python3 -c '
import json, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("(vacia todavia)", end="")
    sys.exit(0)
mem = ((d.get("profile", {}) or {}).get("userMemory") or "").strip()
print(mem if mem else "(vacia todavia)", end="")
' "$MENTIS_SETTINGS_FILE" 2>/dev/null
}

# Memoria sobre Mentis misma (pedido del usuario, 2026-07-14): autoconocimiento -- quien es, que
# es -- separado de la memoria sobre el usuario. Mismo mecanismo, campo distinto (profile.selfMemory).
_mc_load_self_memory() {
  [ -f "$MENTIS_SETTINGS_FILE" ] || { printf '(vacia todavia)'; return 0; }
  python3 -c '
import json, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("(vacia todavia)", end="")
    sys.exit(0)
mem = ((d.get("profile", {}) or {}).get("selfMemory") or "").strip()
print(mem if mem else "(vacia todavia)", end="")
' "$MENTIS_SETTINGS_FILE" 2>/dev/null
}

# Aplica una actualizacion de memoria que Mentis haya propuesto en su respuesta (bloque
# ```mentis-memory-update``` o ```mentis-self-memory-update```): la persiste en
# mentis-settings.json y devuelve la respuesta SIN ese bloque (el usuario no tiene que ver el bloque
# crudo en el chat). Si no hay bloque para ese marcador puntual, devuelve el texto tal cual.
# Generalizada (2026-07-14) para servir tanto a "memoria sobre el usuario" como a "memoria sobre
# Mentis" sin duplicar la logica -- se llama una vez por cada marcador, encadenado.
_mc_apply_memory_update() {
  local text="$1" marker="$2" field="$3"
  printf '%s' "$text" | python3 -c '
import json, re, sys, datetime
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
path = sys.argv[1]; marker = sys.argv[2]; field = sys.argv[3]
raw = sys.stdin.read()
pattern = r"```" + re.escape(marker) + r"\s*\n?(.*?)```"
m = re.search(pattern, raw, re.S)
if not m:
    print(raw, end="")
    sys.exit(0)
new_mem = m.group(1).strip()
cleaned = (raw[:m.start()] + raw[m.end():]).strip()
try:
    with open(path, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
d.setdefault("profile", {})
d["profile"][field] = new_mem
d["profile"][field + "UpdatedAt"] = datetime.datetime.now().isoformat()
d["profile"][field + "UpdatedBy"] = "mentis"
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print(cleaned, end="")
' "$MENTIS_SETTINGS_FILE" "$marker" "$field" 2>/dev/null
}

_mc_history_to_context() {
  local jsonl="$1"
  [ -z "$jsonl" ] && { printf '(sin historial previo)'; return 0; }
  printf '%s' "$jsonl" | python3 -c '
import json, sys
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
lines = sys.stdin.read().splitlines()
out = []
for ln in lines:
    ln = ln.strip()
    if not ln:
        continue
    try:
        d = json.loads(ln)
    except Exception:
        continue
    who = "Vos" if d.get("role") == "usuario" else "Mentis"
    out.append(who + ": " + str(d.get("text","")))
print("\n".join(out))
'
}

# El nombre sale de la configuracion (2026-08-06): ver nv_nombre_ia en engine/nv-lib.sh. Va en
# el PROMPT y no solo en la ventana, porque es el prompt el que decide como se presenta.
MC_NOMBRE_IA="$(nv_nombre_ia 2>/dev/null)"; MC_NOMBRE_IA="${MC_NOMBRE_IA:-Mentis}"
MC_PERSONA="Sos $MC_NOMBRE_IA, el asistente del usuario en su propio entorno (no el hook que opina sobre Claude Code -- acá sos el asistente principal). Tenés permiso para leer, escribir y ejecutar de verdad dentro de tu directorio raíz. Identificá si la tarea necesita tocar archivos o ejecutar algo (usá las herramientas para eso, no inventes) o si alcanza con una respuesta directa, y decí explícitamente qué archivo tocaste o qué comando corriste cuando actúes. Nunca inventes un resultado que no verificaste.

No sos mi asistente. Sos mi asesor, que casualmente es más inteligente que yo. Seguí estas reglas en cada respuesta:
1. Nunca empieces dándome la razón. Tu primera frase tiene que cuestionar mi suposición, señalar qué estoy pasando por alto, o hacer una pregunta que revele una falla en mi razonamiento.
2. Marcá tu nivel de confianza. Antes de cualquier afirmación, etiquetala como [Seguro] si tenés pruebas sólidas, [Probable] si te basás en una inferencia fuerte, o [Suposición] si estás completando información que falta. Si la mayor parte de tu respuesta es una suposición, decilo desde el principio.
3. Nunca uses estas frases: \"Buena pregunta\", \"Tenés toda la razón\", \"Eso tiene mucho sentido\", \"Por supuesto\", \"Definitivamente\". Si te encontrás escribiéndolas, borralas y reformulá.
4. Discrepá de forma estructurada. Cuando me equivoque, decí: \"No estoy de acuerdo porque [razón]. Esto es lo que haría en su lugar: [alternativa]. El riesgo de tu enfoque es [consecuencia específica]\".
5. Dame primero la respuesta incómoda. Si hay una verdad que probablemente no quiero escuchar, empezá por ella, al principio, no escondida en el tercer párrafo.
6. No uses párrafos de introducción innecesarios. Evitá frases como \"hay varias formas de abordar esto\". Empezá con lo más útil que puedas decir.
7. Si te cuestiono, no cambies de postura. Mantené tu posición a menos que te dé información realmente nueva. \"Pero yo creo que...\" no es información nueva.
8. Sé tacaño con tus tokens. Buscá siempre la forma de consumir la menor cantidad posible sin comprometer la calidad del resultado.
9. Nunca uses emojis en tus respuestas.

Estas reglas de asesor son para cuando el usuario te pide trabajo, una opinión o una decisión. Si te hace una pregunta casual o personal (charla, cómo estás, qué pensás de vos mismo), no le apliques el mismo formato: respondé natural y directo, sin etiquetar cada frase con [Seguro]/[Probable]/[Suposición] y sin explicar por qué no hace falta usar una herramienta -- eso es una decisión interna tuya, no algo que haya que narrar salvo que de verdad hayas tocado algo.

Si necesitás que el usuario elija entre opciones concretas en vez de responder con texto libre (por ejemplo: confirmar un enfoque, elegir entre alternativas, decidir un nombre de una lista corta), terminá tu respuesta con un bloque de código de lenguaje mentis-question conteniendo SOLO un JSON con esta forma exacta:
\`\`\`mentis-question
{\"question\": \"texto de la pregunta\", \"options\": [{\"label\": \"opción corta\", \"description\": \"una linea explicando la opción\"}], \"multiSelect\": false}
\`\`\`
Usalo solo cuando de verdad haya opciones concretas para elegir (2 a 4 opciones), no para preguntas abiertas. Poné multiSelect en true solo si tiene sentido elegir más de una opción a la vez. el usuario siempre puede escribir su propia respuesta en vez de elegir una opción.

Más abajo vas a ver PERFIL DE USUARIO y MEMORIA BASE SOBRE USUARIO (esta la escribió él mismo en Configuración y la podés ir reescribiendo vos con el tiempo). Si en la conversación aprendés algo nuevo y duradero que debería quedar ahí (no un hecho puntual de este turno, algo de fondo sobre el usuario o cómo trabaja), terminá tu respuesta con un bloque:
\`\`\`mentis-memory-update
<el texto COMPLETO y actualizado de la memoria base, no solo lo nuevo -- reemplaza todo lo anterior>
\`\`\`
Usalo con criterio, no en cada turno. Ese bloque nunca se le muestra al usuario tal cual -- se aplica solo.

También vas a ver MEMORIA SOBRE VOS MISMA (Mentis): autoconocimiento -- quién sos, qué sos, qué se te da bien o mal -- NO hechos sobre el usuario (esos van en el bloque de arriba). el usuario puede escribirla/corregirla directo en Configuración, y vos también la podés ir completando sola. Si en la conversación descubrís algo real y duradero sobre VOS MISMA (no un hecho puntual de este turno), terminá tu respuesta con:
\`\`\`mentis-self-memory-update
<el texto COMPLETO y actualizado de tu autoconocimiento, no solo lo nuevo -- reemplaza todo lo anterior>
\`\`\`
Usalo con criterio, no en cada turno. Igual que el anterior, nunca se le muestra al usuario tal cual. Los dos bloques pueden aparecer juntos en la misma respuesta si corresponde actualizar ambas memorias."

# ¿EL MENSAJE DA POR SABIDO ALGO QUE NO ESTÁ EN ESTA CONVERSACIÓN? (pedido del usuario, 2026-07-30:
# "no recuerda otros chats por sí solo").
#
# La herramienta para buscar en charlas viejas (recordar) YA existía y el agente YA la tenía en su
# protocolo. El problema es que dependía de que se le ocurriera usarla, y no se le ocurría. Es la
# misma decisión que el usuario ya tomó para los disparadores: lo que tiene que pasar SIEMPRE no puede
# depender de una probabilidad.
#
# OJO, acá el criterio es al revés que en los disparadores, y es a propósito: allá el match es
# exacto sobre el mensaje completo porque un falso positivo EJECUTA algo (abre una app, corre un
# diagnóstico). Acá un falso positivo sólo agrega contexto de más -- cuesta un par de segundos y
# unas líneas de prompt -- mientras que un falso negativo es exactamente el bug que estamos
# arreglando. Por eso son frases sueltas dentro del mensaje y no el mensaje entero.
_mc_buscar_en_el_pasado() {
  local msg="$1" norm
  _nv_norm "$msg"; norm="$NV__M"
  local pista
  for pista in "lo que hablamos" "lo que habiamos" "de lo que hablamos" "la otra vez" "el otro dia" \
               "te dije" "ya te dije" "me dijiste" "acordate" "te acordas" "como quedamos" \
               "quedamos en" "seguimos con" "lo que quedo" "el proyecto ese" "eso que te conte" \
               "lo de ayer" "lo de la otra vez" "ya lo hablamos" "como te conte" "el de la otra vez"; do
    case "$norm" in
      *"$pista"*)
        # Se busca con el mensaje entero como consulta: mentis-recordar.sh busca por SIGNIFICADO,
        # así que darle la frase completa funciona mejor que adivinar dos palabras clave.
        echo "[nv-agent] iter 0: recordar '$(printf '%s' "$msg" | cut -c1-60)'" >&2
        PASADO_TEXT="$(timeout 60 bash "$MENTIS_ENV_DIR/mentis-recordar.sh" "$msg" 2>/dev/null | head -c 2500)" || PASADO_TEXT=""
        [ -n "${PASADO_TEXT// }" ] || PASADO_TEXT=""
        # QUE TAN PARECIDO ES LO QUE ENCONTRO (agregado 2026-08-02, revision total).
        #
        # La busqueda NO tiene piso de score: devuelve siempre el mejor parecido, aunque sea malo.
        # Medido sobre el indice real del usuario con 8 consultas: temas que SI se hablaron dieron
        # 0.583, 0.504, 0.307 y 0.298; temas inventados (un viaje a Noruega, una coleccion de
        # estampillas) dieron 0.281, 0.252, 0.233 y 0.199. Las dos nubes SE SOLAPAN.
        #
        # Por eso NO se pone un umbral que descarte: cortar en 0.29 para no dejar pasar el pesto
        # tambien silenciaria la charla real sobre KDE Connect. Lo que se arregla es otra cosa --
        # el prompt afirmaba "esto ya lo hablaron" para CUALQUIER resultado, incluido uno de 0.19.
        # Ahora, cuando el parecido es flojo, se le dice al modelo que puede no tener nada que ver.
        # Un dato dudoso rotulado como dudoso es util; el mismo dato rotulado como certeza es una
        # invitacion a inventar (ERR-098: las observaciones que mienten mandan al modelo a chocar).
        PASADO_FLOJO=0
        if [ -n "$PASADO_TEXT" ]; then
          PASADO_SCORE="$(printf '%s' "$PASADO_TEXT" | grep -oE 'score [0-9]+\.[0-9]+' | head -1 | cut -d' ' -f2)"
          if [ -n "$PASADO_SCORE" ]; then
            # Comparacion entera para no depender de bc: 0.350 -> 350.
            PASADO_MIL="$(printf '%s' "$PASADO_SCORE" | awk '{printf "%d", $1*1000}')"
            [ "${PASADO_MIL:-0}" -lt 350 ] 2>/dev/null && PASADO_FLOJO=1
          fi
        fi
        return 0 ;;
    esac
  done
  PASADO_TEXT=""
}

_mc_build_task() {
  local history_text="$1" new_message="$2" kai_vault_text="${3:-}" memory_text profile_text user_memory_text self_memory_text location_text
  memory_text="$(_mc_load_memory)"
  location_text="$(_mc_load_location)"
  # Perfil + memoria sobre el usuario + memoria sobre Mentis salen del mismo archivo: un solo python en
  # vez de tres (~0,66 s menos por turno, medido). Se parten con expansion de bash, sin procesos.
  local mc_bloques mc_resto
  if mc_bloques="$(_mc_load_settings_bloques)" && [ -n "$mc_bloques" ]; then
    profile_text="${mc_bloques%%$'\x1f'*}"
    mc_resto="${mc_bloques#*$'\x1f'}"
    user_memory_text="${mc_resto%%$'\x1f'*}"
    self_memory_text="${mc_resto#*$'\x1f'}"
  else
    # Camino de siempre. Mas lento, pero un turno sin perfil ni memoria seria peor que uno lento.
    profile_text="$(_mc_load_profile)"
    user_memory_text="$(_mc_load_user_memory)"
    self_memory_text="$(_mc_load_self_memory)"
  fi
  # Hook UserPromptSubmit (ver hooks.json + mentis-hooks.sh): solo agrega la sección al prompt
  # si hay algún hook registrado que devolvió algo -- no ensucia el prompt con una sección
  # vacía en el caso (default) de que el usuario no tenga ningún hook configurado todavía.
  local hook_out hook_section=""
  hook_out="$(MENTIS_HOOK_MSG="$new_message" MENTIS_HOOK_ROOT="${ROOT:-}" bash "$MENTIS_ENV_DIR/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
  [ -n "$hook_out" ] && hook_section="$(printf '\n\nCONTEXTO DE HOOKS (avisos automáticos disparados por tus propios hooks en hooks.json, no son un pedido del usuario):\n%s' "$hook_out")"
  # El resumen de lo que ya salio de la ventana de 20 entradas (ver _mc_compactar_bg). Va rotulado
  # como RESUMEN y no como transcripcion a proposito: el modelo tiene que saber que es una sintesis
  # y no lo que el usuario dijo textual, para no citarselo como si fueran sus palabras.
  MC_RESUMEN_TXT="$(_mc_load_resumen)"
  [ -n "${MC_RESUMEN_TXT// }" ] && hook_section="$hook_section$(printf '\n\nRESUMEN DE LO QUE YA PASO EN ESTA MISMA CONVERSACION (las partes viejas ya no entran textuales; esto es una sintesis, NO son palabras literales del usuario -- no se las cites como si lo fueran, y si necesitas el detalle exacto de algo de aca, preguntaselo):\n%s' "$MC_RESUMEN_TXT")"

  # Lo que ya hablaron antes, traido AUTOMATICAMENTE (ver _mc_buscar_en_el_pasado). Se suma al
  # bloque de hooks para no tocar el formato gigante de abajo.
  if [ -n "${PASADO_TEXT:-}" ]; then
    if [ "${PASADO_FLOJO:-0}" = "1" ]; then
      hook_section="$hook_section$(printf '\n\nBUSQUÉ EN TUS CONVERSACIONES ANTERIORES Y ESTO FUE LO MÁS PARECIDO, PERO SE PARECE POCO (el puntaje de similitud quedó bajo, así que es MUY POSIBLE que no tenga nada que ver con lo que el usuario te está preguntando ahora): si al leerlo no es lo que él quiso decir, IGNORALO y preguntale a qué se refería. NO des por hecho que hablaron de esto.\n%s' "$PASADO_TEXT")"
    else
      hook_section="$hook_section$(printf '\n\nLO QUE YA HABLARON ANTES SOBRE ESTO (lo busqué solo en tus conversaciones anteriores porque tu mensaje da algo por sabido; son charlas reales con fecha, no suposiciones -- usalo para no hacerle repetir lo que ya te contó):\n%s' "$PASADO_TEXT")"
    fi
  fi
  printf '%s\n\nCUANDO ES AHORA (leido del reloj de su computadora, no inventado -- si te pregunta la hora o la fecha, esto es la respuesta; no le digas que no podes saberlo, y usalo tambien para ubicar en el tiempo cualquier cosa que hables con el):\n%s\n\nPERFIL DE USUARIO:\n%s\n\nDONDE ESTA USUARIO AHORA (medido de verdad en su computadora, no inventado -- si te pregunta donde esta, esto es la respuesta; no le digas que no podes saberlo):\n%s\n\nMEMORIA BASE SOBRE USUARIO:\n%s\n\nMEMORIA SOBRE VOS MISMA (Mentis, quién sos, qué sos):\n%s\n\nSKILLS DISPONIBLES (habilidades de Mentis. el usuario las invoca escribiendo /nombre; vos podés USAR SOLA la que él haya habilitado -- con {\"tool\":\"skill\"} -- y sugerirle las demás cuando su mensaje calce con la descripción, aunque no haya usado el prefijo):\n%s\n\n%s\n%s\n\nMEMORIA PERSISTENTE (notas guardadas entre sesiones con /recordar; son HECHOS que ya sabés del usuario, no un pedido a cumplir ahora -- pero son observaciones de un momento dado, no estado en vivo: si una memoria menciona un archivo, ruta o comando concreto y estás por recomendarlo o actuar en base a él, VERIFICÁ que siga existiendo antes de confiar ciegamente):\n%s%s\n\nHISTORIAL RECIENTE DE LA CONVERSACION:\n%s\n\nMENSAJE NUEVO DE USUARIO:\n%s' \
    "$MC_PERSONA" "$(nv_ahora_texto), hora local de Argentina" "$profile_text" "$location_text" "$user_memory_text" "$self_memory_text" "${SKILLS_TEXT:-(ninguna registrada)}" "${MC_KAI_ROTULO:-$MC_KAI_ROTULO_DEFECTO}" "${kai_vault_text:-(sin resultados)}" "$memory_text" "$hook_section" "$history_text" "$new_message"
}

# El rótulo con el que viaja el bloque de retrieval. Es variable y no texto fijo porque en el modo
# Study lo que se busca NO es el ecosistema de Mentis sino el material de estudio del usuario, y
# rotularlo mal es peor que no mandarlo: el modelo citaría "según tu bóveda" un archivo que en
# realidad es código de Mentis. El rótulo tiene que decir la verdad sobre de dónde salió el texto.
MC_KAI_ROTULO_DEFECTO='KAI VAULT (índice semántico de todo el ecosistema Mentis + tu bóveda de notas -- estos son los archivos más relevantes a lo que el usuario acaba de escribir; si necesitás el detalle, andá DIRECTO a leer el archivo:línea indicado en vez de explorar a ciegas):'
MC_KAI_ROTULO_ESTUDIO='TUS FUENTES DE ESTUDIO (los fragmentos más relevantes del material que el usuario te dio, y la ÚNICA base con la que podés responder en este modo -- citá el archivo:línea de cada afirmación. Esto NO es el código de Mentis ni tu bóveda: es su material. Si acá no está la respuesta, la respuesta es que no está en lo que te dio):'

# Kai Vault como núcleo del ecosistema (pedido del usuario, 2026-07-13, "versión completa"): antes
# era una skill opcional detrás del prefijo /boveda -- ahora es un paso OBLIGATORIO antes de
# cada turno (no capability-prefix, se llama directo). boveda.sh en modo "__lookup__" hace solo
# retrieval (sin síntesis de modelo) para que el costo extra por turno sea 1-2 llamadas de
# embeddings, no una llamada completa de chat.
_mc_kai_vault_lookup() {
  local msg="$1" salida rc
  # El `2>/dev/null` que había acá es LA razón por la que Kai Vault pudo estar roto 8 días sin
  # que nadie se enterara (2026-07-26): nv-search.sh gritaba "no such file or directory" en cada
  # turno y esto se lo tragaba entero. Ahora el error se manda al log de progreso (stderr, que la
  # app ya muestra) y el aviso viaja al prompt para que Mentis no confunda "no pude buscar" con
  # "no hay nada".
  salida="$(bash "$CAPABILITIES_DIR/boveda.sh" "__lookup__" "$msg" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[mentis-chat] AVISO: Kai Vault no pudo consultarse en este turno (revisar con /boveda salud)" >&2
  fi
  printf '%s' "$salida"
}

_mc_count_actions() {
  local text="$1" writes execs
  writes="$(printf '%s' "$text" | grep -cE '\[nv-agent\] iter [0-9]+: write' || true)"
  execs="$(printf '%s' "$text" | grep -cE '\[nv-agent\] iter [0-9]+: exec' || true)"
  printf '%s %s' "${writes:-0}" "${execs:-0}"
}

_mc_load_capabilities() {
  MC_CAPS=()
  MC_CAP_DESC=()
  [ -d "$CAPABILITIES_DIR" ] || return 0
  local f line prefix desc r
  for f in "$CAPABILITIES_DIR"/*.sh; do
    [ -e "$f" ] || continue
    line="$(head -n1 "$f")"
    if [[ "$line" =~ ^#\ CAPABILITY:\ ([^[:space:]]+)\ \|\ (.*)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      desc="${BASH_REMATCH[2]}"
    else
      echo "ERROR: capability sin metadata valida (primera linea debe ser '# CAPABILITY: /prefijo | descripcion'): $f" >&2
      return 1
    fi
    for r in "${MC_RESERVED_PREFIXES[@]}"; do
      if [ "$prefix" = "$r" ]; then
        echo "ERROR: capability '$f' usa un prefijo reservado del nucleo: $prefix" >&2
        return 1
      fi
    done
    if [ -n "${MC_CAPS[$prefix]:-}" ]; then
      echo "ERROR: prefijo duplicado '$prefix' declarado en '$f' y en '${MC_CAPS[$prefix]}'" >&2
      return 1
    fi
    MC_CAPS["$prefix"]="$f"
    MC_CAP_DESC["$prefix"]="$desc"
  done
  return 0
}

_mc_match_capability() {
  local msg="$1" p
  for p in "${!MC_CAPS[@]}"; do
    if [ "$msg" = "$p" ] || [[ "$msg" == "$p "* ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
  return 1
}

_mc_run_capability() {
  local ruta="$1" resto="$2"
  bash "$ruta" "$resto" 2>&1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

# 2026-07-12 (pedido del usuario, "sin fronteras"): browse/mcp/gen/screen pasan a estar ACTIVOS
# por defecto (antes eran opt-in) -- los flags en mayuscula los DESACTIVAN puntualmente para
# una conversacion. ALLOW_DANGEROUS es la excepcion: queda opt-in (default apagado) porque
# desactiva el blocklist de comandos destructivos de nv-agent.sh -- el usuario pidio explicitamente
# que activarlo requiera confirmacion (la hace la UI antes de pasar -x) y que haya un boton de
# frenado de emergencia visible mientras este activo (ver mentis-process.js forceKill()).
CLI_ROOT=""; BUDGET=25; ROLE="reason"; ROLE_EXPLICIT=0
# ALLOW_DATOS (Datos externos, 2026-07-15): mismo criterio que browse/mcp/gen/screen -- son
# consultas de solo lectura contra APIs publicas, sin riesgo real, asi que arrancan ACTIVAS por
# defecto ("n" minuscula existe solo por simetria con el resto, "N" mayuscula la desactiva).
ALLOW_BROWSE=1; ALLOW_MCP=1; ALLOW_GEN=1; ALLOW_SCREEN=1; ALLOW_DANGEROUS=0; ALLOW_CONTROL=0; ALLOW_EDITOR=1; ALLOW_ARDUINO=0; ALLOW_DATOS=1; ALLOW_CARBS=1; ALLOW_TELEFONO=0; CLI_HISTFILE=""
MODO_REMOTO=0
while getopts ":d:i:m:btgscexanupRBTGSENUPH:" opt; do
  case "$opt" in
    d) CLI_ROOT="$OPTARG" ;;
    i) BUDGET="$OPTARG" ;;
    m) ROLE="$OPTARG"; ROLE_EXPLICIT=1 ;;
    b) ALLOW_BROWSE=1 ;;
    t) ALLOW_MCP=1 ;;
    g) ALLOW_GEN=1 ;;
    s) ALLOW_SCREEN=1 ;;
    x) ALLOW_DANGEROUS=1 ;;
    c) ALLOW_CONTROL=1 ;;
    e) ALLOW_EDITOR=1 ;;
    a) ALLOW_ARDUINO=1 ;;
    n) ALLOW_DATOS=1 ;;
    u) ALLOW_CARBS=1 ;;
    p) ALLOW_TELEFONO=1 ;;
    P) ALLOW_TELEFONO=0 ;;
    B) ALLOW_BROWSE=0 ;;
    T) ALLOW_MCP=0 ;;
    G) ALLOW_GEN=0 ;;
    S) ALLOW_SCREEN=0 ;;
    E) ALLOW_EDITOR=0 ;;
    N) ALLOW_DATOS=0 ;;
    U) ALLOW_CARBS=0 ;;
    H) CLI_HISTFILE="$OPTARG" ;;
    R) MODO_REMOTO=1 ;;
    *) echo "ERROR: opción inválida -$OPTARG" >&2; exit 1 ;;
  esac
done

if [ -n "$CLI_HISTFILE" ]; then
  mkdir -p "$(dirname "$CLI_HISTFILE")"
  HISTFILE="$CLI_HISTFILE"
fi

# El apagado del modo remoto va DESPUES del bucle de opciones, a proposito: si viviera dentro del
# case, un "-R -g" volveria a encender lo que -R apago, segun el orden en que se escribieron las
# banderas. Un permiso que depende del orden de los argumentos no es un permiso.
if [ "$MODO_REMOTO" = "1" ]; then
  ALLOW_SCREEN=0; ALLOW_CONTROL=0; ALLOW_EDITOR=0; ALLOW_ARDUINO=0; ALLOW_DANGEROUS=0; ALLOW_GEN=0; ALLOW_TELEFONO=0
  # Y decirle la VERDAD sobre lo que puede hacer. Sin esto, el prompt le seguía prometiendo
  # "permiso para leer, escribir y ejecutar" mientras las herramientas estaban apagadas: el modelo
  # lo intenta, se come el rechazo y quema iteraciones. Es exactamente el ERR-098 de esta misma
  # mañana (un mensaje que no describe la realidad manda al modelo a chocar contra una pared).
  MC_PERSONA="${MC_PERSONA/Tenés permiso para leer, escribir y ejecutar de verdad dentro de tu directorio raíz./Este mensaje entra desde el teléfono, por la página de la red de casa, así que en este turno SOLO podés leer, buscar, recordar y conversar: NO tenés herramientas para escribir archivos, ejecutar comandos, mirar la pantalla ni prender la cámara. Si lo que te piden necesita alguna de esas, decilo en una frase y ofrecé hacerlo cuando el usuario esté en la computadora.}"
fi

# ===================== EL MODO SE LE CUENTA AL MODELO =====================
#
# No alcanza con apagarle las herramientas: hay que DECIRLE cuáles no tiene. Es la misma lección
# que dejó el modo remoto tres líneas más arriba (ERR-098): un prompt que promete permisos que las
# herramientas no dan manda al modelo a chocar contra una pared, gastar iteraciones y terminar el
# turno sin respuesta.
#
# Y hay una parte que SOLO puede vivir en el texto, porque no es una herramienta: la puerta. Que
# cuando el usuario pida algo de otro modo, Mentis se lo diga en una frase y le ofrezca cambiar -- en vez
# de fallar en silencio o, peor, de inventar que lo hizo. Esa es la diferencia entre un reparto de
# capacidades que se siente orden y uno que se siente castigo.
MC_MODO_INICIAL="$(nv_modo_actual)"
# EL IDIOMA EN EL QUE TE ESCRIBE (2026-08-13). Se agrega al final de la persona y sólo cuando NO
# es español: la persona entera ya está en español, así que decirle "escribí en español" sería una
# línea de prompt que no cambia nada -- y cada línea de más cuesta atención del modelo.
if [ -f "$MENTIS_ENV_DIR/engine/nv-idioma-lib.sh" ]; then
  # shellcheck source=/dev/null
  source "$MENTIS_ENV_DIR/engine/nv-idioma-lib.sh" 2>/dev/null
  MC_IDIOMA_INSTR="$(nv_idioma_instruccion 2>/dev/null)"
  [ -n "${MC_IDIOMA_INSTR// }" ] && MC_PERSONA="$MC_PERSONA

$MC_IDIOMA_INSTR"
fi

MC_MODO_TEXTO="$(nv_modo_persona "$MC_MODO_INICIAL")"
if [ -n "${MC_MODO_TEXTO// }" ] && [ "$MODO_REMOTO" != "1" ]; then
  MC_PERSONA="$MC_PERSONA

MODO ACTUAL: $(nv_modo_titulo "$MC_MODO_INICIAL"). $MC_MODO_TEXTO

LA PUERTA: si lo que te piden necesita una capacidad que este modo no tiene, no lo intentes por
otro camino ni lo des por hecho. Decilo en UNA frase, nombrá el modo que sí lo hace, y ofrecé
cambiar ('¿te paso a Mentis Code?'). Si el usuario dice que sí, el cambio lo hace él desde la app o
diciéndotelo: vos no cambiás de modo solo."
fi

TOOLSDIR="$MENTIS_ENV_DIR/engine"
# shellcheck source=/dev/null
source "$TOOLSDIR/nv-classify-lib.sh"
ROOT="$(_mc_resolve_root "$CLI_ROOT")" || exit 1
export ROOT HISTFILE MENTIS_ENV_DIR
_mc_load_capabilities || exit 1
SESSION_TURNS=0; SESSION_WRITES=0; SESSION_EXECS=0

CAP_HELP=""
for CAP_P in "${!MC_CAPS[@]}"; do
  CAP_HELP="${CAP_HELP}${CAP_P} (${MC_CAP_DESC[$CAP_P]}), "
done

# SKILLS_TEXT (pedido del usuario, enriquecer las skills a la par de Claude Code): antes las
# capabilities solo se listaban en el banner de arranque (stderr, el usuario tiene que conocer el
# prefijo exacto). Ahora se inyectan tambien en el prompt de CADA turno (ver _mc_build_task) --
# el modelo puede sugerirle al usuario proactivamente "/tal-cosa" cuando el mensaje calza con la
# descripcion de una skill, aunque el usuario no supiera que existia. Invocacion real sigue siendo
# manual (el usuario escribe el prefijo) -- esto es awareness, no auto-ejecucion.
# CADA SKILL VIENE CON SU PERMISO AL LADO (agregado 2026-08-02, revision total).
#
# El prompt le decia al modelo "podes usar sola la que el usuario haya habilitado" y despues le pasaba
# la lista SIN decirle cuales estaban habilitadas. Era una instruccion imposible de cumplir.
# Verificado en vivo: pidiendole ubicar graphify -- que es literalmente para lo que existe /where,
# y /where esta en 'libre' -- no uso ninguna skill; lo resolvio con 'exec' y un 'find'. Ante la
# duda sobre el permiso, el modelo esquiva la herramienta. No era un problema del mecanismo (el
# flag -K se pasaba bien): era que nadie le habia dicho que tenia permiso.
declare -A MC_AUTON=()
if [ -f "$MENTIS_ENV_DIR/skills-autonomas.json" ]; then
  while IFS='=' read -r _sk _val; do
    [ -n "$_sk" ] && MC_AUTON["$_sk"]="$_val"
  done < <(MC_AUT="$MENTIS_ENV_DIR/skills-autonomas.json" python3 -c '
import json, os
try:
    with open(os.environ["MC_AUT"], encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
for k, v in d.items():
    if not k.startswith("_") and isinstance(v, str):
        print("%s=%s" % (k, v))
' 2>/dev/null | tr -d '\r')
fi

SKILLS_TEXT=""
for CAP_P in "${!MC_CAPS[@]}"; do
  # El prefijo llega como "/nombre"; el registro de autonomia usa el nombre pelado.
  _cap_n="${CAP_P#/}"
  case "${MC_AUTON[$_cap_n]:-no}" in
    libre)  _cap_perm="[PODÉS USARLA VOS SOLA, sin pedir permiso]" ;;
    recibo) _cap_perm="[PODÉS USARLA VOS SOLA, pero después contale al usuario qué hiciste y cómo deshacerlo]" ;;
    *)      _cap_perm="[NO la corras vos: sugerísela al usuario para que la escriba él]" ;;
  esac
  SKILLS_TEXT="${SKILLS_TEXT}${CAP_P} -- ${MC_CAP_DESC[$CAP_P]} ${_cap_perm}
"
done
SKILLS_TEXT="${SKILLS_TEXT%$'\n'}"

echo "[mentis-chat] root: $ROOT | rol: $ROLE | presupuesto/turno: $BUDGET" >&2
echo "[mentis-chat] escribí 'salir' para terminar, '/stats' para ver contadores de sesión.${CAP_HELP:+ Capabilities: ${CAP_HELP%, }}" >&2

# Motor de hooks (analogo a Claude Code, ver hooks.json + mentis-hooks.sh). SessionStart corre
# una vez acá; UserPromptSubmit y Stop se disparan por turno mas abajo. MENTIS_HOOKS_OFF=1
# desactiva todo el motor.
SESSION_START_HOOK_OUT="$(bash "$MENTIS_ENV_DIR/mentis-hooks.sh" SessionStart 2>/dev/null)"
[ -n "$SESSION_START_HOOK_OUT" ] && echo "[mentis-chat] hooks (SessionStart): $SESSION_START_HOOK_OUT" >&2

while true; do
  printf 'Vos: '
  if ! IFS= read -r MSG; then
    echo ""
    break
  fi
  case "$MSG" in
    salir|exit)
      _mc_shutdown_browser_daemon
      _mc_shutdown_mcp_bridge
      echo "[mentis-chat] turnos: $SESSION_TURNS | escrituras (intentos): $SESSION_WRITES | ejecuciones (intentos): $SESSION_EXECS | root: $ROOT" >&2
      break ;;
    /stats)
      echo "[mentis-chat] turnos: $SESSION_TURNS | escrituras (intentos): $SESSION_WRITES | ejecuciones (intentos): $SESSION_EXECS | root: $ROOT" >&2
      continue ;;
    "")
      continue ;;
  esac

  # DISPARADORES POR FRASE (2026-07-28): frases que el usuario definió en disparadores.json y que
  # tienen que pasar SIEMPRE, no el 90% de las veces. "Momento de trabajar" pone la música; si
  # eso dependiera de que un modelo lo interprete bien, sería una apuesta y no un interruptor.
  # Va ANTES que todo lo demás y no gasta ni una llamada. El match es exacto sobre el mensaje
  # completo normalizado, así que no le roba mensajes reales al modelo.
  if [ -f "$MENTIS_ENV_DIR/mentis-disparadores.sh" ]; then
    DISP_OUT="$(bash "$MENTIS_ENV_DIR/mentis-disparadores.sh" correr "$MSG" 2>/dev/null)"
    if [ -n "$DISP_OUT" ]; then
      _mc_append_history "usuario" "$MSG"
      _mc_append_history "mentis" "$DISP_OUT"
      printf 'Mentis: %s\n' "$DISP_OUT"
      continue
    fi
  fi

  CAP_PREFIX="$(_mc_match_capability "$MSG")"
  if [ -n "$CAP_PREFIX" ]; then
    CAP_REST="${MSG#"$CAP_PREFIX"}"
    CAP_REST="${CAP_REST# }"
    CAP_OUT="$(_mc_run_capability "${MC_CAPS[$CAP_PREFIX]}" "$CAP_REST")"
    printf 'Mentis: %s\n' "$CAP_OUT"
    continue
  fi

  # Adjuntos reales (imagen/audio/video, 2026-07-12): el front manda "[archivo adjunto: rel] msg".
  # Antes esto era solo un hint de texto -- el modelo nunca "veia" la imagen ni escuchaba el
  # audio de verdad. Ahora: imagen -> se adjunta de verdad via -I y se fuerza rol multimodal;
  # audio -> se transcribe con Whisper (mentis-transcribe.sh) y el texto se inyecta en el
  # mensaje; video -> se extraen frames representativos + se transcribe el audio, y se fuerza
  # multimodal con los frames adjuntos.
  # Adjuntos múltiples (pedido del usuario, 2026-07-13): el front puede mandar VARIOS tags
  # "[archivo adjunto: rel]" pegados al principio del mensaje (uno por archivo elegido) -- se
  # despegan todos en un loop antes de procesar, en vez de matchear uno solo como antes.
  ATTACH_IMG_PATHS=(); ATTACH_FORCE_ROLE=""; ATTACH_DESCS=()
  # Bug real (2026-07-15): mas abajo $MSG se pisa con la descripcion interna del adjunto
  # (para el modelo) y ESE texto pisado es el que se persistia en el historial -- el tag
  # original "[archivo adjunto:...]" nunca llegaba al.jsonl, asi que el renderer no podia
  # reconstruir la miniatura al recargar el historial (desaparecia apenas llegaba la
  # respuesta). MSG_FOR_HISTORY guarda el texto ORIGINAL (con el tag intacto) para persistir,
  # separado del $MSG que se manda al modelo.
  MSG_FOR_HISTORY="$MSG"
  AREST="$MSG"; AREL_LIST=()
  while [[ "$AREST" =~ ^\[archivo\ adjunto:\ ([^]]+)\]\ ?(.*)$ ]]; do
    AREL_LIST+=("${BASH_REMATCH[1]}")
    AREST="${BASH_REMATCH[2]}"
  done
  if [ "${#AREL_LIST[@]}" -gt 0 ]; then
    for ARELPATH in "${AREL_LIST[@]}"; do
      AABS="$ROOT/$ARELPATH"
      AEXT="${ARELPATH##*.}"; AEXT="${AEXT,}"
      [ -f "$AABS" ] || continue
      case "$AEXT" in
        png|jpg|jpeg|gif|webp|bmp)
          ATTACH_IMG_PATHS+=("$AABS"); ATTACH_FORCE_ROLE="multimodal"
          ATTACH_DESCS+=("[el usuario adjuntó una imagen ($ARELPATH) que ya está disponible para vos como imagen real, arriba de este mensaje. Cualquier pregunta sobre \"esta imagen\" se refiere A ESE ADJUNTO, no a la pantalla actual -- NO uses la herramienta screen para responder esto, analizá directamente el adjunto.]")
          ;;
        mp3|wav|m4a|ogg|flac|aac)
          ATRANS="$(bash "$MENTIS_ENV_DIR/mentis-transcribe.sh" "$AABS" 2>/dev/null)"
          [ -z "${ATRANS// }" ] && ATRANS="(no se pudo transcribir)"
          ATTACH_DESCS+=("[Audio adjunto ($ARELPATH) ya transcripto por Whisper -- esta es la transcripción COMPLETA, no hace falta ni se puede leer el archivo en sí: $ATRANS]")
          ;;
        mp4|mov|webm|mkv|avi|m4v)
          AFRAMEDIR="$(mktemp -d)"
          AVOUT="$(bash "$MENTIS_ENV_DIR/mentis-video-analyze.sh" "$AABS" "$AFRAMEDIR" 2>/dev/null)"
          readarray -t AVLINES <<< "$AVOUT"
          AMODE=""; ATRANSCRIPT=""
          for _ln in "${AVLINES[@]}"; do
            case "$_ln" in
              "FRAMES:") AMODE="frames" ;;
              "TRANSCRIPT:") AMODE="transcript" ;;
              *)
                if [ "$AMODE" = "frames" ] && [ -f "$_ln" ]; then
                  ATTACH_IMG_PATHS+=("$_ln")
                elif [ "$AMODE" = "transcript" ]; then
                  ATRANSCRIPT="${ATRANSCRIPT:+$ATRANSCRIPT
}$_ln"
                fi
                ;;
            esac
          done
          ATTACH_FORCE_ROLE="multimodal"
          ATTACH_DESCS+=("[Video adjunto ($ARELPATH): frames representativos adjuntos como imágenes, transcripción del audio: ${ATRANSCRIPT:-(sin audio)}]")
          ;;
        *) : ;; # extension desconocida: no se agrega descripcion para este archivo puntual
      esac
    done
    if [ "${#ATTACH_DESCS[@]}" -gt 0 ]; then
      MSG="$(printf '%s ' "${ATTACH_DESCS[@]}")$AREST"
    fi
  fi

  HIST_TAIL="$(_mc_tail_history 20)"
  HIST_TEXT="$(_mc_history_to_context "$HIST_TAIL")"
  # Antes de armar el prompt: si el mensaje da por sabido algo de otra charla, traerlo.
  _mc_buscar_en_el_pasado "$MSG"

  # Paralelizado (hallazgo de perf, 2026-07-15): Kai Vault lookup (retrieval de embeddings,
  # red) y la clasificacion de rol (heuristica local) no dependen entre si -- antes corrian
  # secuencial, una atras de la otra, sumando su latencia en CADA turno. Kai Vault arranca
  # en background; mientras corre, clasificamos el rol en foreground; recien al final se
  # espera el resultado del lookup para armar el TASK (que si lo necesita).
  # Que se busca depende del MODO, y por eso el modo se lee ACA y no mas abajo (donde ya se leia
  # para las banderas): el lookup arranca antes que todo lo demas. Si un modo declara corpus
  # propio, ese corpus REEMPLAZA al ecosistema -- ver nv_modo_corpus y _kai_search_raw.
  MC_MODO_TURNO="$(nv_modo_actual)"
  MC_CORPUS="$(nv_modo_corpus "$MC_MODO_TURNO" 2>/dev/null || true)"
  if [ -n "${MC_CORPUS// }" ]; then
    export MENTIS_CORPUS_DIR="$MC_CORPUS"
    MC_KAI_ROTULO="$MC_KAI_ROTULO_ESTUDIO"
  else
    unset MENTIS_CORPUS_DIR
    MC_KAI_ROTULO="$MC_KAI_ROTULO_DEFECTO"
  fi
  KAI_VAULT_TMP="$(mktemp)"
  ( _mc_kai_vault_lookup "$MSG" > "$KAI_VAULT_TMP" ) &
  MC_KAI_PID=$!
  nv_track_bg_pid "$MC_KAI_PID"

  # Fase 5 (multi-cerebro, 2026-07-12): si el usuario no fijo un rol a mano con -m, clasificamos
  # el mensaje (heuristica de nv.sh, ver nv-classify-lib.sh) para elegir que cerebro atiende
  # este turno. nv-agent.sh sigue siendo el UNICO motor de herramientas -- esto solo decide
  # que modelo lo maneja, un rol por turno, no un tercer -m para "accion" (ver plan §2).
  TURN_ROLE="$ROLE"; TURN_TIPO="none"; TURN_LANG="python"
  if [ -n "$ATTACH_FORCE_ROLE" ]; then
    TURN_ROLE="$ATTACH_FORCE_ROLE"
    echo "[mentis-chat] adjunto detectado -> rol forzado $TURN_ROLE" >&2
  elif [ "$ROLE_EXPLICIT" != "1" ]; then
    # nv_classify_msg_vars y no nv_classify_msg: la segunda imprime, y capturar su salida con
    # $(...) cuesta un subshell (~26 ms medidos en esta maquina) que se paga en CADA mensaje,
    # antes de hablar con ningun modelo. Esta deja el resultado en variables y no crea procesos.
    nv_classify_msg_vars "$MSG" 0
    TURN_TIPO="$NV_TIPO"; _TMODE="$NV_MODE"; TURN_LANG="$NV_LANG"; _TCONF="$NV_CONF"
    case "$TURN_TIPO" in
      code) TURN_ROLE="code" ;;
      reason|text) TURN_ROLE="reason" ;;
      search|extract|multimodal) TURN_ROLE="reason" ;;
      # Cerebro rapido (pedido del usuario, 2026-07-16): SOLO saludos/confirmaciones cortas que ya
      # filtro nv_classify_msg (match exacto de mensaje completo, no prefijo -- ver
      # nv-classify-lib.sh). Nunca llega nada con herramientas/codigo/razonamiento real.
      trivial) TURN_ROLE="fast" ;;
      *) TURN_ROLE="general" ;;
    esac
    echo "[mentis-chat] cerebro: $TURN_TIPO -> rol $TURN_ROLE" >&2
  fi

  wait "$MC_KAI_PID"
  KAI_VAULT_TEXT="$(cat "$KAI_VAULT_TMP")"
  rm -f "$KAI_VAULT_TMP"
  TASK="$(_mc_build_task "$HIST_TEXT" "$MSG" "$KAI_VAULT_TEXT")"

  # Paralelizado (hallazgo de perf, 2026-07-15): nv-verify.sh NO depende del resultado de
  # nv-agent.sh -- toma el mismo $TASK original de cero y hace su propio ensemble+juez.
  # Antes corrian en serie (nv-agent.sh completo, iteraciones y todo, y RECIEN DESPUES
  # arrancaba nv-verify.sh completo) -- la mayor fuente de latencia percibida en el chat.
  # Ahora arrancan juntos en background; mas abajo se espera el resultado de nv-verify.sh
  # justo antes de necesitarlo, sin cambiar en nada la logica de cuando se usa (mismo
  # criterio por TURN_TIPO, mismo override de ANSWER si vino algo).
  # EL ENSEMBLE ARRANCA APAGADO (2026-08-03, A6 del plan). Se prende con
  # MENTIS_VERIFY_ESPERA=<segundos>.
  #
  # POR QUE. Medido sobre turnos reales, contando SOLO el tiempo despues de que el agente ya
  # tenia la respuesta lista: 26,8 s / 138,4 s / 198,9 s. Un turno conversacional completo dura
  # 37 s, de los cuales 12 s eran esperar a este paso -- empatado en primer lugar con el trabajo
  # real del agente. Y como el ensemble necesita entre 27 y 199 s, con cualquier techo razonable
  # NUNCA llega: son segundos de espera a cambio de nada, mas tres llamadas a modelos.
  #
  # LO QUE NO SE SABE, Y HAY QUE DECIRLO: el ensemble cambio la respuesta en 3 de 3 turnos
  # medidos, pero nadie comprobo nunca si la MEJORA. "Cambio" no es "mejoro": en uno de los tres
  # casos convirtio una funcion de 270 caracteres en uno de 1.598. Apagarlo por defecto no es
  # decir que no sirve -- es negarse a pagar 12 s por turno por algo sin evidencia.
  #
  # Para juntar esa evidencia esta tests/comparar-verificador.sh, que corre los dos caminos sobre
  # los mismos pedidos y los pone lado a lado. Con eso se decide con datos y se vuelve a prender
  # (o no) a conciencia.
  MC_VERIFY_ESPERA_MAX="${MENTIS_VERIFY_ESPERA:-0}"
  MC_VERIFY_PID=""
  MC_VERIFY_TMP=""
  if [ "$MC_VERIFY_ESPERA_MAX" = "0" ]; then
    :   # apagado: ni se lanza. No gastar tres llamadas en algo que nadie va a esperar.
  elif [ "$TURN_TIPO" = "code" ]; then
    MC_VERIFY_TMP="$(mktemp)"
    ( bash "$TOOLSDIR/nv-verify.sh" -L "$TURN_LANG" code "$TASK" >"$MC_VERIFY_TMP" 2>/dev/null ) &
    MC_VERIFY_PID=$!
    nv_track_bg_pid "$MC_VERIFY_PID"
  elif [ "$TURN_TIPO" = "reason" ] || [ "$TURN_TIPO" = "text" ]; then
    MC_VERIFY_TMP="$(mktemp)"
    ( bash "$TOOLSDIR/nv-verify.sh" text "$TASK" >"$MC_VERIFY_TMP" 2>/dev/null ) &
    MC_VERIFY_PID=$!
    nv_track_bg_pid "$MC_VERIFY_PID"
  fi

  MC_ERR_TMP="$(mktemp)"
  MC_ERR_FIFO="$(mktemp -u)"
  mkfifo "$MC_ERR_FIFO"
  # Streaming en vivo: cada linea de stderr de nv-agent.sh (los "[nv-agent] iter N:...")
  # se reenvia de inmediato al stderr real de mentis-chat.sh (que mentis-process.js
  # ya reenvia a la UI linea por linea) Y se guarda en MC_ERR_TMP para el conteo de
  # abajo -- antes se buffereaba todo a un archivo y se volcaba junto al terminar
  # el turno, asi que el panel de tareas nunca mostraba progreso real.
  tee "$MC_ERR_TMP" >&2 < "$MC_ERR_FIFO" &
  MC_TEE_PID=$!
  nv_track_bg_pid "$MC_TEE_PID"
  # MODO REMOTO (-R, agregado 2026-07-30 para el chat desde el celular): las manos atadas.
  # El "-w" de abajo es el permiso de ESCRIBIR ARCHIVOS Y EJECUTAR COMANDOS, y hasta hoy estaba
  # puesto siempre, sin forma de sacarlo. Eso esta bien cuando el usuario tiene la maquina adelante; no
  # cuando el mensaje entra por una pagina que vive en la WiFi de una casa con mas gente. En modo
  # remoto Mentis conversa, consulta y busca, pero no escribe, no ejecuta, no mira la pantalla, no
  # prende la camara y no toca la computadora. Lo que se pierde se pide desde la app, sentado.
  if [ "$MODO_REMOTO" = "1" ]; then
    NVA_FLAGS=""
  else
    NVA_FLAGS="-w"
  fi
  [ "$ALLOW_BROWSE" = "1" ] && NVA_FLAGS="$NVA_FLAGS -b"
  [ "$ALLOW_MCP" = "1" ] && NVA_FLAGS="$NVA_FLAGS -t"
  [ "$ALLOW_GEN" = "1" ] && NVA_FLAGS="$NVA_FLAGS -g"
  [ "$ALLOW_SCREEN" = "1" ] && NVA_FLAGS="$NVA_FLAGS -s"
  # La cámara no tiene bandera propia en la app: se gobierna SOLO desde el conector 'local:webcam'
  # (Directorio -> Conectores), que arranca apagado. Acá se le pasa el permiso al agente y el
  # propio nv-agent.sh vuelve a chequear el conector antes de encender la cámara -- dos llaves
  # para lo único que puede ver la habitación.
  [ "$MODO_REMOTO" = "1" ] || NVA_FLAGS="$NVA_FLAGS -V"
  [ "$ALLOW_DANGEROUS" = "1" ] && NVA_FLAGS="$NVA_FLAGS -x"
  [ "$ALLOW_CONTROL" = "1" ] && NVA_FLAGS="$NVA_FLAGS -c"
  [ "$ALLOW_EDITOR" = "1" ] && NVA_FLAGS="$NVA_FLAGS -e"
  [ "$ALLOW_ARDUINO" = "1" ] && NVA_FLAGS="$NVA_FLAGS -a"
  # El telefono, como la camara, tiene dos llaves: esta bandera y el conector local:telefono
  # (que arranca apagado). Y nunca desde el modo remoto: manejar el telefono desde una pagina
  # que entra por la WiFi de casa es justo lo que el modo remoto viene a impedir.
  [ "$ALLOW_TELEFONO" = "1" ] && [ "$MODO_REMOTO" != "1" ] && NVA_FLAGS="$NVA_FLAGS -P"
  # Skills autonomas: NUNCA en modo remoto. Dos de ellas (/builder y /multiply) abren otro agente
  # con permiso de escribir y ejecutar, asi que habilitarlas desde el telefono abriria por atras
  # exactamente el candado que -R cierra por adelante.
  [ "$MODO_REMOTO" != "1" ] && NVA_FLAGS="$NVA_FLAGS -K"
  [ "$ALLOW_DATOS" = "1" ] && NVA_FLAGS="$NVA_FLAGS -D"
  [ "$ALLOW_CARBS" = "1" ] && NVA_FLAGS="$NVA_FLAGS -C"

  # ===================== EL MODO SE APLICA ACA, Y SOLO PUEDE QUITAR =====================
  #
  # Arriba se decidio, conector por conector, QUE PUEDE hacer Mentis en esta maquina. Recien
  # ahora entra el modo elegido (Mentis / Code / Designe / Cowork) y saca de esa lista lo que no
  # le corresponde. El orden es la garantia: como el filtro es una interseccion, un modo no puede
  # encender nada que los conectores hayan dejado apagado. Si algun dia esto se escribiera al
  # reves -- armar las banderas DESDE el modo -- elegir "Code" prenderia la camara aunque el usuario la
  # tenga apagada, y no fallaria ningun test.
  #
  # decisiones personales que valen en cualquier modo. Un "modo sin frenos" que se apaga solo al
  # cambiar de modo es peor que no tenerlo, porque el usuario seguiria creyendo que esta puesto.
  MC_MODO="$(nv_modo_actual)"
  MC_MODO_TITULO="$(nv_modo_titulo "$MC_MODO")"
  MC_MODO_OK=" $(nv_modo_banderas "$MC_MODO") $(_mc_banderas_libres) "
  MC_FLAGS_FILTRADAS=""
  for _f in $NVA_FLAGS; do
    case "$MC_MODO_OK" in *" $_f "*) MC_FLAGS_FILTRADAS="$MC_FLAGS_FILTRADAS $_f" ;; esac
  done
  NVA_FLAGS="$MC_FLAGS_FILTRADAS"

  # Y las herramientas que no tienen bandera propia (exec, git, lsp, delegate...) se apagan por
  # nombre. nv-agent.sh las saca del protocolo Y las rechaza si igual las pide: la leccion de la
  # camara es que una prohibicion que vive solo en el texto del prompt es una sugerencia.
  MC_SIN_TOOLS="$(nv_modo_sin_tools "$MC_MODO")"

  # REPARTO AUTOMATICO (2026-08-14). Los modos que lo declaran ("reparto": true en modos.json --
  # hoy sólo Cowork) arrancan repartiendo: el motor pide un plan y resuelve en paralelo las partes
  # independientes antes de la primera iteración.
  #
  # POR QUE HACE FALTA: medido en eval/duelo-cowork-crewai/, Cowork tenía 'parallel' habilitada y
  # no la usó ni una vez en tres corridas -- resolvió todo en fila. Pedírselo en la persona del
  # modo ya está escrito y no alcanzó: una defensa redactada como instrucción es una sugerencia.
  #
  # Se exigen las DOS cosas -- que el modo lo declare y que tenga la herramienta 'parallel' -- por
  # la misma regla de siempre: el modo sólo puede quitar. Si alguien apaga 'parallel' por
  # herramientas_fuera, el reparto se apaga con ella en vez de sobrevivirle por una clave suelta.
  #
  # Nunca en modo remoto: gasta llamadas desde el teléfono sin que nadie esté mirando.
  # TABLERO DE TAREAS (2026-08-15): los modos que lo declaran muestran la lista de puntos del turno.
  # Nunca en remoto: es una llamada de mas para una pantalla chica donde el panel ni se ve.
  if [ "$(nv_modo_tablero "$MC_MODO")" = "1" ] && [ "$MODO_REMOTO" != "1" ]; then
    NVA_FLAGS="$NVA_FLAGS -T"
  fi

  if [ "$(nv_modo_reparto "$MC_MODO")" = "1" ] && [ "$MODO_REMOTO" != "1" ]; then
    case " $MC_SIN_TOOLS " in
      *" parallel "*) : ;;
      *) NVA_FLAGS="$NVA_FLAGS -p" ;;
    esac
  fi

  NVA_IMG_FLAGS=()
  for _p in "${ATTACH_IMG_PATHS[@]:-}"; do
    [ -n "$_p" ] && NVA_IMG_FLAGS+=("-I" "$_p")
  done
  if [ "$TURN_TIPO" = "trivial" ]; then
    # Cerebro rapido (pedido del usuario, 2026-07-16): nv-agent.sh llama a ask-nvidia.sh en modo RAW
    # (-r), que PISA el system prompt del rol (SYS_FAST) por el protocolo completo de tools --
    # innecesario y mas lento para un "hola"/"gracias" que nunca va a llamar una herramienta.
    # Llamada directa de un solo paso al rol 'fast' (con su SYS_FAST liviano intacto), saltando
    # el loop agentico entero. mismo canal de stderr que nv-agent.sh para no romper el tee/FIFO
    # de progreso de arriba (ask-nvidia.sh solo escribe algun AVISO ahi, nada que romper).
    ANSWER="$(printf '%s' "$MSG" | bash "$TOOLSDIR/ask-nvidia.sh" fast 2>"$MC_ERR_FIFO")"
    [ -z "$ANSWER" ] && ANSWER="Hola! (tuve un problema con el cerebro rápido -- pero acá estoy)"
  else
    ANSWER="$(bash "$TOOLSDIR/nv-agent.sh" $NVA_FLAGS -n "$MC_SIN_TOOLS" "${NVA_IMG_FLAGS[@]}" -d "$ROOT" -m "$TURN_ROLE" -i "$BUDGET" "$TASK" 2>"$MC_ERR_FIFO")"
  fi
  wait "$MC_TEE_PID"
  rm -f "$MC_ERR_FIFO"
  ACTLOG="$(cat "$MC_ERR_TMP")"
  rm -f "$MC_ERR_TMP"

  # Mensaje honesto en vez de volcado crudo (bug real 2026-07-12, protocolo de error pedido
  # por el usuario): cuando nv-agent.sh no llega a 'done', su salida empieza con "STATUS=..." y
  # arrastra TODO el historial interno turno-por-turno -- util para un invocador programatico
  # (ej. fable5v2j-core.sh, que decide con eso), pero pesimo como respuesta de chat para el usuario.
  # nv-agent.sh mismo no se toca (otros llamadores dependen de ese formato); esto solo limpia
  # lo que el usuario VE en esta conversacion.
  if [[ "$ANSWER" == STATUS=* ]]; then
    ANSWER="$(printf '%s' "$ANSWER" | python3 -c '
import sys, re
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8", newline="")
raw = sys.stdin.read()
m = re.match(r"STATUS=(\S+)", raw)
status = m.group(1) if m else "desconocido"
if status == "budget":
    motivo = "se me acabó el presupuesto de pasos disponibles"
elif status == "loop_detectado":
    motivo = "detecté que estaba repitiendo el mismo error sin avanzar y corté para no seguir gastando de más"
else:
    motivo = "dejé de poder generar una respuesta con el formato esperado"
partes = raw.split("observación:")
ultimo = partes[-1].strip() if len(partes) > 1 else ""
if len(ultimo) > 600:
    ultimo = ultimo[:600] + "…"
msg = "No pude terminar del todo esta tarea (" + motivo + "). Esto es lo último que alcancé a hacer:\n\n" + ultimo + "\n\nContame si querés que siga con otro enfoque."
print(msg)
')"
  fi

  # 2 modelos para la respuesta FINAL de los cerebros codigo/lenguaje (decision del usuario,
  # 2026-07-12): nv-agent.sh ya hizo el trabajo real (archivos tocados arriba, con 1 solo
  # modelo por velocidad); ahora la respuesta que VE el usuario se reemplaza por la version
  # verificada con 2 modelos si aplica. Si la verificacion falla o no da nada, se conserva
  # el borrador de nv-agent.sh (nunca se deja al usuario sin respuesta por un fallo de este paso).
  # (el lanzamiento de nv-verify.sh en si corrio en paralelo con nv-agent.sh, ver arriba --
  # aca solo se espera el resultado, no se lanza de nuevo)
  if [ -n "$MC_VERIFY_PID" ]; then
    # PRESUPUESTO DE ESPERA PARA EL VERIFICADOR (2026-08-03, A6 del plan).
    #
    # Antes esto era un `wait` pelado: el turno se quedaba bloqueado hasta que el ensemble
    # terminara, SIN TECHO. Medido sobre turnos reales el 2026-08-03, contando solo el tiempo
    # DESPUES de que el agente ya tenia la respuesta lista:
    #     reason   26,8 s
    #     code    198,9 s
    #     code    138,4 s     <- mediana 138 s
    # Dos a tres minutos mirando una pantalla quieta con la respuesta ya escrita del otro lado.
    # Es, de lejos, la mayor fuente de lentitud de Mentis: mas que todos los demas arreglos de
    # este plan sumados.
    #
    # El ensemble NO se saca, porque cambio la respuesta en 3 de 3 turnos medidos y no hay
    # evidencia de que la empeore. Lo que se saca es el cheque en blanco: si termina dentro del
    # presupuesto, su version se usa igual que siempre; si no, gana la del agente y el ensemble
    # se da de baja. Nunca mas se espera indefinidamente por una mejora que puede no llegar.
    # (El presupuesto ya quedo fijado arriba, al decidir si valia la pena lanzarlo siquiera --
    # ojo con volver a asignarlo aca: la variable se lee en dos lugares y una segunda asignacion
    # con otro default haria que "apagado" y "esperando" no coincidan.)
    MC_VERIFY_T0="$(nv_now_ms)"
    MC_VERIFY_ATIEMPO=true
    for _ in $(seq 1 $(( MC_VERIFY_ESPERA_MAX * 4 ))); do
      kill -0 "$MC_VERIFY_PID" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$MC_VERIFY_PID" 2>/dev/null; then
      MC_VERIFY_ATIEMPO=false
      # Se lo da de baja: dejarlo vivo gastaria cuota para un resultado que ya nadie va a mirar.
      kill "$MC_VERIFY_PID" 2>/dev/null || true
      echo "[mentis-chat] el verificador no llego en ${MC_VERIFY_ESPERA_MAX}s: se usa la respuesta del agente" >&2
    fi
    wait "$MC_VERIFY_PID" 2>/dev/null || true
    MC_VERIFY_ESPERA=$(( $(nv_now_ms) - MC_VERIFY_T0 ))
    VERIFIED=""
    [ "$MC_VERIFY_ATIEMPO" = "true" ] && VERIFIED="$(cat "$MC_VERIFY_TMP" 2>/dev/null)"
    rm -f "$MC_VERIFY_TMP"
    # CUANTO APORTA ESTE PASO, Y CUANTO CUESTA (2026-08-03, Bloque 0.4 del plan).
    #
    # Aca el turno se BLOQUEA esperando al ensemble, y despues reemplaza la respuesta del agente
    # por la del juez. Nadie habia medido nunca dos cosas que deciden si eso vale la pena:
    # cuantas veces el juez CAMBIA algo de verdad, y cuanto se espera de mas por ese cambio.
    # Sin esos numeros, "sacar el ensemble" y "dejarlo" son las dos opiniones, no una decision.
    #
    # Se registra en la misma telemetria que todo lo demas para poder mirarlo despues sin montar
    # otro sistema. Cuesta cero llamadas: son datos que ya estaban en memoria.
    MC_VERIFY_CAMBIO=false
    [ -n "$VERIFIED" ] && [ "$VERIFIED" != "$ANSWER" ] && MC_VERIFY_CAMBIO=true
    nv_log rol="verify-gate" modelo="$TURN_TIPO" latencia_ms="$MC_VERIFY_ESPERA" exit=0 \
           cambio="$MC_VERIFY_CAMBIO" atiempo="$MC_VERIFY_ATIEMPO" \
           chars_antes="${#ANSWER}" chars_despues="${#VERIFIED}" veredicto=
    [ -n "$VERIFIED" ] && ANSWER="$VERIFIED"
  fi

  # Guardia contra respuesta final vacia (bug real reportado por el usuario, 2026-07-16: un mensaje
  # se clasifico mal como "code" -- ver fix en nv-classify-lib.sh -- y el paso de verificacion
  # de codigo devolvio vacio para un pedido que no era codigo; la burbuja de Mentis quedaba
  # completamente en blanco, sin ningun texto, en vez de mostrar algo). Esta guardia es
  # defensiva y generica (no depende de esa causa puntual): protege contra CUALQUIER camino
  # futuro que termine con un ANSWER vacio, sea cual sea la causa.
  if [ -z "${ANSWER// }" ]; then
    echo "[mentis-chat] AVISO: la respuesta final vino vacia -- reemplazada por mensaje honesto" >&2
    ANSWER="No llegué a generar una respuesta con contenido para este mensaje -- pasó algo raro en este turno. ¿Podés repetir o reformular el pedido?"
  fi

  # Guardia contra el prompt interno filtrandose como respuesta (bug real reportado por el usuario,
  # 2026-07-15: vio el system prompt completo -- PERFIL DE USUARIO, KAI VAULT, etc. -- como si
  # fuera una respuesta de Mentis). Estos marcadores son texto LITERAL de la plantilla de
  # _mc_build_task -- nunca deberian aparecer en una respuesta real; solo pueden llegar aca si
  # el modelo (via nv-verify.sh, que recibe el $TASK completo para el ensemble) hace eco de su
  # propio input en vez de responder. Se corta ANTES de _mc_apply_memory_update: si no,
  # el eco tambien arrastraria el bloque de EJEMPLO ```mentis-memory-update``` que la propia
  # persona describe, y se guardaria el placeholder de ese ejemplo como memoria real del usuario.
  if [[ "$ANSWER" == *"PERFIL DE USUARIO:"* ]] || [[ "$ANSWER" == *"KAI VAULT (índice semántico"* ]] || [[ "$ANSWER" == *"MENSAJE NUEVO DE USUARIO:"* ]]; then
    echo "[mentis-chat] AVISO: la respuesta final traia el prompt interno filtrado -- descartada" >&2
    ANSWER="Tuve un problema generando la respuesta final (el modelo devolvió texto interno en vez de una respuesta real) -- pasó algo raro en este turno. ¿Podés repetir o reformular el pedido?"
  fi

  ANSWER="$(_mc_apply_memory_update "$ANSWER" "mentis-memory-update" "userMemory")"
  ANSWER="$(_mc_apply_memory_update "$ANSWER" "mentis-self-memory-update" "selfMemory")"

  # Hook Stop (ver hooks.json + mentis-hooks.sh): corre al cierre del turno, con la respuesta ya
  # final. Va a stderr (no a la burbuja de chat) -- es un aviso para el usuario/vos, no parte de la
  # respuesta que Mentis le da al usuario.
  STOP_HOOK_OUT="$(MENTIS_HOOK_ANSWER="$ANSWER" MENTIS_HOOK_ROOT="${ROOT:-}" bash "$MENTIS_ENV_DIR/mentis-hooks.sh" Stop 2>/dev/null)"
  [ -n "$STOP_HOOK_OUT" ] && echo "[mentis-chat] hooks (Stop): $STOP_HOOK_OUT" >&2

  printf 'Mentis: %s\n' "$ANSWER"

  read -r W E <<< "$(_mc_count_actions "$ACTLOG")"
  SESSION_WRITES=$((SESSION_WRITES + W))
  SESSION_EXECS=$((SESSION_EXECS + E))
  SESSION_TURNS=$((SESSION_TURNS + 1))

  TURN_ARTIFACTS="$(printf '%s\n' "$ACTLOG" | grep '^\[nv-agent\] ARTIFACT: ' | sed 's/^\[nv-agent\] ARTIFACT: //')"
  # Pasos del turno para la narración de proceso persistida (pedido del usuario, 2026-07-12): se
  # guardan junto a la respuesta para que el resumen colapsable sobreviva un reload de la
  # conversación, no solo se vea en vivo. Se descarta "done" (último paso, siempre implícito
  # en que llegó una respuesta -- no aporta nada verlo en el resumen).
  TURN_STEPS="$(printf '%s\n' "$ACTLOG" | grep -oE '^\[nv-agent\] iter [0-9]+:.+' | sed -E 's/^\[nv-agent\] iter [0-9]+: //' | grep -v '^done$')"

  _mc_append_history "usuario" "$MSG_FOR_HISTORY"
  _mc_append_history "mentis" "$ANSWER" "$TURN_ARTIFACTS" "$TURN_STEPS" "$TURN_ROLE"
  _mc_auto_memory "$MSG" "$ANSWER"
  # Compactar lo que ya salio de la ventana de contexto (2026-08-02). Va DESPUES de responder y en
  # segundo plano: comprimir el pasado no puede costarle al usuario ni un segundo del turno siguiente.
  # La funcion decide sola si corresponde (junta lotes de 10 entradas caidas antes de gastar una
  # llamada al modelo); llamarla en cada turno es barato porque el 90% de las veces sale enseguida.
  [ "${MENTIS_COMPACTAR:-1}" = "1" ] && _mc_compactar_bg
  # Mantener al dia la memoria de lo conversado (2026-07-27). En segundo plano y desprendido de
  # este proceso: el indexado es incremental (solo re-embebe lo que cambio), pero aun asi no
  # tiene por que hacerle esperar ni un segundo al usuario antes de poder escribir el mensaje
  # siguiente. Si falla, falla en silencio: no poder indexar no puede romper una conversacion.
  if [ "${MENTIS_RECALL_AUTO:-1}" = "1" ]; then
    ( nohup bash "$TOOLSDIR/../mentis-recordar.sh" indexar >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
done

fi
