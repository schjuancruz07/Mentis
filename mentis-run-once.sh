#!/usr/bin/env bash
# mentis-run-once.sh — corre UN turno no interactivo de mentis-chat.sh (para tareas programadas
# via Windows Task Scheduler / capability /programar) y avisa al usuario con un popup cuando termina.
#
# Uso: mentis-run-once.sh <envdir> <root> <histfile> <outfile> <tarea...>
# OJO: <envdir> (la carpeta de Mentis) se recibe como argumento explicito en vez de
# autodescubrirse con dirname/BASH_SOURCE -- bajo Task Scheduler, bash.exe no siempre
# resuelve BASH_SOURCE[0] correctamente al ser lanzado directo (sin una shell padre), y
# terminaba resolviendo mal la ruta. El caller (capability /programar) ya conoce esta ruta.
set -uo pipefail
HERE="$1"; ROOT="$2"; HIST="$3"; OUT="$4"; shift 4
TASK="$*"

# Task Scheduler corre con el PATH minimo del sistema (sin Git\bin) -- "bash" a secas no se
# encuentra ahi (mismo bug que ERR-037 en main.js). Resolvemos la ruta completa a mano.
_resolve_bash() {
  local c
  for c in "/c/Program Files/Git/bin/bash.exe" "/c/Program Files/Git/usr/bin/bash.exe" \
           "/c/Program Files (x86)/Git/bin/bash.exe" "/c/Program Files (x86)/Git/usr/bin/bash.exe"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v bash 2>/dev/null || printf 'bash'
}
BASH_BIN="$(_resolve_bash)"

mkdir -p "$(dirname "$OUT")"
{
  printf '%s\nsalir\n' "$TASK" | "$BASH_BIN" "$HERE/mentis-chat.sh" -d "$ROOT" -H "$HIST"
} > "$OUT" 2>&1

RESPUESTA="$(python3 "$HERE/eval/_extract_mentis.py" first < "$OUT" 2>/dev/null || true)"
[ -z "$RESPUESTA" ] && RESPUESTA="(sin respuesta -- revisar $OUT)"
PREVIEW="$(printf '%s' "$RESPUESTA" | head -c 300)"

MRO_TITLE="Mentis -- tarea programada" MRO_BODY="$TASK

$PREVIEW" powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(\$env:MRO_BODY, \$env:MRO_TITLE) | Out-Null
" >/dev/null 2>&1 || true
