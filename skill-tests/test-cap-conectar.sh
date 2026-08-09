#!/usr/bin/env bash
# test-cap-conectar.sh -- /conectar (alta de conector MCP nuevo en mcp-servers.json real). Dar de
# alta un conector de verdad modifica un archivo de configuracion de produccion -- solo se
# automatiza el caso "sin argumentos" (uso, siempre seguro). El alta real de un conector queda
# documentada como verificacion supervisada (mismo criterio que /programar crear, pero acá el
# archivo de config no tiene un "cancelar" tan directo como Task Scheduler).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/conectar (alta de conector MCP)"

_sk_case "uso sin argumentos (siempre seguro)" \
  bash "$MENTIS_ENV_DIR/capabilities/conectar.sh" ""

_sk_skip "alta real de un conector nuevo" \
  "modifica mcp-servers.json real (config de producción) -- se prueba mejor con supervisión directa del usuario eligiendo un paquete npm real para dar de alta, no con un conector descartable inventado por el test."
