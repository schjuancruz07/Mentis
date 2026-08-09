#!/usr/bin/env bash
# bench-datasets.sh -- envoltorio de bench_datasets.py que resuelve la API key.
#
# Existe sólo para no duplicar la lógica de dónde vive la key (env o settings.json): la resuelve
# nv_read_setting, que ya es la fuente de verdad de todo el resto del ecosistema.
#
# Uso: bench-datasets.sh humaneval -o salida.jsonl -n 50 -m mod1,mod2
set -uo pipefail
BD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$BD_HERE/../engine/nv-lib.sh"
export PYTHONIOENCODING=utf-8
if [ -z "${NVIDIA_API_KEY:-}" ] && [ -f "$HOME/.claude/settings.json" ]; then
  NVIDIA_API_KEY="$(nv_read_setting NVIDIA_API_KEY)"
  export NVIDIA_API_KEY
fi
[ -n "${NVIDIA_API_KEY:-}" ] || { echo "Sin NVIDIA_API_KEY." >&2; exit 1; }
exec python3 "$BD_HERE/bench_datasets.py" "$@"
