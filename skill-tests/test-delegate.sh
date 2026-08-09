#!/usr/bin/env bash
# test-delegate.sh -- tool 'delegate' de nv-agent.sh (consulta secuencial a otro cerebro dentro
# del mismo turno).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "delegate (consulta secuencial a otro cerebro)"

_sk_case "delegar una pregunta de codigo al cerebro 'code' desde un turno 'general'" \
  bash "$TOOLSDIR/nv-agent.sh" -w -d "$ROOT" -m general -i 6 \
  "Delegale al cerebro 'code' (usá la tool delegate) la pregunta 'en Python, cuál es la diferencia entre una lista y una tupla' y pasame su respuesta."
