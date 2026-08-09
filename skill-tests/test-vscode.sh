#!/usr/bin/env bash
# test-vscode.sh -- tool 'vscode' de nv-agent.sh (abre un archivo/carpeta real en VS Code).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"
echo "contenido de prueba" > "$ROOT/para-vscode.txt"

_sk_section "vscode (abrir archivo real en VS Code)"

_sk_case "abrir un archivo real en VS Code" \
  bash "$TOOLSDIR/nv-agent.sh" -e -d "$ROOT" -m general -i 5 \
  "Abrí el archivo para-vscode.txt en VS Code."

echo "  -- verificacion adicional: proceso Code.exe corriendo?"
tasklist 2>&1 | grep -qi "code.exe" && echo "  Code.exe detectado en procesos." || echo "  AVISO: no se detecto Code.exe (puede tardar en abrir, o VS Code no esta instalado/en PATH)."
