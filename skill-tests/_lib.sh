#!/usr/bin/env bash
# _lib.sh -- helper compartido de skill-tests/. Formato de reporte comun a todos los scripts de
# esta carpeta (uno por tool/capability de Mentis, pedido del usuario 2026-07-17 como base de tests
# antes de arrancar Fase 6). Estos scripts SOLO corren escenarios reales y capturan la salida --
# NO deciden pass/fail. El juicio (con criterio de Fable 5) lo hace Claude Code por afuera,
# leyendo el reporte que arma esto.
set -uo pipefail

SKTEST_REPORT="${SKTEST_REPORT:-/tmp/mentis-skill-tests-report.md}"

# Bug de metodologia real (2026-07-17): llamar a nv-agent.sh DIRECTO (sin pasar por
# mentis-chat.sh) deja MENTIS_SETTINGS_FILE sin exportar -- _connector_enabled() en nv-agent.sh
# sin importar el estado real en Directorio -> Conectores. Esto hizo que varios tests reportaran
# "conector desactivado" como si fuera un fallo real cuando en realidad era este gap. Exportado
# acá (compartido por _lib.sh) para que TODOS los scripts de skill-tests reflejen el estado real.
export MENTIS_SETTINGS_FILE="${MENTIS_SETTINGS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mentis-settings.json}"

# _sk_section <titulo> -- encabezado de una tool/capability nueva en el reporte.
_sk_section() {
  { echo ""; echo "## $1"; echo ""; } | tee -a "$SKTEST_REPORT"
}

# _sk_case <descripcion> <comando...> -- corre el comando, vuelca CASO/ENTRADA/SALIDA/EXIT.
# El comando se ejecuta con "$@" (no eval, para no reintroducir problemas de quoting).
_sk_case() {
  local desc="$1"; shift
  local out rc
  {
    echo "### $desc"
    echo '```'
    echo "ENTRADA: $*"
  } | tee -a "$SKTEST_REPORT" >/dev/null
  out="$("$@" 2>&1)"; rc=$?
  {
    echo "SALIDA (exit=$rc):"
    printf '%s\n' "$out" | head -c 3000
    echo ""
    echo '```'
    echo ""
  } | tee -a "$SKTEST_REPORT" >/dev/null
  echo "  [$desc] exit=$rc"
}

# _sk_skip <descripcion> <motivo> -- para casos que no se pueden correr en este entorno
# (falta hardware/key/servidor externo) -- se documenta el motivo en vez de fallar en silencio.
_sk_skip() {
  {
    echo "### $1"
    echo "_SALTEADO: $2_"
    echo ""
  } | tee -a "$SKTEST_REPORT" >/dev/null
  echo "  [$1] SALTEADO: $2"
}
