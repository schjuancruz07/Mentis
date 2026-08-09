#!/usr/bin/env bash
# test-cap-aprender.sh -- /aprender (auditoria de memorias, curator.sh, solo lectura).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/aprender (auditoría de memorias, solo lectura)"

_sk_case "reporte real de auditoria" \
  bash "$MENTIS_ENV_DIR/capabilities/aprender.sh"
