#!/usr/bin/env bash
# mentis-arduino-docs-refresh.sh -- regenera la base de conocimiento de Arduino/hardware que
# usa Kai Vault (pedido del usuario, 2026-07-15: "snapshot estatico, actualizable a mano"). Los
# archivos que toca este script (arduino-cli-reference.md, boards-and-libraries.md) se generan
# SIEMPRE desde el arduino-cli real instalado, no de una copia de internet -- asi quedan
# garantizados exactos a lo que Mentis puede hacer de verdad en esta maquina. La guia de
# troubleshooting (troubleshooting.md) y la de como funciona el conector de Mentis
# (mentis-arduino-connector.md) son estaticas, no las toca este script.
#
# Uso: bash mentis-arduino-docs-refresh.sh
# Corre esto de nuevo cuando instales un core o libreria nueva de Arduino, para que Kai Vault
# sepa de su existencia (el watcher de Kai Vault reindexa solo apenas detecta el cambio en estos
# archivos -- no hace falta correr /boveda reindexar a mano despues).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/knowledge/arduino"
mkdir -p "$OUTDIR"

ARDUINO_CLI="arduino-cli"
if ! command -v "$ARDUINO_CLI" >/dev/null 2>&1; then
  if [ -x "/c/Program Files/Arduino CLI/arduino-cli.exe" ]; then
    ARDUINO_CLI="/c/Program Files/Arduino CLI/arduino-cli.exe"
  else
    echo "ERROR: arduino-cli no encontrado (ni en PATH ni en la ruta default de Windows)." >&2
    exit 1
  fi
fi

echo "Usando: $("$ARDUINO_CLI" version 2>/dev/null)"

# --- arduino-cli-reference.md: comandos reales, generados del --help de este mismo binario ---
REF="$OUTDIR/arduino-cli-reference.md"
{
  echo "# Referencia de comandos de arduino-cli (generado automático, $(date '+%Y-%m-%d'))"
  echo
  echo "Regenerado con \`mentis-arduino-docs-refresh.sh\` a partir del \`arduino-cli\` real"
  echo "instalado en esta máquina — no editar a mano, se pisa en el próximo refresh."
  echo
  echo "## Versión instalada"
  echo '```'
  "$ARDUINO_CLI" version 2>&1
  echo '```'
  echo
  for sub in "" "compile" "upload" "board list" "monitor" "core list" "core install" "lib list" "lib install" "sketch new"; do
    if [ -z "$sub" ]; then
      echo "## \`arduino-cli --help\`"
    else
      echo "## \`arduino-cli $sub --help\`"
    fi
    echo '```'
    # shellcheck disable=SC2086
    "$ARDUINO_CLI" $sub --help 2>&1
    echo '```'
    echo
  done
} > "$REF"
echo "Escrito: $REF"

# --- boards-and-libraries.md: snapshot real de nucleos/placas/librerias instalados ---
BL="$OUTDIR/boards-and-libraries.md"
{
  echo "# Núcleos y librerías de Arduino instalados (generado automático, $(date '+%Y-%m-%d'))"
  echo
  echo "Regenerado con \`mentis-arduino-docs-refresh.sh\` -- refleja lo que hay REALMENTE"
  echo "instalado en esta máquina ahora mismo, no una lista genérica de internet. Si instalás"
  echo "un core o librería nueva, corré este script de nuevo para que Kai Vault se entere."
  echo
  echo "## Núcleos (cores) instalados"
  echo '```'
  "$ARDUINO_CLI" core list 2>&1
  echo '```'
  echo
  echo "## Librerías instaladas"
  echo '```'
  "$ARDUINO_CLI" lib list 2>&1
  echo '```'
  echo
  echo "## Cómo instalar un núcleo o librería nueva"
  echo '```'
  echo "arduino-cli core install <id>      # ej: arduino-cli core install esp32:esp32"
  echo "arduino-cli lib install <nombre>   # ej: arduino-cli lib install Servo"
  echo '```'
} > "$BL"
echo "Escrito: $BL"

echo "Listo. El watcher de Kai Vault va a reindexar solo apenas detecte estos archivos nuevos"
echo "(o corré 'bash $HERE/capabilities/boveda.sh reindexar' para que sea inmediato)."
