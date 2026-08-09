#!/usr/bin/env bash
set -uo pipefail
export PYTHONIOENCODING=utf-8

BASE="https://stabilityai-triposr.hf.space"

MENTIS_OUT=""
MENTIS_PROMPT=""
MENTIS_IMAGE=""
HAVE_PROMPT=0
HAVE_IMAGE=0

# --- Parseo de argumentos ---
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      MENTIS_OUT="$2"; shift 2 ;;
    --prompt)
      MENTIS_PROMPT="$2"; HAVE_PROMPT=1; shift 2 ;;
    --image)
      MENTIS_IMAGE="$2"; HAVE_IMAGE=1; shift 2 ;;
    *)
      echo "ERROR: opcion desconocida: $1"
      exit 1 ;;
  esac
done

if [ -z "$MENTIS_OUT" ]; then
  echo "ERROR: falta -o <ruta_de_salida.glb>"
  exit 1
fi

if [ "$HAVE_PROMPT" -eq 0 ] && [ "$HAVE_IMAGE" -eq 0 ]; then
  echo "ERROR: falta --prompt <texto> o --image <ruta> (uno de los dos es obligatorio)"
  exit 1
fi
if [ "$HAVE_PROMPT" -eq 1 ] && [ "$HAVE_IMAGE" -eq 1 ]; then
  echo "ERROR: pasa --prompt o --image, no ambos"
  exit 1
fi

# --- Archivos temporales a limpiar siempre (exito o fallo) ---
GENERATED_IMG=""
UPLOAD_RESP_FILE=""
CHECK_RESP_FILE=""
PREPROCESS_RESP_FILE=""
GENERATE_RESP_FILE=""

cleanup() {
  [ -n "$GENERATED_IMG" ] && [ -f "$GENERATED_IMG" ] && rm -f "$GENERATED_IMG"
  [ -n "$UPLOAD_RESP_FILE" ] && [ -f "$UPLOAD_RESP_FILE" ] && rm -f "$UPLOAD_RESP_FILE"
  [ -n "$CHECK_RESP_FILE" ] && [ -f "$CHECK_RESP_FILE" ] && rm -f "$CHECK_RESP_FILE"
  [ -n "$PREPROCESS_RESP_FILE" ] && [ -f "$PREPROCESS_RESP_FILE" ] && rm -f "$PREPROCESS_RESP_FILE"
  [ -n "$GENERATE_RESP_FILE" ] && [ -f "$GENERATE_RESP_FILE" ] && rm -f "$GENERATE_RESP_FILE"
}
trap cleanup EXIT

# --- Resolver imagen de entrada ---
INPUT_IMG=""
if [ "$HAVE_PROMPT" -eq 1 ]; then
  GENERATED_IMG="$(mktemp --suffix=.jpg)"
  IMG_GEN_SCRIPT="$HOME/Mentis/mentis-image-gen.sh"
  IMG_GEN_OUT="$(bash "$IMG_GEN_SCRIPT" -o "$GENERATED_IMG" "$MENTIS_PROMPT" 2>&1)"
  IMG_GEN_RC=$?
  if [ "$IMG_GEN_RC" -ne 0 ] || case "$IMG_GEN_OUT" in ERROR*) true ;; *) false ;; esac; then
    echo "$IMG_GEN_OUT"
    exit 1
  fi
  INPUT_IMG="$IMG_GEN_OUT"
else
  if [ ! -f "$MENTIS_IMAGE" ]; then
    echo "ERROR: la imagen de entrada no existe: $MENTIS_IMAGE"
    exit 1
  fi
  INPUT_IMG="$MENTIS_IMAGE"
fi

if [ ! -s "$INPUT_IMG" ]; then
  echo "ERROR: la imagen de entrada esta vacia o no existe: $INPUT_IMG"
  exit 1
fi

# --- Helper: parsear JSON con python3 (PYTHONIOENCODING ya exportado arriba) ---
# Extrae el primer elemento de un array JSON de 1 string (respuesta de /upload)
json_first_array_elem() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data[0])
except Exception as e:
    print("", end="")
'
}

# Extrae el campo event_id de un objeto JSON {"event_id": "..."}
json_event_id() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("event_id", ""))
except Exception:
    print("", end="")
'
}

# Parsea el cuerpo SSE (texto plano con lineas "event:..." y "data:...")
# y determina si el evento final es "complete" o "error".
# Imprime "complete" o "error" o "" (si no se encontro ninguno de los dos, ej: timeout de curl)
sse_final_event() {
  python3 -c '
import sys
text = sys.stdin.read()
event = ""
for line in text.splitlines():
    line = line.strip()
    if line.startswith("event:"):
        event = line.split(":", 1)[1].strip()
print(event)
'
}

# Extrae el campo "data:" (JSON) de la ultima linea "data:" del cuerpo SSE
sse_data_json() {
  python3 -c '
import sys
text = sys.stdin.read()
data_line = ""
for line in text.splitlines():
    line = line.strip()
    if line.startswith("data:"):
        data_line = line.split(":", 1)[1].strip()
print(data_line)
'
}

# Extrae el campo "path" del N-esimo elemento (0-based) de un array JSON de FileData
# uso: echo "$DATA_JSON" | json_path_at_index 0
json_path_at_index() {
  local idx="$1"
  python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data[$idx]['path'])
except Exception:
    print('', end='')
"
}

fail_with() {
  echo "ERROR: $1"
  exit 1
}

# --- Polling con reintentos: hace GET repetidas veces hasta ver event: complete o error ---
# uso: poll_until_complete "<url>" "<timeout_curl>" "<intentos>"
poll_until_complete() {
  local url="$1"
  local curl_timeout="$2"
  local attempts="$3"
  local i=0
  local body=""
  local event=""
  while [ "$i" -lt "$attempts" ]; do
    body="$(curl -s -m "$curl_timeout" "$url" 2>/dev/null)"
    event="$(printf '%s' "$body" | sse_final_event)"
    if [ "$event" = "complete" ] || [ "$event" = "error" ]; then
      printf '%s' "$body"
      return 0
    fi
    i=$((i + 1))
  done
  # timeout total: nunca vimos complete ni error
  printf '%s' "$body"
  return 1
}

# --- 1. Subir imagen ---
UPLOAD_RESP_FILE="$(mktemp)"
HTTP_STATUS="$(curl -s -m 30 -X POST "${BASE}/upload" -F "files=@${INPUT_IMG}" -o "$UPLOAD_RESP_FILE" -w '%{http_code}' 2>/dev/null)"
if [ "$HTTP_STATUS" != "200" ]; then
  fail_with "fallo /upload (HTTP $HTTP_STATUS)"
fi
UPLOADED_PATH="$(json_first_array_elem < "$UPLOAD_RESP_FILE")"
if [ -z "$UPLOADED_PATH" ]; then
  fail_with "no se pudo parsear la ruta subida desde la respuesta de /upload"
fi

# --- 2. (Opcional) validar imagen con check_input_image ---
CHECK_POST_RESP="$(curl -s -m 30 -X POST "${BASE}/call/check_input_image" \
  -H "Content-Type: application/json" \
  -d "{\"data\":[{\"path\":\"${UPLOADED_PATH}\"}]}" 2>/dev/null)"
CHECK_EVENT_ID="$(printf '%s' "$CHECK_POST_RESP" | json_event_id)"
if [ -n "$CHECK_EVENT_ID" ]; then
  CHECK_RESULT="$(poll_until_complete "${BASE}/call/check_input_image/${CHECK_EVENT_ID}" 30 1)"
  CHECK_EVENT="$(printf '%s' "$CHECK_RESULT" | sse_final_event)"
  if [ "$CHECK_EVENT" = "error" ]; then
    fail_with "check_input_image reporto la imagen como invalida"
  fi
  # si no vino "complete" ni "error" (timeout), seguimos igual: es un paso opcional de validacion
fi

# --- 3. Preprocess ---
PREPROCESS_POST_RESP="$(curl -s -m 30 -X POST "${BASE}/call/preprocess" \
  -H "Content-Type: application/json" \
  -d "{\"data\":[{\"path\":\"${UPLOADED_PATH}\"},true,0.85]}" 2>/dev/null)"
PREPROCESS_EVENT_ID="$(printf '%s' "$PREPROCESS_POST_RESP" | json_event_id)"
if [ -z "$PREPROCESS_EVENT_ID" ]; then
  fail_with "no se pudo obtener event_id de /call/preprocess (respuesta: $PREPROCESS_POST_RESP)"
fi

PREPROCESS_RESULT="$(poll_until_complete "${BASE}/call/preprocess/${PREPROCESS_EVENT_ID}" 30 3)"
PREPROCESS_EVENT="$(printf '%s' "$PREPROCESS_RESULT" | sse_final_event)"
if [ "$PREPROCESS_EVENT" != "complete" ]; then
  fail_with "preprocess fallo o no completo a tiempo (evento: '$PREPROCESS_EVENT')"
fi
PREPROCESS_DATA_JSON="$(printf '%s' "$PREPROCESS_RESULT" | sse_data_json)"
PREPROCESSED_PATH="$(printf '%s' "$PREPROCESS_DATA_JSON" | json_path_at_index 0)"
if [ -z "$PREPROCESSED_PATH" ]; then
  fail_with "no se pudo parsear el path de la imagen preprocesada"
fi

# --- 4. Generate (timeout largo, es la parte pesada) ---
GENERATE_POST_RESP="$(curl -s -m 30 -X POST "${BASE}/call/generate" \
  -H "Content-Type: application/json" \
  -d "{\"data\":[{\"path\":\"${PREPROCESSED_PATH}\"},32]}" 2>/dev/null)"
GENERATE_EVENT_ID="$(printf '%s' "$GENERATE_POST_RESP" | json_event_id)"
if [ -z "$GENERATE_EVENT_ID" ]; then
  fail_with "no se pudo obtener event_id de /call/generate (respuesta: $GENERATE_POST_RESP)"
fi

# Polling de generate: timeout de curl generoso (90s) por llamada, varios intentos
GENERATE_RESULT="$(poll_until_complete "${BASE}/call/generate/${GENERATE_EVENT_ID}" 90 5)"
GENERATE_EVENT="$(printf '%s' "$GENERATE_RESULT" | sse_final_event)"
if [ "$GENERATE_EVENT" != "complete" ]; then
  fail_with "generate fallo o no completo a tiempo (evento: '$GENERATE_EVENT')"
fi
GENERATE_DATA_JSON="$(printf '%s' "$GENERATE_RESULT" | sse_data_json)"
GLB_PATH="$(printf '%s' "$GENERATE_DATA_JSON" | json_path_at_index 1)"
if [ -z "$GLB_PATH" ]; then
  fail_with "no se pudo parsear el path del GLB en la respuesta de generate"
fi

# --- 5. Descargar el GLB: reconstruir URL con /file=, IGNORAR el campo "url" ---
DOWNLOAD_URL="${BASE}/file=${GLB_PATH}"
HTTP_STATUS="$(curl -s -m 60 -o "$MENTIS_OUT" -w '%{http_code}' "$DOWNLOAD_URL" 2>/dev/null)"
if [ "$HTTP_STATUS" != "200" ] || [ ! -s "$MENTIS_OUT" ]; then
  rm -f "$MENTIS_OUT"
  fail_with "fallo la descarga del GLB (HTTP $HTTP_STATUS) desde $DOWNLOAD_URL"
fi

# --- 6. Verificar magic bytes glTF ---
MAGIC="$(head -c 4 "$MENTIS_OUT")"
if [ "$MAGIC" != "glTF" ]; then
  rm -f "$MENTIS_OUT"
  fail_with "el archivo descargado no es un GLB valido (magic: $MAGIC)"
fi

printf '%s\n' "$MENTIS_OUT"
exit 0
