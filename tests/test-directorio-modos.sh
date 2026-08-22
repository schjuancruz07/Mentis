#!/usr/bin/env bash
# test-directorio-modos.sh -- el Directorio muestra SOLO lo que el modo actual puede usar.
#
# POR QUE EXISTE (idea 2 del usuario, 2026-08-21): el panel se mostraba u ocultaba entero segun el
# modo, pero su contenido era el mismo en todos. En Study aparecian habilidades y conectores que
# ese modo no puede usar -- tocarlos no hacia nada, o peor, prendia un conector que el turno
# despues rechaza. La app prometiendo algo que el motor no da, que es el error mas repetido de
# este proyecto.
#
# LO QUE ESTE TEST PROTEGE, y es lo que se rompe solo con el tiempo: que la lista salga de
# modos.json y no de una copia escrita a mano en el renderer. Por eso las funciones de filtrado se
# prueban contra los modos REALES, no contra un modo inventado: si alguien le saca la camara a un
# modo en modos.json, este test tiene que enterarse sin que nadie lo edite.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE_WIN="$(cygpath -m "$HERE" 2>/dev/null || printf '%s' "$HERE")"
RENDERER="$HERE/app/renderer/renderer.js"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

[ -f "$RENDERER" ] || { echo "no existe $RENDERER"; exit 1; }

echo "== las funciones de filtrado existen en el renderer =="
for fn in directorioFiltraHabilidad directorioFiltraConector modoDirectorio CONECTOR_BANDERA; do
  if grep -q "$fn" "$RENDERER"; then _ok "'$fn' esta en el renderer"
  else _mal "falta '$fn'" "el Directorio no filtraria nada"; fi
done

# El renderer es un archivo de navegador (usa document, window): no se puede importar desde node.
# Se extraen las dos funciones de filtrado y el mapa, que son codigo puro, y se prueban contra los
# modos de verdad. Extraer y no copiar: una copia del filtro aca adentro probaria la copia.
echo ""
echo "== el filtrado, contra los modos REALES de modos.json =="
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
awk '/^const CONECTOR_BANDERA = \{/,/^\};/' "$RENDERER" > "$SB/filtro.js"
awk '/^function directorioFiltraHabilidad/,/^\}/' "$RENDERER" >> "$SB/filtro.js"
awk '/^function directorioFiltraConector/,/^\}/'  "$RENDERER" >> "$SB/filtro.js"
if [ "$(wc -l < "$SB/filtro.js")" -lt 10 ]; then
  _mal "no se pudo extraer el filtro del renderer" "sin esto, lo de abajo no prueba nada"
  echo "== $ok ok, $fallo fallan =="; exit 1
fi
_ok "el filtro se extrajo del renderer ($(wc -l < "$SB/filtro.js") lineas)"

cat > "$SB/probar.js" <<JS
const store = require('$HERE_WIN/app/lib/modos-store.js');
let modoDirectorio = null;
$(cat "$SB/filtro.js")

const salida = [];
for (const modo of ['mentis', 'code', 'study', 'cowork']) {
  const d = store.datosDelModo('$HERE_WIN', modo);
  modoDirectorio = { capacidades: d.capacidades || [], banderas: d.banderas || [] };
  salida.push([
    modo,
    directorioFiltraConector('local:webcam') ? 'camara-si' : 'camara-no',
    directorioFiltraConector('local:vscode') ? 'vscode-si' : 'vscode-no',
    directorioFiltraHabilidad('/recall') ? 'recall-si' : 'recall-no',
    directorioFiltraConector('api:ideogram') ? 'ideogram-si' : 'ideogram-no',
  ].join(' '));
}
console.log(salida.join('\n'));
JS
RES="$(node "$SB/probar.js" 2>&1)" || { _mal "el filtro no corre" "$RES"; echo "== $ok ok, $fallo fallan =="; exit 1; }
printf '%s\n' "$RES" | sed 's/^/    /'

# La camara es una herramienta INVASIVA: modos.json se la da a Code y Cowork y NO al modo Mentis
# a secas, que es el unico que se le puede prestar a otra persona sin pensarlo.
case "$RES" in
  *"code camara-si"*) _ok "en Code, el conector de camara SE VE" ;;
  *) _mal "en Code no se ve la camara" "Code tiene la bandera -V en modos.json: el Directorio deberia mostrarla" ;;
esac
case "$RES" in
  *"mentis camara-no"*) _ok "en el modo Mentis a secas, la camara NO se ve" ;;
  *) _mal "el modo Mentis muestra la camara" "es el modo que se presta: no tiene -V y no puede ofrecerla" ;;
esac
case "$RES" in
  *"study camara-no"*) _ok "en Study tampoco" ;;
  *) _mal "Study muestra la camara" "Study no tiene la bandera -V" ;;
esac

# Los conectores que NO dependen de una bandera se ven siempre: filtrar de mas dejaria el panel
# vacio y es peor que no filtrar.
case "$RES" in
  *"ideogram-si"*) _ok "un conector sin bandera asociada se ve en todos los modos" ;;
  *) _mal "se filtro un conector que no depende del modo" "el panel quedaria vacio de mas" ;;
esac

# Y las habilidades salen de las capacidades del modo, no de una lista aparte.
case "$RES" in
  *"recall-si"*) _ok "las habilidades del nucleo se ven (recall esta en todos los modos)" ;;
  *) _mal "no se ve /recall" "esta en el nucleo de modos.json: tiene que verse siempre" ;;
esac

echo ""
echo "== la lista sale de modos.json, no de una copia en el renderer =="
# Si alguien escribe la lista de habilidades a mano en el renderer, este test lo tiene que ver.
# Se comprueba que el catalogo se PIDA al backend, no que no exista la variable: `let
# capabilityCatalog = []` es la inicializacion vacia y es correcta -- la primera version de este
# test la marcaba como "lista escrita a mano" y daba un falso positivo sobre codigo que estaba bien.
# Lo que habria que impedir es un array con habilidades adentro, que es lo que se desincroniza.
if grep -q "capabilityCatalog = await window.mentisAPI.listCapabilities()" "$RENDERER"; then
  _ok "el catalogo de habilidades se pide al backend, no esta escrito en el renderer"
else
  _mal "el catalogo ya no viene del backend" "una lista escrita a mano se desincroniza de modos.json"
fi
if grep -qE "capabilityCatalog\s*=\s*\[[^]]" "$RENDERER"; then
  _mal "hay habilidades escritas a mano en el renderer" "se va a desincronizar de modos.json"
else
  _ok "no hay habilidades escritas a mano"
fi
if grep -q "datosDelModo" "$HERE/app/lib/modos-store.js"; then
  _ok "modos-store sigue siendo la fuente (datosDelModo)"
else
  _mal "no esta datosDelModo" "el Directorio se quedaria sin de donde leer el modo"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
