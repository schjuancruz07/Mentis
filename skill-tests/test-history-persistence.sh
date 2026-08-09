#!/usr/bin/env bash
# test-history-persistence.sh -- confirma que un turno real persiste correctamente usuario+mentis
# en el.jsonl (campos role/text/ts, y steps/model del lado de mentis), con historial aislado
# (ver ERR-064 -- SIEMPRE -H a un archivo scratch en estos tests).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
HIST="$HERE/scratch-history-persist.jsonl"
rm -f "$HIST"
mkdir -p "$ROOT"

_sk_section "persistencia de historial (.jsonl por conversación)"

RESP="$(printf 'decime un dato real sobre la luna\nsalir\n' | bash "$MENTIS_ENV_DIR/mentis-chat.sh" -d "$ROOT" -H "$HIST" -i 6 2>&1)"

{
  echo "### turno real, verificacion de campos persistidos"
  echo '```'
  echo "Contenido de $HIST tras el turno:"
  cat "$HIST" 2>&1
  echo '```'
  echo ""
} | tee -a "$SKTEST_REPORT" >/dev/null

# ERR-006: la ruta va como argv[1], NUNCA embebida como literal en el script -- un literal
# embebido no pasa por la conversion automatica de rutas MSYS->Windows que si aplica sobre
# argumentos de linea de comandos, y el python nativo de Windows no entiende /c/Users/...
python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        entries = [json.loads(l) for l in f if l.strip()]
except Exception as e:
    print('FALLO: no se pudo leer/parsear el historial:', e); sys.exit(1)
roles = [e.get('role') for e in entries]
if roles != ['usuario', 'mentis']:
    print('FALLO: se esperaban exactamente 2 entradas [usuario, mentis], se encontraron:', roles); sys.exit(1)
usuario, mentis = entries
faltantes = [k for k in ('role','text','ts') if k not in usuario] + [k for k in ('role','text','ts','model') if k not in mentis]
# 'steps' es opcional en el entry de mentis (_mc_append_history solo lo agrega si hubo pasos
# ademas de 'done' -- un turno que resuelve en un solo paso legitimamente no tiene 'steps').
if faltantes:
    print('FALLO: faltan campos esperados:', faltantes); sys.exit(1)
if not mentis['text'].strip():
    print('FALLO: el texto de mentis quedo vacio'); sys.exit(1)
print('OK: 2 entradas (usuario+mentis), todos los campos esperados presentes, texto no vacio.')
" "$HIST"

rm -f "$HIST"
