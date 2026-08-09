#!/usr/bin/env bash
# test-cap-boveda.sh -- /boveda, interfaz de usuario del capability (distinto de test-memory-vault.sh,
# que ejercita el motor de Kai Vault mas a fondo como pieza del pipeline de cada turno).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/boveda (interfaz de usuario)"

_sk_case "pregunta real sobre una feature nueva de esta sesion" \
  bash "$MENTIS_ENV_DIR/capabilities/boveda.sh" "que hace el boton de detener una respuesta"
