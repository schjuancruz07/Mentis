#!/usr/bin/env bash
# mentis-modelos-reparar.sh -- cuando un modelo se muere, buscarle reemplazo y cambiarlo solo.
#
# POR QUE EXISTE:
#   Los modelos del free tier de NVIDIA se MUEREN sin aviso. Ya pasó dos veces con el mismo
#   síntoma: qwen3.5-397b llegó a su fin de vida (410 Gone) y el rol 'extract' tardaba 3 MINUTOS
#   por turno, porque agotaba el intento contra el muerto antes de caer al fallback (ERR-082).
#   El fallback tapa la falla lo suficiente para que nadie la vea, pero se paga en CADA llamada.
#   Hasta ahora arreglarlo era: darse cuenta, medir a mano, y editar bash.
#
# COMO DECIDE (el orden importa y cada paso existe por un motivo):
#   1. CONFIRMA LA MUERTE. 404/410 rápido = muerto. 429/503/sin-respuesta = SATURADO, y ahí no
#      toca NADA: cambiar un modelo porque hoy está saturado tira a la basura una elección que
#      costó mediciones, y el saturado vuelve solo.
#   2. ARMA LA CADENA SOBREVIVIENTE. El muerto sale ya. Y el que sube a principal es el FALLBACK
#      QUE YA VENÍA RESPONDIENDO -- probado en producción, no en laboratorio. Es exactamente lo
#      que se hizo a mano cuando murió el modelo de 'extract'.
#   3. BUSCA CANDIDATO en el catálogo (102 modelos hoy). El catálogo MIENTE (ERR-003: lista
#      modelos que después dan "Not found for account"), así que ningún candidato entra sin una
#      llamada real que lo confirme.
#   4. LE TOMA EL EXAMEN DEL ROL, con respuestas verificables (ver engine/nv-fixtures-roles.sh).
#      "Está vivo" y "sirve para este rol" son dos preguntas distintas.
#   5. EL GANADOR ENTRA AL FONDO de la cadena, nunca de principal. Un modelo que aprobó un examen
#      no es lo mismo que uno con rodaje real; si de verdad es bueno, la telemetría lo va a ir
#      mostrando. Así el rol NUNCA queda peor de lo que estaba.
#
# FRENOS (para que no se envenene solo):
#   - 1 cambio por rol cada 24 h.
#   - Techo de llamadas por reparación (MR_MAX_LLAMADAS).
#   - Si un rol cambió 3 veces en la última semana, deja de tocar y sólo reporta: si cambia tanto,
#     el problema no es el modelo.
#   - Si el catálogo no responde, no hace nada.
#
# Uso:
#   mentis-modelos-reparar.sh -r <rol>      # repara ese rol si está muerto
#   mentis-modelos-reparar.sh -r <rol> -n   # simulacro: dice qué haría, no escribe nada
#   mentis-modelos-reparar.sh -r <rol> -f   # ignora el freno de 1 cambio/24h
set -uo pipefail
export PYTHONIOENCODING=utf-8

MR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MR_NVDIR="$MR_HERE/engine"
# shellcheck source=/dev/null
source "$MR_NVDIR/nv-lib.sh"
# shellcheck source=/dev/null
source "$MR_NVDIR/nv-modelos-lib.sh"
# shellcheck source=/dev/null
source "$MR_NVDIR/nv-fixtures-roles.sh"

MR_ASK="$MR_NVDIR/ask-nvidia.sh"
MR_OVERRIDE="${NV_OVERRIDE_FILE:-$MR_HERE/modelos-override.json}"
MR_CAMBIOS="${MR_CAMBIOS_LOG:-$MR_NVDIR/logs/modelos-cambios.jsonl}"
MR_LOCK="${MR_LOCK_FILE:-$MR_NVDIR/logs/reparar.lock}"
MR_MAX_CANDIDATOS="${MR_MAX_CANDIDATOS:-4}"   # cuantos candidatos VIVOS llegan a rendir examen
MR_MAX_SONDEOS="${MR_MAX_SONDEOS:-20}"        # cuantos se pueden tantear buscando esos vivos
MR_MAX_LLAMADAS="${MR_MAX_LLAMADAS:-45}"      # techo duro de llamadas de toda la reparacion
MR_MIN_APROBADO="${MR_MIN_APROBADO:-60}"

# Lee un campo del rol en modelos-override.json. Imprime vacio si no esta.
_mr_campo_rol() {
  MRC_ROL="$1" MRC_CAMPO="$2" MRC_F="$MR_OVERRIDE" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["MRC_F"], encoding="utf-8"))
    print(d.get("roles", {}).get(os.environ["MRC_ROL"], {}).get(os.environ["MRC_CAMPO"], ""))
except Exception:
    print("")
' 2>/dev/null | tr -d "\r"
}      # % de fixtures que tiene que aprobar un candidato
MR_PAUSA="${MR_PAUSA:-1.5}"                   # segundos entre sondeos (ver _mr_estado: sin esto se fabrican muertos)

MR_ROL=""; MR_SIMULACRO=0; MR_FORZAR=0
while getopts ":r:nfh" opt; do
  case "$opt" in
    r) MR_ROL="$OPTARG" ;;
    n) MR_SIMULACRO=1 ;;
    f) MR_FORZAR=1 ;;
    h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "ERROR: opcion invalida -$OPTARG" >&2; exit 2 ;;
  esac
done

[ -n "$MR_ROL" ] || { echo "ERROR: falta -r <rol>. Roles: code reason deep ultra general extract multimodal fast" >&2; exit 2; }

MR_LLAMADAS=0
_mr_gasto() { MR_LLAMADAS=$((MR_LLAMADAS+1)); }
_mr_sin_presupuesto() { [ "$MR_LLAMADAS" -ge "$MR_MAX_LLAMADAS" ]; }

_mr_log() { echo "[reparar:$MR_ROL] $*" >&2; }

# --- key (misma resolucion que ask-nvidia.sh, para probar lo que de verdad va a pasar) --------
MR_KEY="${NVIDIA_API_KEY:-}"
[ -z "$MR_KEY" ] && MR_KEY="$(nv_read_setting NVIDIA_API_KEY)"
[ -z "$MR_KEY" ] && { echo "ERROR: falta NVIDIA_API_KEY" >&2; exit 2; }
if [ "$MR_ROL" = "ultra" ]; then
  MR_KU="${NVIDIA_API_KEY_NEMOTRON:-}"
  [ -z "$MR_KU" ] && MR_KU="$(nv_read_setting NVIDIA_API_KEY_NEMOTRON)"
  [ -n "$MR_KU" ] && MR_KEY="$MR_KU"
fi

# --- un solo reparador a la vez ---------------------------------------------------------------
# Sin esto, dos roles cayendo al mismo tiempo lanzarían dos reparadores que se pisan el archivo
# de override y gastan el doble de llamadas.
mkdir -p "$(dirname "$MR_LOCK")" 2>/dev/null || true
if ! ( set -o noclobber; echo "$$ $(date +%s)" > "$MR_LOCK" ) 2>/dev/null; then
  MR_EDAD=0
  if [ -f "$MR_LOCK" ]; then
    MR_TS="$(awk '{print $2}' "$MR_LOCK" 2>/dev/null)"
    [ -n "$MR_TS" ] && MR_EDAD=$(( $(date +%s) - MR_TS ))
  fi
  # Un lock de más de 20 minutos es basura de un proceso que murió, no un reparador trabajando.
  if [ "$MR_EDAD" -gt 1200 ]; then
    _mr_log "habia un lock viejo de ${MR_EDAD}s (proceso muerto); lo piso."
    echo "$$ $(date +%s)" > "$MR_LOCK"
  else
    _mr_log "ya hay otra reparacion en curso; salgo."
    exit 0
  fi
fi
trap 'rm -f "$MR_LOCK" 2>/dev/null' EXIT

# --- frenos anti-manoseo ------------------------------------------------------------------------
_mr_cambios_recientes() {
  # $1 = segundos hacia atras. Imprime cuantos cambios hubo de ESTE rol en esa ventana.
  [ -f "$MR_CAMBIOS" ] || { echo 0; return 0; }
  MRC_ROL="$MR_ROL" MRC_DESDE="$(( $(date +%s) - $1 ))" python3 -c '
import json, os, sys
rol = os.environ["MRC_ROL"]; desde = int(os.environ["MRC_DESDE"]); n = 0
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        for linea in f:
            try:
                d = json.loads(linea)
            except Exception:
                continue
            if d.get("rol") == rol and int(d.get("ts", 0)) >= desde:
                n += 1
except Exception:
    pass
print(n)
' "$(nv_winpath "$MR_CAMBIOS")" 2>/dev/null || echo 0
}

if [ "$MR_FORZAR" != "1" ]; then
  MR_EN_24H="$(_mr_cambios_recientes 86400)"
  if [ "${MR_EN_24H:-0}" -ge 1 ]; then
    _mr_log "ya hubo $MR_EN_24H cambio(s) en las ultimas 24 h; no toco nada (usa -f para forzar)."
    exit 0
  fi
  MR_EN_7D="$(_mr_cambios_recientes 604800)"
  if [ "${MR_EN_7D:-0}" -ge 3 ]; then
    _mr_log "ALERTA: $MR_EN_7D cambios en 7 dias. Si cambia tanto, el problema no es el modelo. No toco nada."
    exit 0
  fi
fi

# --- la cadena actual del rol: tabla de ask-nvidia.sh + override vigente ------------------------
MR_LINEA="$(nv_tabla_roles "$MR_ASK" | awk -v r="$MR_ROL" '$1==r {print; exit}')"
[ -n "$MR_LINEA" ] || { _mr_log "el rol '$MR_ROL' no existe en la tabla de ask-nvidia.sh."; exit 2; }
read -r _r MR_P MR_F1 MR_F2 <<< "$MR_LINEA"
[ "$MR_F1" = "-" ] && MR_F1=""
[ "$MR_F2" = "-" ] && MR_F2=""

MR_OVR="$(NV_OVERRIDE_FILE="$MR_OVERRIDE" nv_override_rol "$MR_ROL")"
if [ -n "$MR_OVR" ]; then
  MR_P="${MR_OVR%%|*}"; MR_RESTO="${MR_OVR#*|}"
  MR_F1="${MR_RESTO%%|*}"; MR_F2="${MR_RESTO#*|}"
  _mr_log "el rol ya tenia override vigente; parto de ahi."
fi

_mr_log "cadena actual: principal='$MR_P' fb='$MR_F1' fb2='$MR_F2'"

# --- 1. confirmar la muerte ---------------------------------------------------------------------
# DOS sondeos, no uno: un 404 aislado por un hipo de red no puede costar un cambio de modelo.
# PAUSA ENTRE SONDEOS -- no es prudencia decorativa, corrige un bug medido el 2026-08-01.
# Sondeando el catalogo en un bucle cerrado, NVIDIA empieza a contestar 404 a TODO. Medido: en una
# pasada rapida por los 102 modelos dieron 102 MUERTOS, incluidos deepseek-v4-pro y llama-3.1-8b,
# que estaban respondiendo perfecto un minuto antes y volvieron a responder al reprobarlos con
# calma. Es decir: sondear rapido FABRICA muertos que no existen.
#
# Con eso, el reparador se descartaba candidatos buenos (nemotron-3-nano-30b y gpt-oss-20b, los dos
# vivos, quedaron marcados MUERTO en una corrida real) y -- mucho peor -- podia "confirmar" la
# muerte de un principal sano y reemplazarlo al pedo. Es la version rate-limit de la leccion vieja:
# SATURADO no es MUERTO, sólo que acá el saturado se disfraza de 404.
# La pausa va SIEMPRE, sin llevar cuenta de si es el primer sondeo. La version que llevaba esa
# cuenta con una variable no funcionaba y costo un rato entenderlo: esta funcion se llama siempre
# dentro de $( ), que es un SUBSHELL, asi que cualquier asignacion que haga se pierde al volver --
# cada llamada se creia la primera y no dormia nunca. El sintoma era el de arriba (candidatos
# vivos marcados MUERTO), con la pausa "puesta" pero sin efecto. Dormir de mas una vez no le
# molesta a nadie: esto corre en segundo plano.
_mr_estado() {
  local e
  sleep "${MR_PAUSA:-1.5}"
  e="$(nv_probar_modelo "$1" "$MR_KEY")"
  _mr_gasto
  [ "${MR_DEBUG:-0}" = "1" ] && { echo "[debug] modelo=[$1] len=${#1} keylen=${#MR_KEY} -> $e" >&2; printf "[debug] bytes: " >&2; printf "%s" "$1" | od -c | head -2 >&2; }
  printf '%s' "${e%% *}"
}

# Un TTFT util es un entero de ms. Vacio, "sin-token" o cualquier otra cosa NO es una medicion.
_mr_es_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

MR_CAUSA=""   # que justifica el reemplazo: "muerte" o "presupuesto"

MR_E1="$(_mr_estado "$MR_P")"
_mr_log "sondeo 1 de '$MR_P': $MR_E1"
if [ "$MR_E1" != "MUERTO" ] && [ "$MR_E1" != "SIN-ACCESO" ]; then
  # --- 1bis. VIVO NO ES LO MISMO QUE SIRVE PARA ESTE ROL (2026-08-04) -------------------------
  # Hasta hoy el reparador salia aca: "no esta muerto, nada que reparar". Eso deja pasar un modo
  # de falla que en la practica es indistinguible de la muerte y dura para siempre: el modelo
  # ACEPTA la conexion y termina contestando, pero tarda mas en soltar el primer token que lo que
  # el rol esta dispuesto a esperar (NVTTFT). El rol lo abandona en el 100% de los turnos y se va
  # al fallback -- funciona, pero pagando el presupuesto entero de espera en cada llamada.
  #
  # token en 15-19 s ronda tras ronda. El chequeo lo daba LENTO -> "nada que reparar", mientras
  # caia al fallback en 2 de 2 llamadas reales y sumaba ~21 s muertos por turno. El
  # reparador miraba tiempo TOTAL contra un umbral fijo de 15 s; el rol mira PRIMER TOKEN contra
  # su propio presupuesto. Dos subsistemas midiendo lo mismo con reglas distintas.
  #
  # PRIMERO: medir el presupuesto SOLO tiene sentido contra un endpoint que contesta sano
  # (2026-08-22, ERR-215). Si el sondeo dio SATURADO, ERROR o RARO, el primer token va a venir
  # vacio por el estado del servicio y no por el modelo -- y degradar por eso es tirar a la basura
  # una eleccion que costo mediciones. SATURADO no es MUERTO: vuelve solo.
  case "$MR_E1" in
    VIVO|LENTO) : ;;
    *)
      _mr_log "el sondeo dio $MR_E1: no es muerte, pero tampoco una respuesta sana. No se puede medir el presupuesto contra esto. No toco nada."
      exit 0
      ;;
  esac
  MR_PRESU="$(nv_ttft_rol "$MR_ROL" "$MR_ASK")"; MR_PRESU="${MR_PRESU:-12}"
  MR_T1="$(nv_probar_ttft "$MR_P" "$MR_KEY" "$MR_NVDIR")"; _mr_gasto
  sleep "${MR_PAUSA:-1.5}"
  MR_T2="$(nv_probar_ttft "$MR_P" "$MR_KEY" "$MR_NVDIR")"; _mr_gasto
  _mr_log "primer token de '$MR_P': ${MR_T1:-sin-token}/${MR_T2:-sin-token} ms (el rol espera hasta ${MR_PRESU}s)"

  # LOS DOS sondeos tienen que dar fuera, igual que con la muerte: un pico aislado de latencia no
  # puede costar un cambio de modelo. Es la misma prudencia que evita confundir SATURADO con
  # MUERTO, aplicada a la tercera categoria.
  #
  # Y UN VACIO NO ES UNA MEDICION (2026-08-22, ERR-215). Antes esta rama trataba "sin token" como
  # "peor que pasarse" y degradaba. Con eso, el 21/08 el rol 'general' se cambio por el motivo
  # "tarda sin-token/sin-token ms": dos valores vacios. La regla vive ahora en
  # nv_ttft_veredicto (nv-modelos-lib.sh), que es pura y se testea sola.
  MR_EST_TTFT=""
  if ! _mr_es_num "$MR_T1" || ! _mr_es_num "$MR_T2"; then
    MR_EST_TTFT="$(_mr_estado "$MR_P")"
    _mr_log "  un sondeo no dio numero; reconfirmo el endpoint antes de decidir: $MR_EST_TTFT"
  fi
  MR_VEREDICTO="$(nv_ttft_veredicto "$MR_T1" "$MR_T2" "$(( MR_PRESU * 1000 ))" "$MR_EST_TTFT")"
  _mr_log "veredicto de presupuesto para '$MR_P': $MR_VEREDICTO"
  if [ "$MR_VEREDICTO" = "NO-MEDIBLE" ]; then
    _mr_log "NO SE PUDO MEDIR el primer token de '$MR_P' (endpoint: ${MR_EST_TTFT:-sin dato}). Un rol no se degrada por algo que no se midio."
    exit 0
  fi
  if [ "$MR_VEREDICTO" = "FUERA" ]; then
    # CALIDAD ANTES QUE VELOCIDAD (2026-08-21). Hay roles donde un modelo lento y bueno vale mas
    # que uno rapido y peor. El reparador no puede saberlo -- mide latencia, no calidad -- asi que
    # se lo dice el propio rol con "calidad_primero": true en modelos-override.json.
    #
    # POR QUE EXISTE, con los numeros: el 14/08 esta misma rama degrado el rol 'code' de
    # deepseek-v4-flash a nemotron-nano-30b porque el primero "tardaba". Medido despues con el
    # duelo de codigo (arreglar 3 bugs reales en un archivo, 3 vueltas): deepseek 3 de 3 con
    # mediana 69 s, nemotron-nano 1 de 3 con mediana 118 s. El cambio hecho POR VELOCIDAD dejo un
    # modelo peor Y mas lento, y nadie lo noto en una semana.
    #
    # Esto NO apaga el reparador: si el principal se MUERE, sigue actuando igual. Lo unico que ya
    # no puede hacer es cambiarlo por lento.
    if [ "$(_mr_campo_rol "$MR_ROL" calidad_primero)" = "True" ]; then
      _mr_log "'$MR_P' tarda, pero el rol '$MR_ROL' esta marcado como calidad_primero: NO se cambia por lentitud."
      _mr_log "  (si de verdad hay que cambiarlo, medilo antes con eval/duelo-code/duelo.sh y hacelo a mano)"
      exit 0
    fi
    MR_CAUSA="presupuesto"
    _mr_log "FUERA DE PRESUPUESTO confirmado: '$MR_P' esta vivo pero no llega a tiempo para '$MR_ROL'. Buscando reemplazo."
  else
    _mr_log "el principal no esta muerto (esta $MR_E1) y llega dentro del presupuesto. Nada que reparar."
    exit 0
  fi
fi

if [ -z "$MR_CAUSA" ]; then
  sleep 2
  MR_E2="$(_mr_estado "$MR_P")"
  _mr_log "sondeo 2 de '$MR_P': $MR_E2"
  if [ "$MR_E2" != "MUERTO" ] && [ "$MR_E2" != "SIN-ACCESO" ]; then
    _mr_log "el segundo sondeo dio $MR_E2: no hay muerte confirmada. No toco nada."
    exit 0
  fi
  MR_CAUSA="muerte"
  _mr_log "MUERTE CONFIRMADA de '$MR_P' ($MR_E1/$MR_E2). Buscando reemplazo."
fi

# --- 2. cadena sobreviviente --------------------------------------------------------------------
# Los fallbacks tambien pueden estar muertos; se prueban antes de ascender a ninguno.
MR_VIVOS=()
# Vivos que NO entran en el presupuesto del rol. No sirven de principal, pero tampoco se tiran:
# como ultimo eslabon de la cadena, un modelo lento sigue siendo mejor que quedarse sin respuesta.
MR_LENTOS_OK=()
# "<ms> <modelo>" de cada uno que SI entra, para poder ordenar la cadena por velocidad.
MR_TTFT_DE=()
for m in "$MR_F1" "$MR_F2"; do
  [ -n "$m" ] || continue
  e="$(_mr_estado "$m")"
  _mr_log "fallback '$m': $e"
  case "$e" in
    VIVO|LENTO|SATURADO)
      # Cuando se reemplaza POR PRESUPUESTO, un fallback que tampoco llega a tiempo no sirve de
      # ascenso: seria cambiar un modelo que no atiende por otro que tampoco. Sigue estando como
      # respaldo (mejor tarde que nada si el de arriba se cae), pero no puede quedar de principal.
      if [ "$MR_CAUSA" = "presupuesto" ]; then
        t="$(nv_probar_ttft "$m" "$MR_KEY" "$MR_NVDIR")"; _mr_gasto
        if [ -z "$t" ] || [ "$t" -gt $(( MR_PRESU * 1000 )) ]; then
          _mr_log "  '$m' esta vivo pero su primer token (${t:-sin-token} ms) tampoco entra en ${MR_PRESU}s: no puede ascender a principal."
          MR_LENTOS_OK+=("$m")
          continue
        fi
        _mr_log "  '$m' llega en ${t} ms: sirve como principal."
        MR_TTFT_DE+=("$t $m")
      fi
      MR_VIVOS+=("$m")
      ;;
    *) _mr_log "  '$m' tambien esta caido; sale de la cadena." ;;
  esac
done

# GUARDA DE CORDURA: si el principal Y todos sus fallbacks dan muertos a la vez, la explicacion
# mucho mas probable no es que se hayan muerto todos juntos -- es que estamos limitados por tasa,
# o que se cayo la red, o que la API key dejo de servir. Actuar sobre esa lectura seria destruir
# una configuracion sana por un problema pasajero. Ante la duda, no se toca nada.
# La guarda mira si quedo algo RESPONDIENDO, no si quedo algo ascendible. Un fallback vivo pero
# lento demuestra que la red, la key y la cuenta estan bien -- que es justo lo que esta guarda
# quiere descartar. Sin esta distincion, un rol cuyos tres modelos estan vivos y lentos abortaria
# aca por "todos caidos" y nunca llegaria a buscar un reemplazo rapido, que es lo unico que lo
# arregla.
if [ "${#MR_VIVOS[@]}" -eq 0 ] && [ "${#MR_LENTOS_OK[@]}" -eq 0 ]; then
  _mr_log "ALERTA: el principal Y todos los fallbacks dieron caidos a la vez."
  _mr_log "Eso casi nunca significa que se murieron todos: significa limite de uso, red caida o key vencida."
  _mr_log "No toco NADA. Si de verdad estan todos muertos, va a volver a saltar mas tarde con la red sana."
  exit 1
fi

# --- 3. candidatos del catalogo ------------------------------------------------------------------
MR_CATALOGO="$(nv_catalogo "$MR_KEY")"
if [ -z "$MR_CATALOGO" ]; then
  _mr_log "el catalogo no respondio; no puedo buscar candidatos. No toco nada."
  exit 1
fi
_mr_log "catalogo: $(printf '%s\n' "$MR_CATALOGO" | grep -c.) modelos."

# RANKING -- la version anterior ordenaba por tamaño parecido al modelo muerto, y en la primera
# prueba real los 6 primeros candidatos estaban TODOS muertos: para un muerto de 397B, "parecido"
# significaba modelos gigantes viejos (nemotron-4-340b, llama-3.1-nemotron-253b), que son
# justamente los que NVIDIA ya dio de baja. El tamaño no predice nada sobre estar vivo.
#
# Lo que SI predice, y se puede medir: la FAMILIA. Los modelos que responden hoy comparten prefijo
# con los que la tabla ya usa y funcionan (deepseek-v4-*, nemotron-3-*, gpt-oss-*, glm-5*). El
# catálogo tampoco ayuda a distinguirlos: los 102 modelos traen el MISMO valor de "created", así
# que no hay señal de novedad para aprovechar. Así que se apuesta a las familias con evidencia.
#
# Igual, nada de esto decide nada por sí solo: todo candidato pasa después por una llamada real
# (ERR-003, el catálogo miente) y por el examen del rol.
MR_YA_USADOS="$(nv_tabla_roles "$MR_ASK" | awk '{print $2"\n"$3"\n"$4}' | grep -v '^-$' | sort -u)"
MR_CANDIDATOS="$(MRK_MUERTO="$MR_P" MRK_VIVOS="$(printf '%s\n' "${MR_VIVOS[@]:-}")" \
                 MRK_USADOS="$MR_YA_USADOS" MRK_N="$(( MR_MAX_CANDIDATOS * 4 ))" \
                 python3 -c '
import os, re, sys

muerto = os.environ["MRK_MUERTO"]
vivos  = [x for x in os.environ.get("MRK_VIVOS","").split("\n") if x.strip()]
usados = {x.strip() for x in os.environ.get("MRK_USADOS","").split("\n") if x.strip()}
n      = int(os.environ["MRK_N"])
cat    = [l.strip() for l in sys.stdin if l.strip()]

# Familias que no sirven para un rol de chat: embeddings, reranking, guardia, OCR, voz, video.
FUERA = ("embed", "rerank", "guard", "ocr", "speech", "asr", "tts", "riva", "vila-embed",
         "nemoretriever", "parakeet", "diffusion", "sana", "flux", "stable-", "sdxl")

def tam(mid):
    """Parametros en miles de millones, deducidos del id. 0 si no se puede."""
    m = re.findall(r"(\d+(?:\.\d+)?)\s*b\b", mid.lower())
    return max((float(x) for x in m), default=0.0)

def vendor(mid):
    return mid.split("/")[0].lower() if "/" in mid else mid.lower()

def familia(mid):
    """vendor + los dos primeros tramos del nombre: la generacion del modelo.
       deepseek-ai/deepseek-v4-pro          -> deepseek-ai/deepseek-v4
       nvidia/nemotron-3-super-120b-a12b    -> nvidia/nemotron-3
       openai/gpt-oss-120b                  -> openai/gpt-oss
       z-ai/glm-5.2                         -> z-ai/glm-5.2
       Es la señal que de verdad separa lo vivo de lo dado de baja."""
    v = vendor(mid)
    nombre = mid.split("/", 1)[1].lower() if "/" in mid else mid.lower()
    return v + "/" + "-".join(nombre.split("-")[:2])

tam_muerto = tam(muerto)
vendors_vivos = {vendor(v) for v in vivos}
# Familias sobre las que el sistema ya apuesta hoy: las de la tabla en uso mas las que se
# acaban de probar vivas en esta misma corrida.
familias_ok = {familia(x) for x in list(usados) + vivos if x}

cands = []
for mid in cat:
    low = mid.lower()
    if any(f in low for f in FUERA):
        continue
    if mid == muerto or mid in usados:
        continue
    t = tam(mid)
    # Puntaje: mas alto = mejor candidato. Se ordena por esto.
    p = 0.0
    # LA SEÑAL FUERTE: pertenece a una generacion que hoy responde.
    if familia(mid) in familias_ok:
        p += 120.0
    # Diversidad de vendor: suma si aporta un vendor que la cadena no tiene (el ensemble de
    # nv-verify.sh pierde sentido si todos los modelos son del mismo).
    if vendor(mid) not in vendors_vivos:
        p += 40.0
    # Mismo vendor que el muerto: suele ser el sucesor natural del que murio.
    if vendor(mid) == vendor(muerto):
        p += 25.0
    # Cercania de tamano: se conserva, pero con poco peso -- ya demostro que no predice nada
    # sobre disponibilidad, solo sirve para desempatar entre dos candidatos igual de plausibles.
    if tam_muerto > 0 and t > 0:
        p += 30.0 / (1.0 + abs(t - tam_muerto) / max(tam_muerto, 1.0))
    # Señales de que es un modelo de instrucciones/chat, que es lo que hace falta.
    if "instruct" in low or "chat" in low:
        p += 15.0
    cands.append((p, mid))

cands.sort(key=lambda x: (-x[0], x[1]))
for _, mid in cands[:n]:
    print(mid)
' <<< "$MR_CATALOGO" | tr -d '\r')"
# El tr -d "\r" de arriba: python en Windows escribe CRLF y, en una salida de varias lineas, $( )
# solo limpia la ultima -- las demas quedan con un \r pegado. Sin esto, cada id de modelo se
# consultaba como "vendor/modelo\r", NVIDIA devolvia 404 y el reparador concluia "esta muerto"
# sobre modelos perfectamente vivos. Ver el comentario largo en nv_catalogo (engine/nv-modelos-lib.sh).

if [ -z "$MR_CANDIDATOS" ]; then
  _mr_log "el catalogo no ofrecio ningun candidato utilizable."
  exit 1
fi
_mr_log "candidatos a probar: $(printf '%s' "$MR_CANDIDATOS" | tr '\n' ' ')"

# --- 4. examen: vivo primero, despues el examen del rol -------------------------------------------
MR_GANADOR=""; MR_GANADOR_PUNTAJE=""; MR_GANADOR_PCT=0
MR_EXAMINADOS=0; MR_SONDEOS=0
# Se recorre la lista hasta EXAMINAR MR_MAX_CANDIDATOS candidatos VIVOS, no hasta descartar los
# primeros N. En la primera prueba real, los 6 primeros del catalogo estaban muertos y la busqueda
# terminaba sin haber examinado a nadie. Un sondeo a un muerto es barato -- contesta su 404 en
# medio segundo -- asi que descartarlos tiene que costar poco y no consumir el cupo de examenes.
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ "$MR_EXAMINADOS" -ge "$MR_MAX_CANDIDATOS" ] && break
  if [ "$MR_SONDEOS" -ge "$MR_MAX_SONDEOS" ]; then
    _mr_log "techo de $MR_MAX_SONDEOS sondeos alcanzado; corto la busqueda aca."
    break
  fi
  if _mr_sin_presupuesto; then
    _mr_log "techo de $MR_MAX_LLAMADAS llamadas alcanzado; corto la busqueda aca."
    break
  fi
  MR_SONDEOS=$((MR_SONDEOS+1))
  est="$(_mr_estado "$cand")"
  if [ "$est" != "VIVO" ] && [ "$est" != "LENTO" ]; then
    _mr_log "  '$cand': $est -- descartado (el catalogo lo listaba igual, ERR-003)."
    continue
  fi
  # Si lo que se esta reemplazando es un modelo que no llega a tiempo, el candidato tiene que
  # llegar a tiempo. Se mide ANTES del examen a proposito: el examen cuesta 3 llamadas y no tiene
  # sentido gastarlas en alguien que ya quedo afuera por el reloj.
  if [ "$MR_CAUSA" = "presupuesto" ]; then
    tc="$(nv_probar_ttft "$cand" "$MR_KEY" "$MR_NVDIR")"; _mr_gasto
    if [ -z "$tc" ] || [ "$tc" -gt $(( MR_PRESU * 1000 )) ]; then
      _mr_log "  '$cand': primer token ${tc:-sin-token} ms -- no entra en ${MR_PRESU}s, descartado sin examen."
      continue
    fi
    _mr_log "  '$cand': primer token ${tc} ms (entra en ${MR_PRESU}s), va a examen."
    MR_TTFT_CAND="$tc"
  fi
  MR_EXAMINADOS=$((MR_EXAMINADOS+1))
  punt="$(nv_puntaje_modelo "$cand" "$MR_KEY" "$MR_ROL")"
  MR_LLAMADAS=$((MR_LLAMADAS + 3))
  bien="${punt%%/*}"; resto="${punt#*/}"; total="${resto%% *}"; ms="${punt##* }"
  pct=0; [ "${total:-0}" -gt 0 ] && pct=$(( bien * 100 / total ))
  _mr_log "  '$cand': VIVO, examen $bien/$total (${pct}%), ~${ms} ms"
  if [ "$pct" -ge "$MR_MIN_APROBADO" ] && [ "$pct" -gt "$MR_GANADOR_PCT" ]; then
    MR_GANADOR="$cand"; MR_GANADOR_PUNTAJE="$punt"; MR_GANADOR_PCT="$pct"
    MR_GANADOR_TTFT="${MR_TTFT_CAND:-}"
  fi
done <<< "$MR_CANDIDATOS"

if [ -z "$MR_GANADOR" ]; then
  _mr_log "ningun candidato aprobo el examen del rol (minimo ${MR_MIN_APROBADO}%)."
  if [ "${#MR_VIVOS[@]}" -eq 0 ]; then
    if [ "$MR_CAUSA" = "presupuesto" ]; then
      # Nadie entra en el presupuesto. Reordenar lentos entre si no mejora nada y perderia el
      # rodaje de la cadena actual; se deja como esta y se avisa.
      _mr_log "ningun modelo disponible entra en ${MR_PRESU}s para '$MR_ROL'. Dejo la cadena como esta."
      _mr_log "El rol va a seguir cayendo al fallback en cada llamada: esto necesita una decision a mano."
      exit 1
    fi
    _mr_log "y no queda ningun fallback vivo: el rol '$MR_ROL' necesita atencion a mano."
    exit 1
  fi
  _mr_log "igual saco al muerto de la cadena: eso solo ya ahorra un timeout por llamada."
else
  _mr_log "GANADOR: '$MR_GANADOR' ($MR_GANADOR_PUNTAJE)"
fi

# --- 5. armar la cadena nueva ----------------------------------------------------------------------
# El muerto sale. Sube el fallback CON RODAJE. El candidato nuevo entra al fondo.
MR_NUEVA=()
if [ "$MR_CAUSA" = "presupuesto" ]; then
  # ORDEN POR VELOCIDAD, NO POR RODAJE (corregido 2026-08-04, tras verlo fallar en vivo).
  #
  # La regla "sube el fallback con rodaje" es la correcta cuando el principal se MURIO: hay un
  # hueco que tapar y el fallback ya demostro en produccion que sirve. Pero cuando lo que se esta
  # arreglando es la LATENCIA, ascender por antiguedad puede empeorar el rol.
  #
  # (11.729 ms de mediana contra un presupuesto de 12 s, y 2 de 6 sondeos sin respuesta) mientras
  # nemotron-3-nano-30b -- 862 ms y 15/15 en el examen del rol -- quedaba tercero. Se cambio un
  # modelo que no llegaba a tiempo por otro que apenas llega, en el rol con consecuencia medica.
  #
  # Si el criterio del reemplazo es el reloj, el orden tambien tiene que ser el reloj.
  [ -n "$MR_GANADOR" ] && [ -n "${MR_GANADOR_TTFT:-}" ] && MR_TTFT_DE+=("$MR_GANADOR_TTFT $MR_GANADOR")
  while read -r _ms m; do
    [ -n "$m" ] && MR_NUEVA+=("$m")
  done < <(printf '%s\n' "${MR_TTFT_DE[@]:-}" | grep -E '^[0-9]+ ' | sort -n)
  # Un aprobado del examen que se haya quedado sin medicion de tiempo no puede perderse.
  if [ -n "$MR_GANADOR" ] && [ -z "${MR_GANADOR_TTFT:-}" ]; then MR_NUEVA+=("$MR_GANADOR"); fi
else
  for m in "${MR_VIVOS[@]:-}"; do [ -n "$m" ] && MR_NUEVA+=("$m"); done
  [ -n "$MR_GANADOR" ] && MR_NUEVA+=("$MR_GANADOR")
fi
# Los que estan vivos pero no llegan a tiempo van al FONDO, no a la basura. Un modelo lento es un
# mal principal y un respaldo perfectamente valido: si los de arriba se caen, contestar tarde
# sigue siendo mejor que no contestar. Incluye al principal viejo, que por definicion no esta
# muerto -- llegar tarde fue todo su problema.
if [ "$MR_CAUSA" = "presupuesto" ]; then
  for m in "${MR_LENTOS_OK[@]:-}"; do [ -n "$m" ] && MR_NUEVA+=("$m"); done
  MR_NUEVA+=("$MR_P")
fi

if [ "${#MR_NUEVA[@]}" -eq 0 ]; then
  _mr_log "no quedo ningun modelo para armar la cadena. No escribo nada."
  exit 1
fi

MR_NP="${MR_NUEVA[0]}"
MR_NF1="${MR_NUEVA[1]:-}"
MR_NF2="${MR_NUEVA[2]:-}"

echo
echo "  Rol '$MR_ROL':"
echo "    antes : $MR_P  ->  ${MR_F1:--}  ->  ${MR_F2:--}"
echo "    ahora : $MR_NP  ->  ${MR_NF1:--}  ->  ${MR_NF2:--}"
if [ "$MR_CAUSA" = "presupuesto" ]; then
  # Como se lee el numero del primer token en los textos que quedan archivados. Si los dos sondeos
  # vinieron vacios, el veredicto ya confirmo que el endpoint estaba SANO -- decirlo asi es la
  # verdad. "tarda sin-token/sin-token ms" fue lo que hizo ilegible el cambio del rol 'general'
  # el 21/08: una frase que no dice ningun numero y ademas suena a que si lo dice (ERR-215).
  if _mr_es_num "${MR_T1:-}" || _mr_es_num "${MR_T2:-}"; then
    MR_TTFT_TXT="tarda ${MR_T1:-sin-token}/${MR_T2:-sin-token} ms en el primer token"
  else
    MR_TTFT_TXT="nunca emitio un primer token en dos sondeos, con el endpoint contestando sano (${MR_EST_TTFT:-VIVO})"
  fi
  echo "    motivo: '$MR_P' esta vivo pero $MR_TTFT_TXT, y '$MR_ROL' espera hasta ${MR_PRESU}s"
else
  echo "    motivo: '$MR_P' esta muerto ($MR_E1)"
fi
if [ -n "$MR_GANADOR" ]; then
  if [ "$MR_CAUSA" = "presupuesto" ]; then
    echo "    nuevo : '$MR_GANADOR' entra tras aprobar $MR_GANADOR_PUNTAJE del examen de '$MR_ROL'; la cadena quedo ordenada por primer token"
  else
    echo "    nuevo : '$MR_GANADOR' entra al fondo tras aprobar $MR_GANADOR_PUNTAJE del examen de '$MR_ROL'"
  fi
fi
echo

if [ "$MR_SIMULACRO" = "1" ]; then
  echo "  (simulacro: no se escribio nada)"
  exit 0
fi

# --- 6. escribir el override + el recibo -----------------------------------------------------------
MR_TS_AHORA="$(date +%s)"
MR_FECHA="$(date '+%Y-%m-%dT%H:%M:%S%z')"
# El motivo queda archivado en modelos-override.json y es lo unico que va a explicar este cambio
# dentro de seis meses. "no responde (LENTO)" seria enganoso para un reemplazo por presupuesto: el
# modelo SI respondia. Lo que no hacia era llegar a tiempo, y ese numero es el dato que importa.
if [ "$MR_CAUSA" = "presupuesto" ]; then
  MR_MOTIVO_TXT="'$MR_P' esta vivo pero ${MR_TTFT_TXT:-no llega a tiempo} y el rol '$MR_ROL' espera hasta ${MR_PRESU}s: caia al fallback en cada llamada. Reemplazo automatico."
else
  MR_MOTIVO_TXT="'$MR_P' no responde ($MR_E1); reemplazo automatico"
fi
MRW_ROL="$MR_ROL" MRW_M="$MR_NP" MRW_F1="$MR_NF1" MRW_F2="$MR_NF2" \
MRW_APM="$MR_P" MRW_APF1="$MR_F1" MRW_APF2="$MR_F2" \
MRW_MOTIVO="$MR_MOTIVO_TXT" MRW_FECHA="$MR_FECHA" \
python3 -c '
import json, os, sys
ruta = sys.argv[1]
try:
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d.setdefault("version", 1)
d.setdefault("roles", {})
d["roles"][os.environ["MRW_ROL"]] = {
    "modelo":    os.environ["MRW_M"],
    "fallback":  os.environ["MRW_F1"],
    "fallback2": os.environ["MRW_F2"],
    "desde":     os.environ["MRW_FECHA"],
    "motivo":    os.environ["MRW_MOTIVO"],
    # "anterior" es lo que hace posible revertir sin adivinar.
    "anterior": {
        "modelo":    os.environ["MRW_APM"],
        "fallback":  os.environ["MRW_APF1"],
        "fallback2": os.environ["MRW_APF2"],
    },
}
# Escritura atomica: si esto se corta a la mitad, el JSON roto dejaria al rol sin override en la
# proxima llamada (degrada bien, pero se perderia el cambio). Se escribe al lado y se renombra.
tmp = ruta + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.replace(tmp, ruta)
print("ok")
' "$(nv_winpath "$MR_OVERRIDE")" >/dev/null 2>&1 || { _mr_log "ERROR: no pude escribir $MR_OVERRIDE"; exit 1; }

# Igual que en mentis-modelos.sh: el override cambio, la memoria corta tiene que morir ya.
nv_memo_limpiar 2>/dev/null || true

mkdir -p "$(dirname "$MR_CAMBIOS")" 2>/dev/null || true
MRL_ROL="$MR_ROL" MRL_TS="$MR_TS_AHORA" MRL_FECHA="$MR_FECHA" \
MRL_DE="$MR_P" MRL_A="$MR_NP" MRL_NUEVO="$MR_GANADOR" MRL_PUNT="$MR_GANADOR_PUNTAJE" \
MRL_EST="$([ "$MR_CAUSA" = "presupuesto" ] && printf 'FUERA-DE-PRESUPUESTO' || printf '%s' "$MR_E1")" MRL_LLAM="$MR_LLAMADAS" \
python3 -c '
import json, os, sys
d = {
    "ts": int(os.environ["MRL_TS"]), "fecha": os.environ["MRL_FECHA"],
    "rol": os.environ["MRL_ROL"], "de": os.environ["MRL_DE"], "a": os.environ["MRL_A"],
    "candidato_nuevo": os.environ["MRL_NUEVO"], "examen": os.environ["MRL_PUNT"],
    "estado_del_muerto": os.environ["MRL_EST"], "llamadas_gastadas": int(os.environ["MRL_LLAM"]),
}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(d, ensure_ascii=False) + "\n")
' "$(nv_winpath "$MR_CAMBIOS")" 2>/dev/null || true

echo "  Listo. Se deshace con:  mentis-modelos.sh revertir $MR_ROL"
echo "  (gastó $MR_LLAMADAS llamadas de las $MR_MAX_LLAMADAS del techo)"
exit 0
