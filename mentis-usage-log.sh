#!/usr/bin/env bash
# mentis-usage-log.sh -- registra el uso real de una API para el tracking de costo/gasto (pedido
# del usuario, 2026-07-14). Cada generacion exitosa de un script pago (Ideogram/Runway) le pega acá
# una linea; el panel de estadisticas de la app lee este archivo para mostrar el gasto real.
# NVIDIA NIM (ask-nvidia.sh) no registra acá: es gratis (ver comentario en ask-nvidia.sh), no
# genera costo real que trackear.
#
# Uso: mentis-usage-log.sh <provider> <unit> <quantity> <costUsd>
# Nunca falla el script que lo llama (best-effort, no valida de mas): si el logging en si falla,
# no debe tirar abajo la generacion real que ya tuvo exito.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$HERE/usage-ledger.jsonl"
PROVIDER="${1:-}"
UNIT="${2:-}"
QTY="${3:-1}"
COST="${4:-0}"
[ -z "$PROVIDER" ] && exit 0

PROVIDER="$PROVIDER" UNIT="$UNIT" QTY="$QTY" COST="$COST" python3 -c '
import json, os, sys, datetime
try:
    line = json.dumps({
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "provider": os.environ["PROVIDER"],
        "unit": os.environ.get("UNIT", ""),
        "quantity": float(os.environ.get("QTY", "1") or "1"),
        "costUsd": float(os.environ.get("COST", "0") or "0")
    })
    print(line)
except Exception:
    pass
' >> "$LEDGER" 2>/dev/null
exit 0
