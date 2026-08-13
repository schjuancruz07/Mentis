# CAPABILITY: /estructura | dibuja en 3D la estructura REAL de una molécula o un cristal, con datos de PubChem y parámetros de red publicados. "/estructura agua", "/estructura calcio", "/estructura cafeina". Es del modo Mentis Science: si no hay dato, lo dice en vez de inventar una forma.
#
# POR QUE EXISTE (2026-08-12): el usuario pidio que Science le muestre en 3D lo que le esta explicando.
# El motor 3D que ya tenia Mentis es TripoSR (imagen -> malla) y para quimica NO sirve: inventa
# una forma parecida a partir de una foto. En el modo que promete no inventar, eso era lo peor
# que se podia hacer -- una masa deforme con cara de molecula, imposible de distinguir de la real
# para quien esta estudiando.
#
# LO QUE SI HACE: baja la geometria medida (PubChem, del NIH) o arma la celda cristalina con
# parametros de red publicados, y guarda las COORDENADAS. El dibujo lo hace el visor de la app.
# Asi lo que se ve son los datos, no el render de otro programa.
#
# UNA DISTINCION QUE IMPORTA Y QUE EL PEDIDO ORIGINAL MEZCLABA: "un mol de calcio" no tiene
# estructura molecular. Un mol es una cantidad (6,022x10^23) y el calcio metalico es una RED
# cristalina, no una molecula. El script elige el camino correcto segun lo que se pida, y por eso
# 'calcio' devuelve una celda FCC y 'agua' una molecula.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SALIDA_DIR="${MENTIS_CREATIONS_DIR:-$HOME/Documents/Mentis}"
QUE="${*:-}"
# Sin esto los acentos salen como "mol�cula": python escribe UTF-8 y la consola de Windows lee
# cp1252. Va exportado para TODOS los python de este script, no solo el principal.
export PYTHONIOENCODING=utf-8

if [ -z "${QUE// }" ]; then
  cat <<'AYUDA'
/estructura -- la estructura 3D real de una molécula o un cristal.

  /estructura agua                 una molécula (geometría medida, de PubChem)
  /estructura cafeina              idem, cualquier compuesto que PubChem tenga en 3D
  /estructura calcio               un metal: celda cristalina FCC con su parámetro de red
  /estructura sal                  cloruro de sodio: las dos subredes

Se abre en el visor de Mentis y se puede girar. Si de algo no hay dato publicado, te lo digo
en vez de dibujarte una forma inventada.
AYUDA
  exit 0
fi

mkdir -p "$SALIDA_DIR" 2>/dev/null

JSON="$(python3 "$HERE/engine/quimica_3d.py" auto "$QUE" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] || [ -z "${JSON// }" ]; then
  # El mensaje de error del script ya explica la causa (no existe el compuesto, no hay conformero
  # 3D, no hay red). Se pasa tal cual: es informacion util, no ruido.
  ERR="$(printf '%s' "$JSON" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('error','no se pudo generar la estructura'))
except Exception: print('no se pudo generar la estructura')" 2>/dev/null)"
  echo "No pude armar la estructura de '$QUE': $ERR"
  exit 1
fi

# Nombre de archivo predecible y sin caracteres raros: lo va a listar la galeria.
SLUG="$(printf '%s' "$QUE" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
[ -z "$SLUG" ] && SLUG="estructura"
DEST="$SALIDA_DIR/$SLUG.mol3d.json"
printf '%s' "$JSON" > "$DEST" || { echo "No pude escribir $DEST"; exit 1; }

# Resumen honesto para el modelo y para el usuario: que se dibujo, con cuantos atomos y DE DONDE salio.
printf '%s' "$JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
clase='molécula' if d.get('clase')=='molecula' else 'estructura cristalina'
print(f\"Listo: {clase} de {d.get('nombre')} -- {len(d['atomos'])} átomos, {len(d['enlaces'])} uniones dibujadas.\")
print(f\"Fuente de la geometría: {d.get('fuente')}\")
if d.get('url'): print(f\"Ficha: {d['url']}\")
if d.get('nota'): print(f\"Ojo: {d['nota']}\")
"
# El marcador ARTIFACT es lo que hace que aparezca el chip en la app y se pueda abrir en el visor.
#
# LA RUTA VA EN FORMATO WINDOWS, NO MSYS. main.js compara la ruta contra MENTIS_CREATIONS_DIR
# ('C:\Users\...\Documents\Mentis') y un '/c/Users/...' no coincide con eso: el chip aparecia y
# al tocarlo respondia "ruta fuera de la carpeta de creaciones". Es la misma familia del ERR-004
# (node no entiende rutas MSYS), esta vez del lado de la comparacion.
DEST_WIN="$(cygpath -w "$DEST" 2>/dev/null || printf '%s' "$DEST")"
echo "[nv-agent] ARTIFACT: $DEST_WIN" >&2
