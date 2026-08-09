#!/usr/bin/env bash
# test-gen.sh -- tool 'gen' de nv-agent.sh (imagen/3d/doc/video). Pollinations y el generador de
# documentos no necesitan key -- se prueban reales. Ideogram/Runway necesitan key propia del usuario
# (Configuración); se chequea si esta configurada antes de intentar, para no reportar un fallo
# que en realidad es "falta la key", no un bug.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "gen (imagen / 3D / documento / video)"

_sk_case "image: generar una imagen real (Pollinations, sin key)" \
  bash "$TOOLSDIR/nv-agent.sh" -g -d "$ROOT" -m general -i 6 \
  "Generá una imagen de un zorro corriendo en un bosque y decime la ruta completa donde quedó guardada."

_sk_case "doc: generar un documento real (docx, sin key)" \
  bash "$TOOLSDIR/nv-agent.sh" -g -d "$ROOT" -m general -i 6 \
  "Generá un documento Word con el título 'Test de calidad' y un párrafo que diga 'Documento de prueba generado por skill-tests.' y decime la ruta donde quedó."

SECRETS_FILE="$MENTIS_ENV_DIR/.custom-models-secrets.env"
if [ -f "$SECRETS_FILE" ] && grep -q "^IDEOGRAM_API_KEY=" "$SECRETS_FILE" 2>/dev/null; then
  _sk_case "image (ideogram): imagen con texto legible, key configurada" \
    bash "$TOOLSDIR/nv-agent.sh" -g -d "$ROOT" -m general -i 6 \
    "Generá con Ideogram un cartel que diga 'TEST' bien grande y legible, y decime la ruta."
else
  _sk_skip "image (ideogram)" "no hay IDEOGRAM_API_KEY configurada en Configuración -- esperable, no es un bug."
fi
if [ -f "$SECRETS_FILE" ] && grep -q "^RUNWAY_API_KEY=" "$SECRETS_FILE" 2>/dev/null; then
  _sk_case "video (runway): key configurada" \
    bash "$TOOLSDIR/nv-agent.sh" -g -d "$ROOT" -m general -i 8 \
    "Generá un video corto de una ola de mar y decime la ruta."
else
  _sk_skip "video (runway)" "no hay RUNWAY_API_KEY configurada en Configuración -- esperable, no es un bug."
fi
