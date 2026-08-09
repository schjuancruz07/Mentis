#!/usr/bin/env bash
# test-cap-recall.sh -- /recall (busqueda FTS5 en transcripts de sesiones pasadas).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/recall (búsqueda en transcripts de sesiones pasadas)"

_sk_case "buscar un termino real que aparecio en sesiones anteriores (Mentis)" \
  bash "$MENTIS_ENV_DIR/capabilities/recall.sh" "carbohidratos"
