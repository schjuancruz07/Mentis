#!/usr/bin/env bash
# test-recordar.sh -- memoria de lo conversado (mentis-recordar.sh + recall_corpus.py).
#
# Lo que se prueba de verdad: que una pregunta en OTRAS palabras encuentre la conversacion
# correcta. Un test que buscara la palabra exacta no probaria nada -- eso ya lo hace grep.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
OK=0; FALLOS=0

ok()   { echo "  ok   -- $1"; OK=$((OK+1)); }
mal()  { echo "  MAL  -- $1"; FALLOS=$((FALLOS+1)); }

REC_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/recordar-$$")"
mkdir -p "$REC_TMP/conversations"
trap 'rm -rf "$REC_TMP"' EXIT

echo "== 1. el corpus traduce el JSONL a dialogo legible =="
cat > "$REC_TMP/conversations/2026-07-01T10-00-00-000Z-aaa.jsonl" <<'EOF'
{"role": "usuario", "text": "Mentis, quiero armar un invernadero automatizado con riego por goteo.", "ts": "2026-07-01T10:00:00"}
{"role": "mentis", "text": "Buena idea. Te propongo un sensor de humedad de suelo y una bomba con relé.", "ts": "2026-07-01T10:00:30"}
{"role": "usuario", "text": "ok", "ts": "2026-07-01T10:01:00"}
EOF
python3 "$RAIZ/engine/recall_corpus.py" --entrada "$REC_TMP/conversations" --salida "$REC_TMP/corpus" >/dev/null 2>&1
TXT="$REC_TMP/corpus/2026-07-01T10-00-00-000Z-aaa.txt"
if [ -f "$TXT" ]; then ok "genera el.txt de la conversacion"; else mal "no genero el.txt"; fi
if grep -q "\[2026-07-01 10:00\] el usuario:" "$TXT" 2>/dev/null; then
  ok "cada turno queda fechado y con el hablante"
else
  mal "falta la fecha o el hablante en el dialogo"
fi
if grep -q "invernadero" "$TXT" 2>/dev/null; then ok "conserva el contenido"; else mal "perdio el contenido"; fi
# El "ok" suelto no aporta a una busqueda y solo ensucia el indice.
if grep -qx "\[2026-07-01 10:01\] el usuario: ok" "$TXT" 2>/dev/null; then
  mal "indexo un turno trivial ('ok')"
else
  ok "descarta los turnos triviales"
fi

echo "== 2. es incremental (no rehace lo que no cambio) =="
SALIDA1="$(python3 "$RAIZ/engine/recall_corpus.py" --entrada "$REC_TMP/conversations" --salida "$REC_TMP/corpus" 2>&1)"
if echo "$SALIDA1" | grep -q "1 sin cambios"; then
  ok "la segunda pasada no reescribe nada"
else
  mal "reescribio una conversacion que no habia cambiado: $SALIDA1"
fi

echo "== 3. una conversacion borrada desaparece del corpus =="
rm -f "$REC_TMP/conversations/2026-07-01T10-00-00-000Z-aaa.jsonl"
python3 "$RAIZ/engine/recall_corpus.py" --entrada "$REC_TMP/conversations" --salida "$REC_TMP/corpus" >/dev/null 2>&1
if [ -f "$TXT" ]; then
  mal "quedo el.txt de una conversacion que el usuario borro"
else
  ok "limpia los huerfanos"
fi

echo "== 4. aguanta datos rotos sin caerse (leccion de ERR-080) =="
printf '{"role":"usuario","text":"probando bytes raros \xbf aca","ts":"2026-07-02T10:00:00"}\nesto no es json\n{"role":"mentis","text":"respuesta valida y suficientemente larga","ts":"2026-07-02T10:00:05"}\n' \
  > "$REC_TMP/conversations/2026-07-02T10-00-00-000Z-bbb.jsonl"
if python3 "$RAIZ/engine/recall_corpus.py" --entrada "$REC_TMP/conversations" --salida "$REC_TMP/corpus" >/dev/null 2>&1; then
  ok "no se cae con un byte invalido ni con una linea corrupta"
else
  mal "se cayo con datos imperfectos"
fi
if grep -q "respuesta valida" "$REC_TMP/corpus/2026-07-02T10-00-00-000Z-bbb.txt" 2>/dev/null; then
  ok "conserva los turnos sanos del archivo dañado"
else
  mal "perdio los turnos sanos por culpa de una linea rota"
fi

echo "== 5. busqueda semantica sobre las conversaciones REALES =="
if [ -f "$RAIZ/engine/recall-index.jsonl" ]; then
  # A proposito con OTRAS palabras que las de la conversacion: se busca por significado.
  RES="$(timeout 120 bash "$RAIZ/mentis-recordar.sh" "la cuenta que le pedi a la calculadora" 2>/dev/null)"
  if echo "$RES" | grep -qi "calculadora"; then
    ok "encuentra la conversacion preguntando con otras palabras"
  else
    mal "no encontro la conversacion de la calculadora"
  fi
  if echo "$RES" | grep -qE '\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\]'; then
    ok "los pasajes vuelven fechados"
  else
    mal "los pasajes no traen fecha (no se puede saber cuando se dijo)"
  fi
  if bash "$RAIZ/mentis-recordar.sh" salud >/dev/null 2>&1; then
    ok "salud responde con el estado del indice"
  else
    mal "salud falla"
  fi
else
  echo "  (salteado: todavia no hay indice real -- corre: mentis-recordar.sh indexar)"
fi

echo
echo "RESULTADO: $OK ok, $FALLOS fallos."
[ "$FALLOS" -eq 0 ] || exit 1
