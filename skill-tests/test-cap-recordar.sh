#!/usr/bin/env bash
# test-cap-recordar.sh -- /recordar (memoria persistente). Round-trip: guardar, listar, olvidar
# -- no deja notas de prueba residuales en la memoria real del usuario.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/recordar (memoria persistente)"

MARCA="skilltestrecordar$(date +%s)"

_sk_case "guardar una nota real" \
  bash "$MENTIS_ENV_DIR/capabilities/recordar.sh" "$MARCA nota de prueba de skill-tests"

_sk_case "listar notas reales" \
  bash "$MENTIS_ENV_DIR/capabilities/recordar.sh" "listar"

LISTADO="$(bash "$MENTIS_ENV_DIR/capabilities/recordar.sh" listar 2>&1)"
SLUG_REAL="$(printf '%s' "$LISTADO" | grep -oi "$MARCA[a-zA-Z0-9-]*" | head -1)"
if [ -n "$SLUG_REAL" ]; then
  echo "  OK: la nota de prueba aparece en el listado real (slug: $SLUG_REAL)."
  _sk_case "olvidar (limpieza real de la nota de prueba)" \
    bash "$MENTIS_ENV_DIR/capabilities/recordar.sh" "olvidar $SLUG_REAL"
else
  echo "  AVISO: no se encontro la nota '$MARCA' en el listado -- revisar salida de arriba, puede necesitar limpieza MANUAL en Mentis/memoria/."
fi
