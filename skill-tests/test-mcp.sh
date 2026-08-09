#!/usr/bin/env bash
# test-mcp.sh -- tool 'mcp' de nv-agent.sh (conectores externos vía mcp-bridge). 'call' necesita
# elegir una tool real de un servidor ya autenticado (ej. Google) -- fragil de hardcodear en un
# test generico, así que solo se ejercita 'list' (deterministico, no depende de que Google este
# autenticado hoy) y se documenta la limitacion.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "mcp (conectores externos vía mcp-bridge)"

_sk_case "list: listar herramientas MCP reales disponibles" \
  bash "$TOOLSDIR/nv-agent.sh" -t -d "$ROOT" -m general -i 5 \
  "Listá qué herramientas MCP externas tenés disponibles ahora mismo (usá la tool mcp, accion list) y decime cuántas encontraste."

_sk_skip "call: invocar una herramienta MCP externa real" \
  "requiere un servidor ya autenticado (ej. Google Workspace con OAuth vigente) -- no reproducible de forma determinista en un test automatizado. Verificar a mano si hace falta confirmar un conector puntual."
