#!/usr/bin/env bash
# test-disparadores.sh — frases que Mentis convierte en acción, y el catálogo del cerebro rápido.
#
# Lo que hay que proteger acá es la PRECISIÓN: un disparador que se activa de más le roba el
# mensaje al modelo y hace algo que el usuario no pidió. Es peor que uno que no se activa.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/mentis-disparadores.sh"
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fail=1; fi; }

bash -n "$SCRIPT" && echo "ok: mentis-disparadores.sh parsea sin errores" || { echo "FAIL: sintaxis"; fail=1; }

# Config de prueba propia: no se toca la del usuario ni se abre Spotify en cada corrida.
TMPCONF="$(mktemp)"
MARCA="$(mktemp -u)"
cat > "$TMPCONF" <<EOF
[
  { "nombre": "prueba", "frases": ["momento de probar", "a probar"],
    "accion": "comando", "valor": "touch '$MARCA'", "respuesta": "Listo, probado." }
]
EOF
_probar() { MENTIS_DISPARADORES="$TMPCONF" bash "$SCRIPT" probar "$1" >/dev/null 2>&1 && echo si || echo no; }

echo "== 1. matchea lo que tiene que matchear =="
chk "$(_probar 'momento de probar')" "si" "matchea la frase exacta"
chk "$(_probar 'Momento De Probar')" "si" "no le importan las mayusculas"
chk "$(_probar '¡Momento de probar!')" "si" "no le importan los signos"
chk "$(_probar 'a probar')" "si" "matchea una frase alternativa del mismo disparador"

echo "== 2. NO matchea lo que no debe (lo que importa de verdad) =="
chk "$(_probar 'momento de probar el codigo nuevo que hicimos')" "no" "no atrapa un pedido real que EMPIEZA igual"
chk "$(_probar 'cuando es momento de probar algo?')" "no" "no atrapa una pregunta que contiene la frase"
chk "$(_probar 'probar')" "no" "no matchea por una palabra suelta"
chk "$(_probar '')" "no" "un mensaje vacio no dispara nada"

echo "== 3. correr ejecuta de verdad =="
rm -f "$MARCA"
SALIDA="$(MENTIS_DISPARADORES="$TMPCONF" bash "$SCRIPT" correr 'momento de probar' 2>/dev/null)"
chk "$SALIDA" "Listo, probado." "devuelve la respuesta configurada"
[ -f "$MARCA" ] && echo "ok: la accion se ejecuto de verdad" || { echo "FAIL: no ejecuto la accion"; fail=1; }
rm -f "$MARCA"

echo "== 4. un mensaje que no matchea no ejecuta ni imprime nada =="
SALIDA2="$(MENTIS_DISPARADORES="$TMPCONF" bash "$SCRIPT" correr 'hola que tal' 2>/dev/null)"; RC2=$?
chk "$SALIDA2" "" "no imprime nada cuando no matchea"
[ "$RC2" -ne 0 ] && echo "ok: sale con codigo != 0 para que el chat siga su curso normal" || { echo "FAIL: deberia salir != 0"; fail=1; }
[ ! -f "$MARCA" ] && echo "ok: no ejecuto nada" || { echo "FAIL: ejecuto una accion que no correspondia"; fail=1; }

echo "== 5. config rota o ausente no rompe el chat =="
SALIDA3="$(MENTIS_DISPARADORES="/no/existe/nada.json" bash "$SCRIPT" correr 'momento de probar' 2>/dev/null)"; RC3=$?
[ "$RC3" -ne 0 ] && [ -z "$SALIDA3" ] && echo "ok: sin archivo de config, sale limpio y en silencio" || { echo "FAIL: deberia salir en silencio"; fail=1; }
ROTO="$(mktemp)"; echo "esto no es json" > "$ROTO"
MENTIS_DISPARADORES="$ROTO" bash "$SCRIPT" correr 'momento de probar' >/dev/null 2>&1
[ "$?" -ne 0 ] && echo "ok: con la config rota tampoco explota" || { echo "FAIL: acepto una config invalida"; fail=1; }
rm -f "$ROTO" "$TMPCONF"

echo "== 6. la config real del usuario es valida y sus acciones existen en el script =="
# La ruta va convertida a formato Windows: este python es el nativo y no entiende /c/Users/...
# (ERR-004/006 -- caí en la misma trampa escribiendo el test que la comprueba).
# Antes esto verificaba el disparador de Spotify. Se eliminó por completo el 2026-07-30 (pedido de
# el usuario): abrir la playlist funcionaba pero nunca se pudo hacer que ARRANCARA sola -- tecla
# multimedia, foco+Espacio y el URI ':play' fallaron los tres, y la Web API pide plan Premium.
# En su lugar se comprueba algo más fuerte y que no caduca: que toda acción configurada esté
# realmente implementada. Una config que nombra una acción inexistente falla recién al usarla.
CONF_WIN="$(cygpath -w "$DIR/disparadores.json" 2>/dev/null || echo "$DIR/disparadores.json")"
ACCIONES="$(MD_CONF="$CONF_WIN" python3 -c "
import json,os
d=json.load(open(os.environ['MD_CONF'],encoding='utf-8'))
assert isinstance(d,list) and d, 'vacio'
for x in d:
    assert x.get('frases'), 'un disparador sin frases: %s' % x.get('nombre')
    assert x.get('accion'), 'un disparador sin accion: %s' % x.get('nombre')
print('\n'.join(sorted({x['accion'] for x in d})))
")" || { echo "FAIL: la config real tiene problemas"; fail=1; }
for acc in $ACCIONES; do
  if grep -qE "^ *${acc}\)" "$SCRIPT"; then
    echo "ok: la accion '$acc' que usa la config esta implementada"
  else
    echo "FAIL: la config usa la accion '$acc' y el script no la implementa"; fail=1
  fi
done
grep -q "spotify" "$SCRIPT" "$DIR/disparadores.json" && { echo "FAIL: quedaron restos de Spotify"; fail=1; } || echo "ok: no quedan restos de Spotify"

echo "== 7. esta enganchado en el chat =="
grep -q 'mentis-disparadores.sh' "$DIR/mentis-chat.sh" && echo "ok: mentis-chat.sh consulta los disparadores" || { echo "FAIL: no esta enganchado"; fail=1; }

echo "== 8. cerebro rapido: catalogo ampliado sin robarle mensajes al modelo =="
_tipo() { bash -c "source '$DIR/engine/nv-classify-lib.sh'; read -r T M L C <<< \"\$(nv_classify_msg \"\$1\" 0)\"; printf '%s' \"\$T\"" _ "$1"; }
for frase in "gracias mentis" "dale dale" "excelente" "que descanses" "jajaja" "impecable" "sale"; do
  chk "$(_tipo "$frase")" "trivial" "\"$frase\" va al cerebro rapido"
done
for frase in "gracias, ahora implementame una funcion en python" "dale, explicame como funciona el router" "claro que si, podes escribir un script de bash?"; do
  T="$(_tipo "$frase")"
  if [ "$T" = "trivial" ]; then echo "FAIL: \"$frase\" se fue al cerebro rapido siendo un pedido real"; fail=1
  else echo "ok: \"$frase\" NO va al cerebro rapido (es $T)"; fi
done

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
