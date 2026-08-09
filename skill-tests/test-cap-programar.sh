#!/usr/bin/env bash
# test-cap-programar.sh -- /programar (Windows Task Scheduler real). Round-trip completo y
# limpio: crea una tarea real que dispara en 1 minuto, confirma que aparece listada, y la
# cancela ANTES de que llegue a dispararse -- no deja residuo real en el Task Scheduler del usuario.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/programar (Windows Task Scheduler real)"

NOMBRE_TAREA="skilltest-$(date +%s)"

_sk_case "crear una tarea real (dispara en 1 minuto)" \
  bash "$MENTIS_ENV_DIR/capabilities/programar.sh" "en 1 m tarea de prueba $NOMBRE_TAREA"

_sk_case "listar tareas reales programadas" \
  bash "$MENTIS_ENV_DIR/capabilities/programar.sh" "listar"

LISTADO="$(bash "$MENTIS_ENV_DIR/capabilities/programar.sh" listar 2>&1)"
if printf '%s' "$LISTADO" | grep -qi "$NOMBRE_TAREA"; then
  echo "  OK: la tarea creada aparece en el listado real."
  # cancelar -- necesita el nombre EXACTO tal como quedo registrado; se busca en el listado.
  NOMBRE_REAL="$(printf '%s' "$LISTADO" | grep -oi "[a-zA-Z0-9-]*$NOMBRE_TAREA[a-zA-Z0-9-]*" | head -1)"
  _sk_case "cancelar la tarea de prueba (limpieza real)" \
    bash "$MENTIS_ENV_DIR/capabilities/programar.sh" "cancelar $NOMBRE_REAL"
else
  echo "  AVISO: no se encontro la tarea '$NOMBRE_TAREA' en el listado -- revisar salida de arriba, puede necesitar limpieza MANUAL en Task Scheduler."
fi
