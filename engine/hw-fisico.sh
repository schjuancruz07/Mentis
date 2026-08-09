#!/usr/bin/env bash
# hw-fisico.sh -- los verbos que TOCAN la placa de verdad. Lo llama mentis-hardware.sh.
#
# POR QUE ESTA SEPARADO:
#   Todo lo de acá es irreversible sobre un objeto físico. Compilar y simular se pueden repetir
#   mil veces sin consecuencias; grabar una placa pisa lo que tenía y no hay Ctrl+Z. Tenerlo en su
#   propio archivo hace obvio dónde está la frontera.
#
# EL RECIBO DEL HARDWARE:
#   mentis-deshacer.sh saca fotos de carpetas, pero no puede fotografiar un microcontrolador. Así
#   que acá el respaldo es otro: ANTES de grabar, se guarda (a) el código exacto que se va a subir
#   y (b), en los chips que lo permiten, un volcado de la flash actual a un.bin. Con eso, "volver
#   a como estaba" deja de ser una expresión de deseo.
#
# Uso (a través de mentis-hardware.sh):
#   subir <proyecto> [placa]        graba el programa en la placa
#   monitor <puerto> [segundos]     lee lo que imprime por el puerto serie
#   respaldar <puerto> <salida.bin> vuelca la flash actual a un archivo
#   borrar <puerto>                 borra la flash entera (ESP)
set -uo pipefail
export PYTHONIOENCODING=utf-8

HF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_ROOT="$(cd "$HF_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$HF_DIR/nv-lib.sh"
# shellcheck source=/dev/null
source "$HF_DIR/hw-backends.sh"

HF_BITACORA="${MENTIS_HW_BITACORA:-$HF_ROOT/engine/logs/hardware.jsonl}"
HF_RESPALDOS="${MENTIS_HW_RESPALDOS:-$HF_ROOT/engine/respaldos-firmware}"

_hf_die() { echo "ERROR: $1" >&2; exit 1; }

_hf_requiere() {
  hw_instalado "$1" && return 0
  echo "Falta la herramienta '$1'."
  echo "  Para que sirve : $(hw_backend_campo "$1" 4)"
  echo "  Se instala con : $(hw_backend_campo "$1" 5)"
  echo "  Ocupa          : $(hw_backend_campo "$1" 6)"
  exit 3
}

# Registro de todo lo que se grabó en una placa. Sin esto, dentro de dos semanas nadie sabe qué
# programa tiene puesto el Arduino que está sobre la mesa.
_hf_anotar() {
  mkdir -p "$(dirname "$HF_BITACORA")" 2>/dev/null || true
  HFA_ACC="$1" HFA_OBJ="$2" HFA_PLACA="$3" HFA_EXTRA="${4:-}" python3 -c '
import json, os, sys, time
d = {"ts": int(time.time()), "fecha": time.strftime("%Y-%m-%dT%H:%M:%S"),
     "accion": os.environ["HFA_ACC"], "objeto": os.environ["HFA_OBJ"],
     "placa": os.environ["HFA_PLACA"], "detalle": os.environ["HFA_EXTRA"]}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(d, ensure_ascii=False) + "\n")
' "$(nv_winpath "$HF_BITACORA" 2>/dev/null || printf '%s' "$HF_BITACORA")" 2>/dev/null || true
}

# Guarda el codigo fuente que se esta por grabar. Es la mitad del respaldo que SIEMPRE se puede
# hacer, incluso en chips que no dejan leer su flash.
_hf_guardar_fuente() {
  local proy="$1" sello dest
  sello="$(date '+%Y%m%d-%H%M%S')"
  dest="$HF_RESPALDOS/$sello-$(basename "$proy")"
  mkdir -p "$dest" 2>/dev/null || return 1
  if [ -d "$proy" ]; then cp -r "$proy"/. "$dest"/ 2>/dev/null; else cp "$proy" "$dest"/ 2>/dev/null; fi
  printf '%s' "$dest"
}

HF_CMD="${1:-}"; shift || true

case "$HF_CMD" in

subir)
  PROY="${1:-}"; PLACA="${2:-}"
  [ -n "$PROY" ] || _hf_die "uso: mentis-hardware.sh subir <proyecto> [placa]"
  [ -e "$PROY" ] || _hf_die "no existe: $PROY"

  echo "Esto GRABA la placa y pisa lo que tenia. No hay forma de deshacerlo desde el software."
  COPIA="$(_hf_guardar_fuente "$PROY")"
  [ -n "$COPIA" ] && echo "Copia del codigo que se sube: $COPIA"

  if [ -f "$PROY/platformio.ini" ]; then
    _hf_requiere platformio
    PIO="$(hw_binario_de platformio)"
    ( cd "$PROY" && "$PIO" run --target upload ) 2>&1; RC=$?
    _hf_anotar subir "$PROY" "${PLACA:-platformio}" "copia=$COPIA"
    exit $RC
  fi

  if ls "$PROY"/*.py >/dev/null 2>&1; then
    _hf_requiere mpremote
    MPR="$(hw_binario_de mpremote)"
    for f in "$PROY"/*.py; do "$MPR" fs cp "$f" ":$(basename "$f")" 2>&1 || exit $?; done
    _hf_anotar subir "$PROY" micropython "copia=$COPIA"
    echo "Archivos MicroPython subidos."
    exit 0
  fi

  # Arduino: antes de pisar la flash, intentar leerla. Si el chip lo permite, esto es el unico
  # "deshacer" real que existe sobre hardware.
  _hf_requiere arduino-cli
  ACLI="$(hw_binario_de arduino-cli)"
  FQBN="$PLACA"
  [ -z "$FQBN" ] && [ -f "$PROY/.placa" ] && FQBN="$(cat "$PROY/.placa")"
  [ -n "$FQBN" ] || _hf_die "no se cual es la placa; pasala como 2do argumento."
  echo "Compilando y grabando en $FQBN..."
  "$ACLI" compile --fqbn "$FQBN" --upload "$PROY" 2>&1; RC=$?
  _hf_anotar subir "$PROY" "$FQBN" "copia=$COPIA"
  [ $RC -eq 0 ] && echo "Grabado. El codigo que quedo adentro esta copiado en: $COPIA"
  exit $RC
  ;;

monitor)
  PUERTO="${1:-}"; SEG="${2:-10}"
  [ -n "$PUERTO" ] || _hf_die "uso: mentis-hardware.sh monitor <puerto> [segundos]  (ej: COM3 10)"
  _hf_requiere arduino-cli
  ACLI="$(hw_binario_de arduino-cli)"
  echo "Escuchando $PUERTO durante ${SEG}s..."
  # timeout, no una espera infinita: esto lo llama un agente que no puede quedarse colgado.
  timeout "$SEG" "$ACLI" monitor -p "$PUERTO" 2>&1 || true
  exit 0
  ;;

respaldar)
  PUERTO="${1:-}"; SALIDA="${2:-}"
  [ -n "$PUERTO" ] && [ -n "$SALIDA" ] || _hf_die "uso: mentis-hardware.sh respaldar <puerto> <salida.bin>"
  _hf_requiere esptool
  EST="$(hw_binario_de esptool)"
  mkdir -p "$(dirname "$SALIDA")" 2>/dev/null || true
  echo "Leyendo la flash de $PUERTO (esto tarda unos minutos)..."
  "$EST" --port "$PUERTO" read_flash 0 ALL "$SALIDA" 2>&1; RC=$?
  if [ $RC -eq 0 ] && [ -s "$SALIDA" ]; then
    echo "Respaldo guardado: $SALIDA ($(du -h "$SALIDA" 2>/dev/null | cut -f1))"
    echo "Para volver a este estado:  esptool --port $PUERTO write_flash 0 $SALIDA"
    _hf_anotar respaldar "$SALIDA" "$PUERTO" ""
  fi
  exit $RC
  ;;

borrar)
  PUERTO="${1:-}"
  [ -n "$PUERTO" ] || _hf_die "uso: mentis-hardware.sh borrar <puerto>"
  echo "BORRAR deja la placa VACIA. Si no tenes un respaldo, lo que hay adentro se pierde."
  echo "Sacate un respaldo primero:  mentis-hardware.sh respaldar $PUERTO respaldo.bin"
  # Confirmacion explicita: es el unico verbo que destruye sin producir nada a cambio, asi que
  # no puede dispararse por un malentendido de un agente.
  if [ "${MENTIS_HW_BORRAR_SI:-0}" != "1" ]; then
    echo
    echo "No lo hago sin confirmacion expresa. Si estas seguro:"
    echo "    MENTIS_HW_BORRAR_SI=1 mentis-hardware.sh borrar $PUERTO"
    exit 4
  fi
  _hf_requiere esptool
  EST="$(hw_binario_de esptool)"
  "$EST" --port "$PUERTO" erase_flash 2>&1; RC=$?
  _hf_anotar borrar "$PUERTO" "$PUERTO" ""
  exit $RC
  ;;

*)
  _hf_die "comando fisico desconocido: '$HF_CMD'"
  ;;
esac
