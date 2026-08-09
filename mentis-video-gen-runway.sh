#!/usr/bin/env bash
# mentis-video-gen-runway.sh -- genera un video real via Runway (POST /v1/image_to_video +
# polling en /v1/tasks/{id}). Reemplaza a mentis-video-gen-replicate.sh (pedido del usuario,
# 2026-07-14): la key de Replicate nunca se configuro y LTX-Video via Replicate es pago sin
# alternativa gratis -- Runway es la que el usuario consiguio y probo que funciona.
#
# OJO: la API publica de Runway NO tiene texto->video puro, solo image_to_video (imagen +
# texto). Por eso, si solo llega --prompt, este script primero genera un frame fijo con
# mentis-image-gen.sh (mismo patron que mentis-3d-gen.sh) y despues lo anima con Runway.
#
# Verificado en vivo el 2026-07-14 contra la API real de Runway con la key del usuario: auth OK,
# modelo "gen4_turbo" y ratio "1280:720" validos (confirmados por la propia API, no adivinados),
# el POST llega limpio hasta el ultimo paso -- se corta ahi porque la cuenta tiene 0 creditos
# (error explicito de Runway: "You do not have enough credits to run this task."). El polling
# de abajo no se pudo probar de punta a punta por esa falta de creditos; si Runway cambia algo
# del lado de la respuesta de /v1/tasks, el error de mas abajo lo va a mostrar tal cual, no en
# silencio.
#
# Uso: mentis-video-gen-runway.sh -o <archivo salida.mp4> --prompt "<texto>"
#      mentis-video-gen-runway.sh -o <archivo salida.mp4> --image <ruta_imagen> --prompt "<texto>"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RV_OUT=""
RV_PROMPT=""
RV_IMAGE=""
HAVE_IMAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) RV_OUT="$2"; shift 2 ;;
    --prompt) RV_PROMPT="$2"; shift 2 ;;
    --image) RV_IMAGE="$2"; HAVE_IMAGE=1; shift 2 ;;
    *) echo "ERROR: opcion desconocida: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$RV_OUT" ]; then
  echo "ERROR: uso: mentis-video-gen-runway.sh -o <salida.mp4> [--image <ruta>] --prompt \"<texto>\"" >&2
  exit 1
fi
if [ -z "${RV_PROMPT// }" ]; then
  echo "ERROR: falta --prompt (Runway siempre necesita una descripcion de texto, con o sin imagen de entrada)." >&2
  exit 1
fi

RV_SECRETS="$HERE/.custom-models-secrets.env"
RV_KEY=""
if [ -f "$RV_SECRETS" ]; then
  RV_KEY="$(grep '^RUNWAY_API_KEY=' "$RV_SECRETS" | head -1 | sed 's/^RUNWAY_API_KEY=//')"
fi
if [ -z "$RV_KEY" ]; then
  echo "ERROR: no hay RUNWAY_API_KEY configurada (Configuración -> Video en la app de Mentis)." >&2
  exit 1
fi

RV_MODEL="${RUNWAY_VIDEO_MODEL:-gen4_turbo}"
RV_RATIO="${RUNWAY_VIDEO_RATIO:-1280:720}"
RV_DURATION="${RUNWAY_VIDEO_DURATION:-5}"
RV_VERSION="2024-11-06"

# --- Archivos temporales a limpiar siempre (exito o fallo) ---
GENERATED_IMG=""
B64_FILE=""
REQ_FILE=""
CREATE_RESP_FILE=""
POLL_RESP_FILE=""
cleanup() {
  [ -n "$GENERATED_IMG" ] && [ -f "$GENERATED_IMG" ] && rm -f "$GENERATED_IMG"
  [ -n "$B64_FILE" ] && [ -f "$B64_FILE" ] && rm -f "$B64_FILE"
  [ -n "$REQ_FILE" ] && [ -f "$REQ_FILE" ] && rm -f "$REQ_FILE"
  [ -n "$CREATE_RESP_FILE" ] && [ -f "$CREATE_RESP_FILE" ] && rm -f "$CREATE_RESP_FILE"
  [ -n "$POLL_RESP_FILE" ] && [ -f "$POLL_RESP_FILE" ] && rm -f "$POLL_RESP_FILE"
}
trap cleanup EXIT

# --- Resolver imagen de entrada (frame fijo que Runway despues anima) ---
INPUT_IMG=""
if [ "$HAVE_IMAGE" -eq 1 ]; then
  if [ ! -f "$RV_IMAGE" ]; then
    echo "ERROR: la imagen de entrada no existe: $RV_IMAGE" >&2
    exit 1
  fi
  INPUT_IMG="$RV_IMAGE"
else
  GENERATED_IMG="$(mktemp --suffix=.jpg)"
  IMG_GEN_OUT="$(bash "$HERE/mentis-image-gen.sh" -o "$GENERATED_IMG" "$RV_PROMPT" 2>&1)"
  IMG_GEN_RC=$?
  if [ "$IMG_GEN_RC" -ne 0 ] || case "$IMG_GEN_OUT" in ERROR*) true ;; *) false ;; esac; then
    echo "ERROR: no se pudo generar el frame inicial para animar: $IMG_GEN_OUT" >&2
    exit 1
  fi
  INPUT_IMG="$GENERATED_IMG"
fi
if [ ! -s "$INPUT_IMG" ]; then
  echo "ERROR: la imagen de entrada esta vacia o no existe: $INPUT_IMG" >&2
  exit 1
fi

# --- Armar el request: base64 de la imagen via archivo (nunca como argumento de linea de
# comandos -- un JPEG realista en base64 supera el limite de argv, ver bitacora ERR-041) y el
# JSON via python leyendo ese base64 por stdin (nunca con python open() sobre una ruta MSYS,
# ver bitacora ERR-006). ---
B64_FILE="$(mktemp)"
base64 -w0 "$INPUT_IMG" > "$B64_FILE"
REQ_FILE="$(mktemp)"
RV_PROMPT="$RV_PROMPT" RV_MODEL="$RV_MODEL" RV_RATIO="$RV_RATIO" RV_DURATION="$RV_DURATION" python3 -c '
import json, os, sys
b64 = sys.stdin.read().strip()
req = {
    "promptImage": "data:image/jpeg;base64," + b64,
    "promptText": os.environ["RV_PROMPT"],
    "model": os.environ["RV_MODEL"],
    "ratio": os.environ["RV_RATIO"],
    "duration": int(os.environ["RV_DURATION"])
}
print(json.dumps(req))
' < "$B64_FILE" > "$REQ_FILE"

CREATE_RESP_FILE="$(mktemp)"
HTTP_STATUS="$(curl -s -m 60 -o "$CREATE_RESP_FILE" -w '%{http_code}' -X POST "https://api.dev.runwayml.com/v1/image_to_video" \
  -H "Authorization: Bearer $RV_KEY" \
  -H "X-Runway-Version: $RV_VERSION" \
  -H "Content-Type: application/json" \
  --data-binary "@$REQ_FILE")"

RV_TASK_ID="$(python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("id",""))
except Exception:
    pass
' < "$CREATE_RESP_FILE")"

if [ -z "$RV_TASK_ID" ]; then
  echo "ERROR: Runway no acepto el pedido de video (HTTP $HTTP_STATUS). Respuesta: $(head -c 500 "$CREATE_RESP_FILE")" >&2
  exit 1
fi

# --- Polling: Runway no recomienda consultar mas seguido que cada 5s ---
RV_STATUS=""
RV_TRIES=0
RV_OUTPUT_URL=""
while [ "$RV_TRIES" -lt 60 ]; do
  sleep 5
  POLL_RESP_FILE="$(mktemp)"
  curl -s -m 20 "https://api.dev.runwayml.com/v1/tasks/$RV_TASK_ID" \
    -H "Authorization: Bearer $RV_KEY" \
    -H "X-Runway-Version: $RV_VERSION" \
    -o "$POLL_RESP_FILE"
  RV_STATUS="$(python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("status",""))
except Exception:
    print("")
' < "$POLL_RESP_FILE")"
  case "$RV_STATUS" in
    SUCCEEDED|succeeded)
      RV_OUTPUT_URL="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    out = d.get("output")
    if isinstance(out, list): out = out[0] if out else ""
    print(out or "")
except Exception:
    pass
' < "$POLL_RESP_FILE")"
      break
      ;;
    FAILED|failed|CANCELLED|cancelled)
      # failureCode (investigacion 2026-07-14, docs.dev.runwayml.com/errors/task-failures):
      # SAFETY.INPUT.*/SAFETY.OUTPUT.* = rechazo por moderacion (no reintentar tal cual);
      # ASSET.INVALID = la imagen no cumple requisitos (no reintentar sin arreglar el input);
      # THIRD_PARTY.UNAVAILABLE = outage transitorio del proveedor (reintentar mas tarde);
      # INTERNAL = error transitorio de Runway (reintentar). Se muestra explicito para no
      # confundir "hay que arreglar el prompt/imagen" con "hay que reintentar mas tarde".
      RV_ERRINFO="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    code = d.get("failureCode") or ""
    msg = d.get("failure") or d.get("error") or ""
    print((code + ": " if code else "") + msg)
except Exception:
    print("")
' < "$POLL_RESP_FILE")"
      echo "ERROR: Runway no pudo generar el video (status: $RV_STATUS). ${RV_ERRINFO:-sin detalle. Respuesta completa: $(head -c 400 "$POLL_RESP_FILE")}" >&2
      exit 1
      ;;
  esac
  rm -f "$POLL_RESP_FILE"; POLL_RESP_FILE=""
  RV_TRIES=$((RV_TRIES+1))
done

if [ -z "$RV_OUTPUT_URL" ]; then
  echo "ERROR: Runway no termino a tiempo (ultimo status: $RV_STATUS, tarea $RV_TASK_ID) -- probá de nuevo." >&2
  exit 1
fi

if curl -s -m 120 -o "$RV_OUT" "$RV_OUTPUT_URL"; then
  echo "OK: video generado con Runway ($RV_MODEL): $RV_OUT"
  # Tracking de costo real (pedido del usuario, 2026-07-14): gen4_turbo = 5 creditos/segundo x
  # $0.01/credito = $0.05/segundo (confirmado contra docs.dev.runwayml.com/guides/pricing, jul-2026).
  RV_COST="$(python3 -c "print(round($RV_DURATION * 0.05, 4))" 2>/dev/null || echo 0)"
  bash "$HERE/mentis-usage-log.sh" runway video-seconds "$RV_DURATION" "$RV_COST"
else
  echo "ERROR: no se pudo descargar el video generado por Runway." >&2
  exit 1
fi
