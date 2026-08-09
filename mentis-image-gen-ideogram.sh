#!/usr/bin/env bash
# mentis-image-gen-ideogram.sh -- genera una imagen real via Ideogram v3 (API paga, mejor que
# Pollinations para texto/logos/tipografia LEGIBLE dentro de la imagen). Necesita
# IDEOGRAM_API_KEY en.custom-models-secrets.env (Configuración -> Ideogram en la app).
# Uso: mentis-image-gen-ideogram.sh -o <archivo salida> "<prompt>"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IG_OUT=""
while getopts ":o:" opt; do
  case "$opt" in
    o) IG_OUT="$OPTARG" ;;
    *) ;;
  esac
done
shift $((OPTIND-1))
IG_PROMPT="$*"

if [ -z "$IG_OUT" ] || [ -z "${IG_PROMPT// }" ]; then
  echo "ERROR: uso: mentis-image-gen-ideogram.sh -o <salida> \"<prompt>\"" >&2
  exit 1
fi

IG_SECRETS="$HERE/.custom-models-secrets.env"
IG_KEY=""
if [ -f "$IG_SECRETS" ]; then
  IG_KEY="$(grep '^IDEOGRAM_API_KEY=' "$IG_SECRETS" | head -1 | sed 's/^IDEOGRAM_API_KEY=//')"
fi
if [ -z "$IG_KEY" ]; then
  echo "ERROR: no hay IDEOGRAM_API_KEY configurada (Configuración -> Ideogram en la app de Mentis)." >&2
  exit 1
fi

IG_RESP="$(curl -s -m 60 -X POST "https://api.ideogram.ai/v1/ideogram-v3/generate" \
  -H "Api-Key: $IG_KEY" \
  -F "prompt=$IG_PROMPT" \
  -F "rendering_speed=DEFAULT")"

IG_URL="$(printf '%s' "$IG_RESP" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["data"][0]["url"])
except Exception:
    pass
')"

if [ -z "$IG_URL" ]; then
  echo "ERROR: Ideogram no devolvió una imagen. Respuesta: $(printf '%s' "$IG_RESP" | head -c 300)" >&2
  exit 1
fi

if curl -s -m 60 -o "$IG_OUT" "$IG_URL"; then
  echo "OK: imagen generada con Ideogram: $IG_OUT"
  # Tracking de costo real (pedido del usuario, 2026-07-14): $0.06/imagen con rendering_speed=DEFAULT
  # (confirmado contra developer.ideogram.ai/ideogram-api/api-overview, jul-2026).
  bash "$HERE/mentis-usage-log.sh" ideogram image 1 0.06
else
  echo "ERROR: no se pudo descargar la imagen generada por Ideogram." >&2
  exit 1
fi
