#!/usr/bin/env bash
set -uo pipefail

OUT=""
while getopts ":o:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    *) echo "ERROR: opcion invalida"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
IMG_PROMPT="$*"

if [ -z "${IMG_PROMPT// }" ]; then
  echo "ERROR: falta el prompt de texto" >&2
  exit 1
fi
if [ -z "$OUT" ]; then
  echo "ERROR: falta -o <ruta_de_salida.jpg>" >&2
  exit 1
fi

# === CAMINO PRINCIPAL: FLUX por NVIDIA ======================================================
# (2026-07-28) Antes esto era Pollinations y nada mas. Flux entra adelante porque es mejor en las
# tres dimensiones que importan aca: calidad de imagen, y ademas no tiene ni el cache envenenado
# de Cloudflare ni el placeholder de rate-limit que obligaron a los dos parches de mas abajo.
# Cuesta lo mismo (cero): usa la NVIDIA_API_KEY que Mentis ya tiene.
#
# El payload costo encontrarlo y la pista estaba en el propio endpoint: mandarle 'aspect_ratio'
# devuelve 422 con el detalle exacto ("Extra inputs are not permitted"), no un 503 generico. El
# 503 que se venia viendo era otra cosa -- el free tier lleno ("ResourceExhausted"), que no tiene
# nada que ver con el payload. Por eso el diagnostico viejo ("payload sin acertar por el 503")
# apuntaba al lado equivocado: el tamano se pide con width/height, NO con aspect_ratio.
NVIDIA_IMG_URL="${NVIDIA_IMG_URL:-https://ai.api.nvidia.com/v1/genai/black-forest-labs/flux.1-dev}"
HERE_IMG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE_IMG/engine/nv-lib.sh"

gen_nvidia() {
  local key resp code resp_w out_w
  key="${NVIDIA_API_KEY:-}"
  [ -z "$key" ] && key="$(nv_read_setting NVIDIA_API_KEY 2>/dev/null)"
  [ -z "$key" ] && return 1
  resp="$(mktemp)"
  code="$(NVI_PROMPT="$IMG_PROMPT" python3 -c '
import json,os,sys
print(json.dumps({"prompt":os.environ["NVI_PROMPT"],"mode":"base","cfg_scale":3.5,
                  "width":1024,"height":1024,"seed":0,"steps":30}))' 2>/dev/null | \
    curl -s -o "$resp" -w '%{http_code}' -m 120 -X POST "$NVIDIA_IMG_URL" \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -H 'Accept: application/json' --data-binary @- 2>/dev/null)"
  if [ "$code" != "200" ]; then
    # El detalle importa: 422 = payload mal (arreglable aca), 503 = free tier lleno (transitorio).
    echo "[mentis-image-gen] NVIDIA devolvio HTTP $code: $(head -c 200 "$resp" 2>/dev/null)" >&2
    rm -f "$resp"; return 1
  fi
  # La imagen viene en artifacts[0].base64 (JPEG). Se decodifica en python -- el base64 de 1024x1024
  # ronda los 160 KB y no entra por argv.
  # Rutas convertidas a formato Windows ANTES de pasarlas (ERR-004/ERR-006): este python3 es el
  # nativo de Windows y NO entiende rutas MSYS -- medido: open("/c/Users/...") -> FileNotFoundError.
  # (MSYS igual convierte solo los valores de las env vars que parecen ruta, pero depender de esa
  # magia implicita es como no tener el arreglo: se rompe el dia que la ruta no le "parezca" una.)
  resp_w="$(nv_winpath "$resp")"; out_w="$(nv_winpath "$OUT")"
  if ! NVI_RESP="$resp_w" NVI_OUT="$out_w" python3 -c '
import base64,json,os,sys
d=json.load(open(os.environ["NVI_RESP"],encoding="utf-8"))
arts=d.get("artifacts") or []
if not arts or not arts[0].get("base64"): sys.exit(1)
raw=base64.b64decode(arts[0]["base64"])
if len(raw)<1000 or raw[:2]!=b"\xff\xd8": sys.exit(1)   # tiene que ser un JPEG de verdad
open(os.environ["NVI_OUT"],"wb").write(raw)
' 2>/dev/null; then
    echo "[mentis-image-gen] NVIDIA respondio 200 pero sin una imagen valida" >&2
    rm -f "$resp"; return 1
  fi
  rm -f "$resp"
  [ -s "$OUT" ]
}

if gen_nvidia; then
  printf '%s\n' "$OUT"
  exit 0
fi
echo "[mentis-image-gen] flux/NVIDIA no pudo generar; probando con Pollinations..." >&2

# === FALLBACK: Pollinations (sin key, pero con dos trampas ya pagadas) ======================
ENCODED="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))' "$IMG_PROMPT" 2>/dev/null)"
if [ -z "$ENCODED" ]; then
  echo "ERROR: no se pudo codificar el prompt" >&2
  exit 1
fi

# Pollinations cachea en Cloudflare por el texto EXACTO del prompt (Cache-Control: immutable,
# 1 año) -- si esa URL alguna vez devolvio un cuerpo vacio, queda cacheada vacia para siempre y
# cualquier reintento con el mismo prompt falla instantaneo (repro: HTTP 200, 0 bytes, <1s).
# seed random rompe esa clave de cache en cada corrida.
#
# Segundo bug real (investigacion 2026-07-14, github.com/pollinations/pollinations/issues/7207):
# el tier sin API key (el que usa este script) tiene un limite documentado de 1 request cada 15s.
# Al superarlo, Pollinations NO devuelve 429 -- devuelve HTTP 200 con una imagen "placeholder" de
# ~1.3MB con un hash MD5 fijo conocido. Sin este chequeo, ese placeholder se aceptaria como si
# fuera la imagen real pedida. Se detecta por hash y se reintenta una vez respetando el limite
# documentado (15s de espera) antes de rendirse.
POLL_PLACEHOLDER_MD5="2090a5dc21c32952cbf8496339752bd1"

fetch_pollinations() {
  local seed="$1"
  curl -s -m 90 -o "$OUT" -w '%{http_code}' "https://image.pollinations.ai/prompt/$ENCODED?seed=$seed&nologo=true" 2>/dev/null
}

SEED="$RANDOM$RANDOM"
HTTP_STATUS="$(fetch_pollinations "$SEED")"
if [ "$HTTP_STATUS" != "200" ] || [ ! -s "$OUT" ]; then
  echo "ERROR: Pollinations devolvio HTTP $HTTP_STATUS o un archivo vacio (seed=$SEED)" >&2
  rm -f "$OUT"
  exit 1
fi

ACTUAL_MD5="$(md5sum "$OUT" | cut -d' ' -f1)"
if [ "$ACTUAL_MD5" = "$POLL_PLACEHOLDER_MD5" ]; then
  echo "[mentis-image-gen] rate limit de Pollinations (1 req/15s) detectado, esperando y reintentando una vez..." >&2
  sleep 15
  SEED="$RANDOM$RANDOM"
  HTTP_STATUS="$(fetch_pollinations "$SEED")"
  ACTUAL_MD5="$([ -s "$OUT" ] && md5sum "$OUT" | cut -d' ' -f1 || echo "")"
  if [ "$HTTP_STATUS" != "200" ] || [ ! -s "$OUT" ] || [ "$ACTUAL_MD5" = "$POLL_PLACEHOLDER_MD5" ]; then
    echo "ERROR: Pollinations sigue devolviendo el placeholder de rate-limit tras esperar 15s (seed=$SEED) -- probá de nuevo en un minuto." >&2
    rm -f "$OUT"
    exit 1
  fi
fi

printf '%s\n' "$OUT"
exit 0
