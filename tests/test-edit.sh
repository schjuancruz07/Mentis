#!/usr/bin/env bash
# test-edit.sh -- la herramienta 'edit' de nv-agent.sh (agregada 2026-08-02).
#
# POR QUE ESTE TEST EXISTE TAL COMO ESTA:
#   No prueba "que la función exista". Ejercita el DESPACHO REAL de nv-agent.sh sourceando el
#   archivo de producción y llamando a la misma rama del case que corre en un turno de verdad.
#   Es el único modo de detectar el error que ya pasó dos veces en este archivo (ERR-028): que el
#   extractor de Python no reconozca un campo nuevo y la herramienta lo reciba vacío. Por eso el
#   primer bloque prueba el EXTRACTOR, no el efecto.
set -uo pipefail
TE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TE_AGENT="$TE_HERE/../engine/nv-agent.sh"
export PYTHONIOENCODING=utf-8

TE_OK=0; TE_MAL=0
_ok()  { TE_OK=$((TE_OK+1));  echo "  OK   $1"; }
_mal() { TE_MAL=$((TE_MAL+1)); echo "  MAL  $1  ($2)"; }

# --- 1. el extractor reconoce old/new ------------------------------------------------------------
echo "== el protocolo de los dos lados =="
# shellcheck source=/dev/null
source "$TE_AGENT" 2>/dev/null || true
TE_ACT="$(_extract_action '{"tool":"edit","path":"a.txt","old":"hola","new":"chau"}' 2>/dev/null)"
printf '%s' "$TE_ACT" | grep -q "TOOL=edit"  && _ok "reconoce tool=edit"      || _mal "no reconoce tool=edit" "$TE_ACT"
printf '%s' "$TE_ACT" | grep -q "OLD_B64="   && _ok "emite OLD_B64"           || _mal "no emite OLD_B64" "$TE_ACT"
printf '%s' "$TE_ACT" | grep -q "NEW_B64="   && _ok "emite NEW_B64"           || _mal "no emite NEW_B64" "$TE_ACT"
TE_VO="$(printf '%s' "$TE_ACT" | grep '^OLD_B64=' | cut -d= -f2- | base64 -d 2>/dev/null)"
[ "$TE_VO" = "hola" ] && _ok "OLD_B64 decodifica al texto original" || _mal "OLD_B64 decodifica mal" "'$TE_VO'"

# --- 2. el despacho real -------------------------------------------------------------------------
echo "== el despacho real, con archivos de verdad =="
TE_TMP="$(mktemp -d)"
trap 'rm -rf "$TE_TMP"' EXIT

# _foto_antes_de_tocar vive DENTRO del bloque "si me ejecutaron directo" de nv-agent.sh, así que
# al sourcear el archivo no existe. Se define un doble acá a propósito: lo que este test mide es
# la edición, y el punto de retorno ya tiene su propia prueba (tests/test-deshacer.sh, 9/9).
# Sin este doble, el despacho muere con "command not found" y el test no llega a probar nada.
_foto_antes_de_tocar() { :; }

# Estas son las variables que el loop principal deja seteadas antes de llamar al despacho.
_probar_edit() {  # <archivo_rel> <old> <new> -> deja la observación en TE_OBS
  ROOT="$TE_TMP"; OBSMAX=4000; ALLOW_WRITE="${TE_ALLOW_W:-1}"; it=1
  TOOL="edit"
  PATH_B64="$(printf '%s' "$1" | base64 -w0)"
  OLD_B64="$(printf '%s' "$2" | base64 -w0)"
  NEW_B64="$(printf '%s' "$3" | base64 -w0)"
  QUERY_B64=""; CODE_B64=""; CONTENT_B64=""; ANSWER_B64=""
  OBS=""
  _dispatch_tool 1
  TE_OBS="$OBS"
}

printf 'linea uno\nlinea dos\nlinea tres\n' > "$TE_TMP/a.txt"
_probar_edit "a.txt" "linea dos" "LINEA DOS CAMBIADA"
if grep -q "^LINEA DOS CAMBIADA$" "$TE_TMP/a.txt" && grep -q "^linea uno$" "$TE_TMP/a.txt" && grep -q "^linea tres$" "$TE_TMP/a.txt"; then
  _ok "cambia sólo el fragmento pedido y deja el resto intacto"
else
  _mal "no editó bien" "$(cat "$TE_TMP/a.txt" | tr '\n' '|')"
fi
printf '%s' "$TE_OBS" | grep -q "^OK:" && _ok "informa OK" || _mal "no informó OK" "$TE_OBS"

# Ambiguo: el texto aparece dos veces. Adivinar cuál cambiar sería peor que fallar.
printf 'repetido\notra cosa\nrepetido\n' > "$TE_TMP/b.txt"
TE_ANTES="$(cat "$TE_TMP/b.txt")"
_probar_edit "b.txt" "repetido" "cambiado"
if [ "$(cat "$TE_TMP/b.txt")" = "$TE_ANTES" ]; then _ok "no toca nada si el texto es ambiguo"; else _mal "editó un texto ambiguo" "$(cat "$TE_TMP/b.txt" | tr '\n' '|')"; fi
printf '%s' "$TE_OBS" | grep -qi "2 veces" && _ok "dice cuántas veces apareció" || _mal "no explica la ambigüedad" "$TE_OBS"

# Texto que no está: tiene que decirlo, no crear nada ni fallar en silencio.
_probar_edit "a.txt" "esto no esta en ninguna parte" "x"
printf '%s' "$TE_OBS" | grep -qi "no aparece" && _ok "avisa cuando el texto no está" || _mal "no avisa" "$TE_OBS"

# Archivo inexistente: manda a usar write, no lo crea por las dudas.
_probar_edit "no-existe.txt" "a" "b"
[ ! -e "$TE_TMP/no-existe.txt" ] && _ok "no crea el archivo si no existía" || _mal "creó un archivo que no debía" ""
printf '%s' "$TE_OBS" | grep -qi "usá write\|usa write" && _ok "manda a write para crear" || _mal "no orienta a write" "$TE_OBS"

# La jaula: una ruta que se escapa de la raíz tiene que ser rechazada.
_probar_edit "../fuera.txt" "a" "b"
printf '%s' "$TE_OBS" | grep -qi "fuera de la raíz\|fuera de la raiz\|inválida\|invalida" && _ok "la jaula rechaza rutas que escapan" || _mal "la jaula no rechazó" "$TE_OBS"

# Sin -w no se edita nada, igual que write.
printf 'contenido original\n' > "$TE_TMP/c.txt"
TE_ALLOW_W=0 _probar_edit "c.txt" "contenido original" "pisado"
grep -q "^contenido original$" "$TE_TMP/c.txt" && _ok "sin -w no edita" || _mal "editó sin permiso de escritura" ""
unset TE_ALLOW_W

# Caracteres que romperían una expresión regular: el reemplazo tiene que ser literal.
printf 'valor = f(x) + [1,2] * {a}\nfin\n' > "$TE_TMP/d.txt"
_probar_edit "d.txt" 'f(x) + [1,2] * {a}' 'g(y)'
grep -qF "valor = g(y)" "$TE_TMP/d.txt" && _ok "reemplaza literal (paréntesis, corchetes y llaves)" || _mal "rompió con metacaracteres" "$(cat "$TE_TMP/d.txt" | tr '\n' '|')"

# Multilínea: es el caso normal al tocar código.
printf 'def f():\n    return 1\n\ndef g():\n    return 2\n' > "$TE_TMP/e.py"
_probar_edit "e.py" "$(printf 'def f():\n    return 1')" "$(printf 'def f():\n    return 99')"
grep -q "return 99" "$TE_TMP/e.py" && grep -q "return 2" "$TE_TMP/e.py" && _ok "edita un bloque de varias líneas" || _mal "falló el multilínea" "$(cat "$TE_TMP/e.py" | tr '\n' '|')"

# Tildes y ñ: el archivo no se puede corromper al reescribirlo.
printf 'año: mañana viene la señora\n' > "$TE_TMP/f.txt"
_probar_edit "f.txt" "mañana" "pasado mañana"
grep -qF "año: pasado mañana viene la señora" "$TE_TMP/f.txt" && _ok "no rompe UTF-8 (tildes y ñ)" || _mal "corrompió el UTF-8" "$(cat "$TE_TMP/f.txt")"

echo
echo "== RESULTADO: $TE_OK bien, $TE_MAL mal =="
[ "$TE_MAL" -eq 0 ]
