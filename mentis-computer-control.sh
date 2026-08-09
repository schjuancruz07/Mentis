#!/usr/bin/env bash
# mentis-computer-control.sh -- control REAL de mouse/teclado del escritorio, via
# mentis-computer-control.ps1 (User32 + SendKeys). Solo lo llama nv-agent.sh (tool "control",
# opt-in con -c, ver ALLOW_CONTROL). NUNCA se corre a mano contra un click/type real sin que
# el usuario haya confirmado el modo en la UI.
#
# Uso:
#   mentis-computer-control.sh launch "nombre-o-ruta"
#   mentis-computer-control.sh move X Y
#   mentis-computer-control.sh click X Y [left|right|double]
#   mentis-computer-control.sh type "texto"
#   mentis-computer-control.sh key "ctrl+c"
#   mentis-computer-control.sh scroll up|down
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_FILE="$HERE/mentis-computer-control.ps1"
WIN_PS1="$(cygpath -w "$PS1_FILE" 2>/dev/null || printf '%s' "$PS1_FILE")"

ACTION="${1:-}"
case "$ACTION" in
  launch)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action launch -Text "${2:-}"
    ;;
  move)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action move -X "${2:-0}" -Y "${3:-0}"
    ;;
  click)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action click -X "${2:-0}" -Y "${3:-0}" -ClickType "${4:-left}"
    ;;
  type)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action type -Text "${2:-}"
    ;;
  key)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action key -Keys "${2:-}"
    ;;
  scroll)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_PS1" -Action scroll -Text "${2:-down}"
    ;;
  *)
    echo "ERROR: accion desconocida: $ACTION" >&2
    exit 1
    ;;
esac
