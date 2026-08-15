#!/usr/bin/env bash
# test-interfaz-2026-08-10.sh -- los arreglos de interfaz que pidio el usuario el 2026-08-10.
#
# Son cinco cosas chicas y una grande, y todas comparten un riesgo: son de INTERFAZ, asi que un
# test puede verificar que el codigo existe y no que se vea bien. Lo que se prueba aca es lo que
# si se puede probar sin ojos -- que los elementos existan, que esten cableados, que el estado se
# refleje en el boton y que nada quedo escrito a mano donde deberia salir de una declaracion.
# Lo otro (que se vea bien) lo mira el usuario, y para eso hay capturas.
#
# LO QUE MAS IMPORTA DE ACA: que los botones de la app sigan al modo. Antes el modo Cowork decia
# "tareas" en su descripcion y el boton de tareas programadas se veia igual en Code -- la
# descripcion prometia una cosa y la interfaz mostraba otra.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$HERE/app/renderer/index.html"
C="$HERE/app/renderer/style.css"
R="$HERE/app/renderer/renderer.js"
M="$HERE/app/main.js"
P="$HERE/app/preload.js"
LIB="$HERE/engine/nv-modos-lib.sh"
A="$HERE/app/renderer/assets"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== 1. mostrar/ocultar la lista de chats =="
grep -q 'id="btn-sidebar"' "$H" \
  && _ok "el boton existe y esta en el header" \
  || _mal "boton de la barra lateral" "sin el, la lista de chats no se puede esconder"
grep -q '#app.sin-sidebar #sidebar' "$C" \
  && _ok "hay una regla que la esconde" \
  || _mal "regla CSS" "el boton no haria nada"
# width:0 y no display:none: display:none saca el elemento del layout y al volver el scroll de la
# lista se va arriba de todo, perdiendo donde estabas leyendo.
grep -A 3 '#app.sin-sidebar #sidebar' "$C" | grep -q 'width: 0' \
  && _ok "se esconde con ancho cero (conserva el scroll de la lista)" \
  || _mal "como se esconde" "con display:none, al volver la lista pierde donde estabas"
grep -q '#app.sin-sidebar #btn-sidebar.relleno' "$C" \
  && _ok "el icono muestra en que estado esta, no solo que hace" \
  || _mal "el boton refleja el estado" "un boton igual en los dos estados obliga a mirar la pantalla para saber que va a pasar"
grep -q "mentis:sidebar-oculta" "$R" \
  && _ok "la preferencia se recuerda entre arranques" \
  || _mal "se guarda la eleccion" "habria que esconderla de nuevo cada vez que abris Mentis"

echo "== 2. previsualizador a pantalla completa =="
grep -q 'id="btn-status-full"' "$H" \
  && _ok "el boton existe" \
  || _mal "boton de pantalla completa" "el pedido era justamente ese"
grep -q 'icono-agrandar' "$H" && grep -q 'icono-achicar' "$H" \
  && _ok "tiene los dos iconos (flechitas para afuera y para adentro)" \
  || _mal "los dos iconos" "sin cambiar el icono, el boton no dice si vas a agrandar o achicar"
# 2026-08-15: el panel tiene dos tamanos con nombres nuevos -- 'columna' (el normal, alto y a la
# derecha, que no tapa) y 'completa' (cubre todo). Se verifican los dos.
grep -q '#status-panel.columna' "$C" \
  && _ok "hay estilo del tamano normal (columna alta)" \
  || _mal "estilo columna" "el panel volveria al cuadradito de 340px"
grep -q '#status-panel.completa' "$C" \
  && _ok "hay estilo de pantalla completa" \
  || _mal "estilo" "el boton no haria nada"
grep -q "e.key === 'Escape' && panel.classList.contains('completa')" "$R" \
  && _ok "se sale con Escape" \
  || _mal "salida con Escape" "en una vista que ocupa todo, el boton no siempre es obvio"

echo "== 3. los botones de la app siguen al modo =="
for m in mentis code designe cowork; do
  p="$(bash "$LIB" paneles "$m")"
  [ -n "${p// }" ] \
    && _ok "el modo '$m' declara sus paneles ($p)" \
    || _mal "paneles de '$m'" "sin declaracion, la interfaz muestra todo en todos los modos"
done
# El Directorio es donde se prenden los conectores y las capacidades: es administracion. El modo
# chat es el unico que se le presta a otra persona, y entregarselo con el panel que enciende la
# camara seria lo contrario de lo que ese modo promete.
bash "$LIB" paneles mentis | grep -q directory \
  && _mal "el modo Mentis muestra el Directorio" "es el panel que enciende camara, pantalla y control: no va en el modo prestable" \
  || _ok "el modo Mentis NO muestra el Directorio"
for m in code designe cowork; do
  bash "$LIB" paneles "$m" | grep -q directory \
    && _ok "el modo '$m' si muestra el Directorio (conectores)" \
    || _mal "'$m' sin Directorio" "no podria prender un conector"
done
grep -q "const PANELES = { projects:" "$R" \
  && _ok "el renderer esconde los botones segun el modo" \
  || _mal "el renderer aplica los paneles" "la declaracion existiria y no haria nada"
grep -q "paneles: unicos(" "$HERE/app/lib/modos-store.js" \
  && _ok "y los paneles salen de modos.json, no de un if escrito a mano" \
  || _mal "una sola fuente" "un dia la app y el motor dirian cosas distintas del mismo modo"

echo "== 4. Mentis Code puede usar conectores =="
bash "$LIB" sin-tools code | grep -q '\bmcp\b' \
  && _mal "Code tiene mcp apagado" "no podria usar conectores externos" \
  || _ok "Code tiene la herramienta de conectores (mcp) prendida"
bash "$LIB" banderas code | grep -q '\-t' \
  && _ok "y la bandera que la habilita (-t)" \
  || _mal "bandera -t en Code" "la herramienta estaria declarada y apagada"

echo "== 5. el consumo de las APIs se ve en Configuracion =="
grep -q 'id="settings-consumo"' "$H" \
  && _ok "hay un apartado en Configuracion" \
  || _mal "apartado de consumo" "el dato existia y solo se veia en la pantalla de bienvenida"
grep -q "pintarConsumoEnAjustes" "$R" \
  && _ok "se llena al abrir Configuracion" \
  || _mal "se llena" "el apartado quedaria vacio"
# Se recalcula al abrir y no al arrancar: si no, muestra lo que valia cuando abriste la app.
grep -A 3 "btn-open-settings').addEventListener" "$R" | grep -q "pintarConsumoEnAjustes()" \
  && _ok "se recalcula cada vez que se abre (no muestra un numero viejo)" \
  || _mal "se recalcula" "diria la cifra de cuando arrancaste la app"

echo "== 6. el tema decide que logo se ve =="
for f in mentis-app.ico mentis-app-oscuro.ico mentis-app-16.png mentis-app-oscuro-16.png; do
  [ -s "$A/$f" ] \
    && _ok "existe $f" \
    || _mal "falta $A/$f" "sin las dos variantes no hay logo por tema"
done
grep -q "'logo'" "$HERE/app/renderer/temas.js" || grep -q "logo:" "$HERE/app/renderer/temas.js" \
  && _ok "cada tema declara su logo" \
  || _mal "el tema declara logo" "habria que adivinarlo desde el codigo"
grep -q "mentis:set-logo" "$M" \
  && _ok "el proceso principal puede cambiar el icono de la ventana y la bandeja" \
  || _mal "IPC del logo" "el icono de la ventana no es CSS: solo lo puede cambiar el proceso principal"
grep -q "setLogo" "$P" \
  && _ok "y el renderer tiene como avisarle" \
  || _mal "puente en preload" "el renderer no podria pedir el cambio"
# El de la bandeja sale de un PNG de 16 y no del.ico multi-resolucion: Windows elige mal el
# tamano cuando se le da un.ico para la bandeja (fix del 2026-07-15).
grep -q 'mentis-app\${suf}-16.png' "$M" \
  && _ok "la bandeja usa el PNG de 16 (no el.ico, que Windows resuelve mal)" \
  || _mal "icono de bandeja" "con el.ico multi-resolucion Windows elige el tamano equivocado"

echo
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
