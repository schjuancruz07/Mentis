#!/usr/bin/env bash
# Igual que fake-mentis-chat.sh, pero ademas escribe entradas JSONL reales al -H pedido -- el
# real mentis-chat.sh escribe historial via _mc_append_history, este fixture original no lo
# imita (no hacia falta para los tests que ya lo usaban). Se necesita un fixture aparte para
# testear el flujo de tareas programadas (que SI depende de leer el historial persistido).
HISTFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) HISTFILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

append_history() {
  local role="$1" text="$2"
  [ -z "$HISTFILE" ] && return 0
  ROLE="$role" TEXT="$text" python3 -c '
import json, os
print(json.dumps({"role": os.environ["ROLE"], "text": os.environ["TEXT"], "ts": "2026-01-01T00:00:00Z"}))
' >> "$HISTFILE"
}

while true; do
  printf 'Vos: '
  if ! IFS= read -r MSG; then
    break
  fi
  if [ "$MSG" = "salir" ]; then
    echo "[fake] chau"
    break
  fi
  append_history "usuario" "$MSG"
  echo "[fake] log de una herramienta imaginaria"
  RESP="eco: $MSG"
  append_history "mentis" "$RESP"
  printf 'Mentis: %s\n' "$RESP"
done
