#!/usr/bin/env bash
# run-skill-tests.sh -- runner maestro de skill-tests/ (base de tests de calidad y habilidades
# de Mentis, pedido del usuario 2026-07-17 como prerrequisito de la Fase 6). Corre TODOS los scripts
# test-*.sh de esta carpeta contra la Mentis REAL, arma un reporte consolidado en
# SKTEST_REPORT (default /tmp/mentis-skill-tests-report.md). Cada script decide sus propios
# escenarios -- este runner solo orquesta y agrega tiempos.
#
# Uso: bash run-skill-tests.sh [patron-opcional]
#   sin argumentos: corre todos los test-*.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SKTEST_REPORT="${SKTEST_REPORT:-/tmp/mentis-skill-tests-report.md}"

PATRON="${1:-}"

{
  echo "# Reporte de skill-tests de Mentis"
  echo ""
  echo "Corrida: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo ""
} > "$SKTEST_REPORT"

TOTAL=0
FALLIDOS=()
for f in "$HERE"/test-*.sh; do
  name="$(basename "$f")"
  if [ -n "$PATRON" ] && [[ "$name" != *"$PATRON"* ]]; then continue; fi
  TOTAL=$((TOTAL+1))
  t0=$(date +%s)
  echo "=== corriendo $name ==="
  if bash "$f"; then
    rc=0
  else
    rc=$?
    FALLIDOS+=("$name (exit=$rc)")
  fi
  t1=$(date +%s)
  echo "=== $name terminado en $((t1-t0))s (exit=$rc) ==="
  echo ""
done

echo ""
echo "############################################"
echo "TOTAL scripts corridos: $TOTAL"
if [ "${#FALLIDOS[@]}" -gt 0 ]; then
  echo "Scripts con exit != 0 (revisar, no siempre es un bug real -- puede ser un _sk_skip legitimo):"
  printf '  - %s\n' "${FALLIDOS[@]}"
else
  echo "Todos los scripts terminaron con exit 0."
fi
echo "Reporte completo en: $SKTEST_REPORT"
echo "############################################"
