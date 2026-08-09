#!/usr/bin/env bash
# Imita el prompt SIN salto de linea y el eco de mentis-chat.sh real, para testear
# mentis-process.js sin depender de la red real ni del script bash real.
while true; do
  printf 'Vos: '
  if ! IFS= read -r MSG; then
    break
  fi
  if [ "$MSG" = "salir" ]; then
    echo "[fake] chau"
    break
  fi
  echo "[fake] log de una herramienta imaginaria"
  printf 'Mentis: eco: %s\n' "$MSG"
done
