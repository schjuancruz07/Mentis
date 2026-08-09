#!/usr/bin/env bash
# test-kai-vault.sh -- tests del indice semantico de Kai Vault (2026-07-26).
#
# Estos tests existen por un bug concreto: nv-index.sh/nv-search.sh se perdieron el 2026-07-17,
# boveda.sh los siguio llamando, y durante 8 dias todo el sistema reporto "Listo" mientras
# devolvia siempre "no encontre nada". Nadie lo detecto porque no habia una sola prueba que
# comprobara que buscar devuelve algo REAL, ni que un fallo se reporta COMO fallo.
#
# Se usa un corpus de juguete (3 archivos) para que la corrida sea de segundos y no dependa de
# tener Mentis entero indexado. Las llamadas de embeddings son reales (son gratis y rapidas con
# pocos textos): mockearlas dejaria sin probar justo la parte que se rompio.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
_ok()  { echo "  ok   -- $1"; PASS=$((PASS+1)); }
_bad() { echo "  FALLO-- $1"; FAIL=$((FAIL+1)); }

KV_TMP="$(mktemp -d)"
trap 'rm -rf "$KV_TMP"' EXIT
CORPUS="$KV_TMP/corpus"; mkdir -p "$CORPUS"
IDX="$KV_TMP/indice.jsonl"

cat > "$CORPUS/regar-plantas.sh" <<'EOF'
#!/usr/bin/env bash
# Riega las plantas del balcon segun la humedad de la tierra.
# Si llovio en las ultimas 12 horas, no riega.
regar_si_hace_falta() {
  local humedad="$1"
  [ "$humedad" -lt 30 ] && echo "regando"
}
EOF

cat > "$CORPUS/cobrar-facturas.js" <<'EOF'
// Emite las facturas del mes y le manda el recordatorio de pago a cada cliente moroso.
function calcularInteresPorMora(dias, monto) {
  return monto * 0.02 * dias;
}
EOF

cat > "$CORPUS/notas.md" <<'EOF'
# Cumpleanos de la familia
Marta cumple el 4 de marzo. Tomas cumple el 19 de septiembre.
EOF

echo "== 1. indexar =="
OUT="$(bash "$HERE/engine/nv-index.sh" -o "$IDX" "$CORPUS" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && _ok "el indexado termina con exit 0" || _bad "el indexado devolvio $RC: $OUT"
printf '%s' "$OUT" | grep -q '^OK ' && _ok "reporta OK con el resumen" || _bad "no reporto OK: $OUT"
[ -s "$IDX" ] && _ok "se creo el.jsonl de metadatos" || _bad "no hay.jsonl"
[ -s "${IDX%.jsonl}.vecs.npy" ] && _ok "se creo el.npy de vectores" || _bad "no hay.npy"
# El JSONL NO debe traer los vectores: ese era el formato viejo y hacia que cada busqueda
# tardara ~4 s parseando JSON.
grep -q '"vec"' "$IDX" && _bad "el.jsonl todavia guarda vectores (formato viejo, lento)" \
                       || _ok "los vectores no estan en el.jsonl (van al.npy)"

echo "== 2. buscar =="
RES="$(bash "$HERE/engine/nv-search.sh" -k 3 -i "$IDX" --json -- "cuando hay que ponerle agua a las plantas" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && _ok "la busqueda termina con exit 0" || _bad "la busqueda devolvio $RC: $RES"
printf '%s' "$RES" | grep -q "regar-plantas.sh" \
  && _ok "encuentra el archivo correcto por SIGNIFICADO (la consulta no comparte palabras con el codigo)" \
  || _bad "no encontro regar-plantas.sh: $(printf '%s' "$RES" | head -c 200)"

RES2="$(bash "$HERE/engine/nv-search.sh" -k 3 -i "$IDX" --json -- "calcularInteresPorMora" 2>&1)"
printf '%s' "$RES2" | grep -q "cobrar-facturas.js" \
  && _ok "encuentra por nombre EXACTO de funcion (senal lexica del score hibrido)" \
  || _bad "no encontro cobrar-facturas.js buscando el nombre exacto"

echo "== 3. indice incremental =="
OUT2="$(bash "$HERE/engine/nv-index.sh" -o "$IDX" "$CORPUS" 2>&1)"
printf '%s' "$OUT2" | grep -qE 'nuevos=0 ' && _ok "reindexar sin cambios no re-embebe nada" \
                                           || _bad "reindexo de cero pese a no haber cambios: $OUT2"
echo "# linea agregada" >> "$CORPUS/notas.md"
OUT3="$(bash "$HERE/engine/nv-index.sh" -o "$IDX" "$CORPUS" 2>&1)"
NUEVOS="$(printf '%s' "$OUT3" | grep -oE 'nuevos=[0-9]+' | cut -d= -f2)"
REUSADOS="$(printf '%s' "$OUT3" | grep -oE 'reusados=[0-9]+' | cut -d= -f2)"
{ [ "${NUEVOS:-0}" -ge 1 ] && [ "${REUSADOS:-0}" -ge 1 ]; } \
  && _ok "tras cambiar UN archivo solo se re-embebe ese (nuevos=$NUEVOS, reusados=$REUSADOS)" \
  || _bad "el incremental no discrimino (nuevos=$NUEVOS reusados=$REUSADOS)"

echo "== 4. diversidad por archivo =="
# Sin esto, el top-3 se llenaba con fragmentos consecutivos del mismo archivo y tapaba al resto.
DIV="$(bash "$HERE/engine/nv-search.sh" -k 3 -i "$IDX" --json -- "plantas balcon humedad riego agua" 2>/dev/null \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len({x["file"] for x in d}), len(d))')"
set -- $DIV
[ "${1:-0}" = "${2:-0}" ] && _ok "los resultados del top-k son de archivos distintos ($1 archivos / $2 resultados)" \
                          || _bad "hay resultados repetidos del mismo archivo ($1 archivos / $2 resultados)"

echo "== 5. errores REPORTADOS como errores (el bug de fondo) =="
bash "$HERE/engine/nv-search.sh" -k 3 -i "$KV_TMP/no-existe.jsonl" -- "cualquier cosa" >/dev/null 2>&1
[ "$?" -eq 3 ] && _ok "buscar sin indice devuelve exit 3 (no 0 con las manos vacias)" \
               || _bad "buscar sin indice no devolvio 3"

# Indice inconsistente: metadatos y vectores desparejos. Tiene que negarse a responder, no
# devolver resultados emparejados al azar.
cp "$IDX" "$KV_TMP/roto.jsonl"; cp "${IDX%.jsonl}.vecs.npy" "$KV_TMP/roto.vecs.npy"
head -2 "$IDX" > "$KV_TMP/roto.jsonl"
bash "$HERE/engine/nv-search.sh" -k 3 -i "$KV_TMP/roto.jsonl" -- "plantas" >/dev/null 2>&1
[ "$?" -eq 3 ] && _ok "un indice inconsistente se rechaza en vez de devolver datos mezclados" \
               || _bad "acepto un indice con metadatos y vectores desparejos"

echo "== 6. boveda.sh propaga el fallo (no vuelve a decir 'Listo' si fallo) =="
SALIDA_FALSA="$KV_TMP/fake-engine"; mkdir -p "$SALIDA_FALSA"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SALIDA_FALSA/nv-index.sh"
BOV_OUT="$(cd "$KV_TMP" && TOOLSDIR_OVERRIDE=1 bash -c "
  sed 's#TOOLSDIR=.*#TOOLSDIR=\"$SALIDA_FALSA\"#' '$HERE/capabilities/boveda.sh' > '$KV_TMP/boveda-test.sh'
  bash '$KV_TMP/boveda-test.sh' reindexar 2>&1")"; BOV_RC=$?
[ "$BOV_RC" -ne 0 ] && _ok "reindexar con el indexador roto devuelve exit != 0" \
                    || _bad "reindexar devolvio 0 aunque el indexador fallo (la mentira original)"
printf '%s' "$BOV_OUT" | grep -qi "ERROR" && _ok "y lo dice explicitamente" || _bad "no informo el error: $BOV_OUT"
printf '%s' "$BOV_OUT" | grep -qi "Kai Vault ya puede responder" \
  && _bad "TODAVIA dice 'ya puede responder' despues de fallar" \
  || _ok "ya no afirma que funciona cuando fallo"

echo
echo "RESULTADO: $PASS ok, $FAIL fallos."
[ "$FAIL" -eq 0 ]
