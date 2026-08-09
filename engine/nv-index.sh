#!/usr/bin/env bash
# nv-index.sh -- envoltorio del indexador de Kai Vault (repuesto 2026-07-26).
#
# Este script existia antes del decomisionado del ecosistema `nv` (2026-07-17) y se perdio,
# pero capabilities/boveda.sh nunca dejo de llamarlo: por eso Kai Vault paso 8 dias diciendo
# "Listo" mientras fallaba. Se repone con la MISMA interfaz que esperaba boveda.sh
# (`nv-index.sh [-x "ext ext"] <dir>`) para no tener que reescribir a los llamadores.
#
# La logica real vive en nv_index.py (chunking, lotes, indice incremental); aca solo se resuelve
# el entorno: la key, el modelo y donde va el archivo del indice.
#
# Uso:
#   nv-index.sh [-m modelo] [-x "md txt"] [-o salida.jsonl] [--completo] <dir> [dir2...]
set -uo pipefail

NVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"

# Mismo blindaje que mentis-backup.sh: si esto lo dispara el watcher de Electron o una tarea
# programada, el PATH puede venir sin /usr/bin y no existirian ni `date` ni `find`.
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

NVI_MODELO="${NV_EMB_MODEL:-nvidia/nv-embedqa-e5-v5}"
NVI_EXT=""
NVI_SALIDA=""
NVI_COMPLETO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) NVI_MODELO="$2"; shift 2 ;;
    -x) NVI_EXT="$2"; shift 2 ;;
    -o) NVI_SALIDA="$2"; shift 2 ;;
    --completo) NVI_COMPLETO="--completo"; shift ;;
    --) shift; break ;;
    -*) echo "nv-index.sh: opcion desconocida $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "Uso: nv-index.sh [-m modelo] [-x \"ext ext\"] [-o salida] [--completo] <dir> [dir2...]" >&2
  exit 2
fi

export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$(nv_read_setting NVIDIA_API_KEY)}"
if [ -z "${NVIDIA_API_KEY// }" ]; then
  echo "ERROR: no hay NVIDIA_API_KEY (ni en el entorno ni en settings.json)" >&2
  exit 2
fi

# El nombre del indice sale del hash de las rutas indexadas: asi cada conjunto de carpetas tiene
# su propio archivo y no se pisan entre si (es el mismo criterio del indice viejo).
if [ -z "$NVI_SALIDA" ]; then
  NVI_CLAVE="$(printf '%s|' "$@" "$NVI_MODELO" | md5sum | cut -d' ' -f1)"
  NVI_SALIDA="$NV_INDEXDIR/$NVI_CLAVE.jsonl"
fi
mkdir -p "$(dirname "$NVI_SALIDA")" 2>/dev/null

# Lock: el watcher de la app puede disparar dos reindexados casi juntos y quedarian dos procesos
# escribiendo el mismo archivo. mkdir es atomico en Windows y en POSIX, asi que sirve de lock
# sin depender de flock (que en MSYS no siempre esta).
NVI_LOCK="$NVI_SALIDA.lock"
if ! mkdir "$NVI_LOCK" 2>/dev/null; then
  # Un lock de mas de 30 min es de un proceso que murio sin limpiar.
  if [ -n "$(find "$NVI_LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$NVI_LOCK" 2>/dev/null
    mkdir "$NVI_LOCK" 2>/dev/null || { echo "ERROR: no se pudo tomar el lock del indice" >&2; exit 3; }
  else
    echo "AVISO: ya hay un indexado en curso sobre $NVI_SALIDA, no se arranca otro" >&2
    exit 0
  fi
fi
trap 'rm -rf "$NVI_LOCK" 2>/dev/null' EXIT

PY_ARGS=(-o "$NVI_SALIDA" -m "$NVI_MODELO")
[ -n "$NVI_EXT" ] && PY_ARGS+=(-x "$NVI_EXT")
[ -n "$NVI_COMPLETO" ] && PY_ARGS+=("$NVI_COMPLETO")

# ERR-006: las rutas van como argumentos reales, NUNCA interpoladas dentro del codigo Python.
python3 "$NVDIR/nv_index.py" "${PY_ARGS[@]}" "$@"
