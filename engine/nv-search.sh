#!/usr/bin/env bash
# nv-search.sh -- envoltorio del buscador de Kai Vault (repuesto 2026-07-26).
#
# Se repone con la MISMA interfaz que ya usaba capabilities/boveda.sh:
#   nv-search.sh -k <topk> -d <dir_indexado> -- "<consulta>"
# El -d no es la carpeta donde buscar en vivo: es la carpeta que se indexo, y sirve para
# encontrar el archivo de indice que le corresponde (mismo hash que arma nv-index.sh).
#
# Codigos de salida (importan: boveda.sh los usa para no volver a mentir sobre el resultado):
#   0 = hubo resultados      3 = no hay indice todavia
#   4 = fallo la API         5 = el indice es de otro modelo de embeddings
set -uo pipefail

NVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"

case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

NVS_MODELO="${NV_EMB_MODEL:-nvidia/nv-embedqa-e5-v5}"
NVS_TOPK=5
NVS_DIRS=()
NVS_INDICES=()
NVS_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    -k) NVS_TOPK="$2"; shift 2 ;;
    -d) NVS_DIRS+=("$2"); shift 2 ;;
    -i) NVS_INDICES+=("$2"); shift 2 ;;
    -m) NVS_MODELO="$2"; shift 2 ;;
    --json) NVS_JSON="--json"; shift ;;
    --) shift; break ;;
    -*) echo "nv-search.sh: opcion desconocida $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

NVS_CONSULTA="$*"
if [ -z "${NVS_CONSULTA// }" ]; then
  echo "Uso: nv-search.sh [-k N] [-d dir_indexado] [-i indice.jsonl] -- \"consulta\"" >&2
  exit 2
fi

export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$(nv_read_setting NVIDIA_API_KEY)}"
if [ -z "${NVIDIA_API_KEY// }" ]; then
  echo "ERROR: no hay NVIDIA_API_KEY (ni en el entorno ni en settings.json)" >&2
  exit 2
fi

# Cada carpeta indexada se traduce a su archivo de indice con el MISMO hash que usa nv-index.sh.
for d in "${NVS_DIRS[@]:-}"; do
  [ -n "$d" ] || continue
  clave="$(printf '%s|' "$d" "$NVS_MODELO" | md5sum | cut -d' ' -f1)"
  NVS_INDICES+=("$NV_INDEXDIR/$clave.jsonl")
done

if [ "${#NVS_INDICES[@]}" -eq 0 ]; then
  echo "ERROR: no se indico ni -d ni -i" >&2
  exit 2
fi

PY_ARGS=()
for i in "${NVS_INDICES[@]}"; do PY_ARGS+=(-i "$i"); done
PY_ARGS+=(-k "$NVS_TOPK" -m "$NVS_MODELO")
[ -n "$NVS_JSON" ] && PY_ARGS+=("$NVS_JSON")

python3 "$NVDIR/nv_search.py" "${PY_ARGS[@]}" -- "$NVS_CONSULTA"
