#!/usr/bin/env bash
# test-parallel.sh -- tool 'parallel' de nv-agent.sh (varias sub-tareas a distintos cerebros EN
# SIMULTANEO, background+wait real, no secuencial como delegate).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "parallel (sub-tareas simultaneas a distintos cerebros)"

_sk_case "2 sub-tareas en paralelo real (medible por tiempo total)" \
  bash "$TOOLSDIR/nv-agent.sh" -w -d "$ROOT" -m general -i 6 \
  "Usá la tool parallel para mandar EN SIMULTANEO estas dos sub-tareas: 1) al cerebro 'code', qué es un decorator en Python. 2) al cerebro 'reason', por qué el cielo es azul. Pasame las dos respuestas."
