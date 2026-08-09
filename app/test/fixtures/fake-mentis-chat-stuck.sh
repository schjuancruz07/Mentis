#!/usr/bin/env bash
# Ignora "salir" a proposito, para testear el camino de timeout -> forceKill() de
# mentis-process.js (stop() no puede confiar en que el fixture cierre solo).
while true; do
  printf 'Vos: '
  if ! IFS= read -r MSG; then
    break
  fi
  echo "[fake-stuck] ignorando: $MSG"
done
