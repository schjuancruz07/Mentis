#!/usr/bin/env bash
# mentis-arduino.sh -- PUENTE al despachador nuevo. No agregues nada acá.
#
# El 2026-08-01 este script se reemplazó por mentis-hardware.sh, que cubre lo mismo y además
# FPGA/RISC-V, PlatformIO, MicroPython, la impresora 3D y la simulación sin placa. El objetivo de
# el usuario es construir su propia tecnología, y para eso cuatro verbos sobre arduino-cli se quedaban
# muy cortos.
#
# Este archivo sigue existiendo por una sola razón: puede haber algo que lo llame por el nombre
# viejo (documentación, notas, un script que se me pase). Traduce las acciones de antes a los
# verbos nuevos y avisa por stderr. No hace nada más.
#
#   boards  -> placas        verify  -> verificar
#   upload  -> subir         monitor -> monitor
set -uo pipefail

MA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MA_NUEVO="$MA_HERE/mentis-hardware.sh"

[ -f "$MA_NUEVO" ] || { echo "ERROR: falta mentis-hardware.sh, que es donde vive esto ahora." >&2; exit 1; }

MA_CMD="${1:-}"; shift || true
case "$MA_CMD" in
  boards)  MA_VERBO="placas" ;;
  verify)  MA_VERBO="verificar" ;;
  upload)  MA_VERBO="subir" ;;
  monitor) MA_VERBO="monitor" ;;
  "")      exec bash "$MA_NUEVO" ;;
  *)       MA_VERBO="$MA_CMD" ;;
esac

echo "AVISO: mentis-arduino.sh quedo reemplazado por mentis-hardware.sh (que ademas hace FPGA, RISC-V, PlatformIO y la impresora)." >&2
echo "AVISO: reenviando a:  mentis-hardware.sh $MA_VERBO $*" >&2
exec bash "$MA_NUEVO" "$MA_VERBO" "$@"
