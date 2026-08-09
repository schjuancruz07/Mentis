#!/usr/bin/env bash
# test-guards.sh -- guardias defensivas de mentis-chat.sh. Reproduce el caso REAL que reportó
# el usuario (ERR-067, respuesta vacía por clasificación errónea) de punta a punta contra el pipeline
# real, con historial aislado (aprendiendo de ERR-064: NUNCA correr esto sin -H). La guardia
# anti-leak (ERR-061) no se re-testea acá con un mock (ya se verificó en su momento con un
# nv-verify.sh fake, documentado en la bitácora) -- reproducir un eco real del modelo no es
# determinístico a demanda.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
HIST="$HERE/scratch-history-guards.jsonl"
rm -f "$HIST"
mkdir -p "$ROOT"

_sk_section "guardias de mentis-chat.sh"

MSG_REAL='Contexto: Tengo una empresa que se llama "SCh" que hace automatizaciones en n8n. Tengo un contacto que visite una vez y hablamos un poco de sus problemas de perdida de informacion y le ofreci una automatizacion. Tengo una pagina web (schflows.com) que si quieres revisala. Esta persona se llama Mario (pasame la propuesta aca por el chat).'

{
  echo "### ERR-067 regresion: mensaje real del usuario que antes daba respuesta vacia"
  echo '```'
  echo "ENTRADA: $MSG_REAL"
} | tee -a "$SKTEST_REPORT" >/dev/null

RESP="$(printf '%s\nsalir\n' "$MSG_REAL" | bash "$MENTIS_ENV_DIR/mentis-chat.sh" -d "$ROOT" -H "$HIST" -i 8 2>&1)"
{
  echo "SALIDA (ultimas 15 lineas):"
  printf '%s\n' "$RESP" | tail -15
  echo '```'
  echo ""
} | tee -a "$SKTEST_REPORT" >/dev/null

# chequeo automatico: la entrada "mentis" en el historial NO puede quedar vacia.
# ERR-006: la ruta va como argv[1], NUNCA embebida como literal en el script.
MENTIS_TEXT_LEN="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        lines = [json.loads(l) for l in f if l.strip()]
    mentis = [l for l in lines if l.get('role') == 'mentis']
    print(len((mentis[-1].get('text') or '')) if mentis else -1)
except Exception as e:
    print(-2)
" "$HIST")"
if [ "$MENTIS_TEXT_LEN" -gt 0 ] 2>/dev/null; then
  echo "  OK: la respuesta final tiene $MENTIS_TEXT_LEN caracteres (no vacia)."
else
  echo "  FALLO: la respuesta final quedo vacia o no se pudo leer el historial (len=$MENTIS_TEXT_LEN) -- ERR-067 podria haber regresado."
fi

rm -f "$HIST"
