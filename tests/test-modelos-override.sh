#!/usr/bin/env bash
# test-modelos-override.sh -- la capa de datos que saca la tabla rol->modelo del bash.
#
# QUE SE PRUEBA Y POR QUE:
#   La tabla de modelos vive hardcodeada en el case de ask-nvidia.sh, con las mediciones que
#   justifican cada eleccion al lado. Eso esta bien como default. El problema es que cuando un
#   modelo se MUERE (pasa: ERR-082 con qwen3.5-397b, 410 Gone) cambiarlo exige editar bash.
#   modelos-override.json es la capa que lo convierte en datos.
#
#   La garantia mas importante que se prueba aca es la NEGATIVA: mientras no exista el archivo,
#   nada cambia. Un override mal cableado no puede degradar el camino normal, que es el 99% de
#   las llamadas. Por eso el test compara la resolucion de modelo CON y SIN archivo.
#
#   No se llama al endpoint: esto prueba la RESOLUCION del modelo, no que el modelo responda.
#   Para lo segundo esta mentis-modelos.sh. Mezclarlos haria un test que falla los dias que
#   NVIDIA esta saturada, por algo que no tiene nada que ver.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASK="$HERE/engine/ask-nvidia.sh"
OK=0; FALLA=0
_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }

MO_TMP="$(mktemp -d)"
trap 'rm -rf "$MO_TMP" 2>/dev/null' EXIT
OVR="$MO_TMP/modelos-override.json"

# CACHE PROPIA, OBLIGATORIO (2026-08-04). Este test consulta los roles reales ('reason',
# 'extract') contra overrides de mentira, incluido uno que no existe. Sin aislar el directorio de
# memo, esas respuestas vacias se escribian en el cache de PRODUCCION (/tmp/mentis-memo) bajo la
# misma clave que usa el sistema de verdad, y con fecha mas nueva que el modelos-override.json
# real -- que se invalida por `-nt` y por lo tanto no las vencia nunca.
#
# Consecuencia medida: desde el 2026-08-04 18:48 (este test corre dentro de la rutina de
# mentis-mejorar.sh) 'reason' y 'extract' ignoraron su override y corrieron con el modelo por
# default. El test que prueba que los overrides andan era el que los rompia.
#
# nv-lib.sh ademas mete el archivo fuente en la clave del cache, asi que hoy harian falta las dos
# fallas a la vez para repetirlo. Este aislamiento se queda igual: un test no escribe en el estado
# de produccion, punto.
export NV_CACHE_MEMO="$MO_TMP/memo"

# Resuelve que modelo usaria un rol, SIN llamar al endpoint. Se apoya en el AVISO que imprime
# ask-nvidia.sh por stderr y en la telemetria; para no depender de ninguno de los dos, se usa el
# camino directo: cargar nv-lib.sh y preguntarle al lector del override.
_override_de() {
  NV_OVERRIDE_FILE="$1" bash -c '
    source "'"$HERE"'/engine/nv-lib.sh" 2>/dev/null
    nv_override_rol "'"$2"'"
  ' 2>/dev/null
}

echo "== modelos-override.json: la tabla rol->modelo como datos =="

# --- 1. Sin archivo, cero efecto (la garantia negativa) --------------------------------------
echo "-- sin archivo de override no pasa nada"
SIN="$(_override_de "$MO_TMP/no-existe.json" reason)"
if [ -z "$SIN" ]; then
  _ok "sin archivo: no devuelve override (el rol usa su modelo de tabla)"
else
  _falla "sin archivo devolvio algo: '$SIN'"
fi

# El costo tambien tiene que ser cero: si esto arrancara python igual, serian ~475 ms por llamada.
INICIO="$(date +%s%N 2>/dev/null || echo 0)"
for _ in 1 2 3 4 5; do _override_de "$MO_TMP/no-existe.json" reason >/dev/null; done
FIN="$(date +%s%N 2>/dev/null || echo 0)"
if [ "$INICIO" != "0" ] && [ "$FIN" != "0" ]; then
  MS=$(( (FIN - INICIO) / 1000000 / 5 ))
  # El techo contempla que cada vuelta arranca un bash y hace source de nv-lib.sh; lo que NO
  # puede pasar es que arranque python (eso solo ya son ~475 ms).
  if [ "$MS" -lt 400 ]; then
    _ok "sin archivo cuesta ${MS} ms por llamada (no arranca python)"
  else
    _falla "sin archivo cuesta ${MS} ms por llamada -- parece estar arrancando python al pedo"
  fi
fi

# --- 2. Con archivo, se aplica -----------------------------------------------------------------
echo "-- con archivo de override se aplica"
cat > "$OVR" <<'JSON'
{
  "version": 1,
  "roles": {
    "extract": {
      "modelo": "modelo/nuevo-de-prueba",
      "fallback": "modelo/respaldo-1",
      "fallback2": "modelo/respaldo-2",
      "desde": "2026-08-01T00:00:00",
      "motivo": "prueba automatizada",
      "anterior": { "modelo": "modelo/viejo", "fallback": "x", "fallback2": "y" }
    }
  }
}
JSON
CON="$(_override_de "$OVR" extract)"
if [ "$CON" = "modelo/nuevo-de-prueba|modelo/respaldo-1|modelo/respaldo-2" ]; then
  _ok "con archivo: devuelve modelo y los dos fallbacks en orden"
else
  _falla "con archivo: devolvio '$CON'"
fi

OTRO="$(_override_de "$OVR" reason)"
if [ -z "$OTRO" ]; then
  _ok "un rol sin entrada propia no se ve afectado por el override de otro"
else
  _falla "el rol 'reason' se contagio el override de 'extract': '$OTRO'"
fi

# --- 3. Archivos rotos no pueden dejar a Mentis mudo -------------------------------------------
# Un JSON corrupto (escritura cortada a la mitad, edicion a mano con una coma de mas) NO puede
# tumbar el camino de las llamadas: tiene que degradar a "sin override" y seguir.
echo "-- un override roto degrada a 'sin override', no rompe"
printf '%s' '{"roles": {"extract": {"modelo":' > "$MO_TMP/roto.json"
ROTO="$(_override_de "$MO_TMP/roto.json" extract)"
if [ -z "$ROTO" ]; then
  _ok "JSON cortado a la mitad: devuelve vacio (el rol cae a su modelo de tabla)"
else
  _falla "JSON roto devolvio '$ROTO'"
fi

printf '%s' '{"roles": {"extract": {"fallback": "solo-respaldo"}}}' > "$MO_TMP/sinmodelo.json"
SINM="$(_override_de "$MO_TMP/sinmodelo.json" extract)"
if [ -z "$SINM" ]; then
  _ok "entrada sin 'modelo': se ignora entera (no deja al rol sin a que llamar)"
else
  _falla "entrada sin modelo devolvio '$SINM'"
fi

printf '%s' '{"roles": {"extract": {"modelo": "   "}}}' > "$MO_TMP/vacio.json"
VAC="$(_override_de "$MO_TMP/vacio.json" extract)"
if [ -z "$VAC" ]; then
  _ok "modelo en blanco: se ignora"
else
  _falla "modelo en blanco devolvio '$VAC'"
fi

# --- 3bis. Dos archivos de override NO comparten celda de cache (regresion 2026-08-04) --------
# El bug: la clave del cache era "src.override.<rol>" y no incluia de que archivo salio el dato.
# Como este mismo test consulta 'reason' y 'extract' contra overrides de mentira, dejaba esos
# vacios escritos en el cache real -- y con fecha mas nueva que el modelos-override.json de
# verdad, que se invalida por `-nt`, no vencian NUNCA. Produccion corrio dos roles con el modelo
# por default durante horas mientras el JSON mostraba el override aplicado.
#
# Se prueba el orden que rompia: leer el bueno, ensuciar con dos falsos, y volver a leer el bueno.
echo "-- un override de mentira no puede pisar la celda del real"
# EL ORDEN IMPORTA y es el del bug de verdad: primero se ENSUCIA la celda, despues se lee el
# archivo bueno. Al reves no reproduce nada -- el cache devuelve el valor bueno que ya tenia y el
# test pasa con el bug puesto (comprobado).
#
# El archivo sucio tiene que EXISTIR y no tener el rol: uno inexistente sale antes de tocar el
# cache, asi que no ensucia. Ese fue exactamente el caso real (linea 89: se consulta 'reason'
# contra un override que solo define 'extract').
#
# Y el bueno se crea ANTES que la celda sucia a proposito: la invalidacion es por `-nt`, o sea
# que un archivo mas viejo que el cache envenenado no lo vence nunca. Ahi estaba la permanencia.
printf '%s' '{"roles": {"extract": {"modelo": "modelo-real-de-prueba"}}}' > "$MO_TMP/real.json"
printf '%s' '{"roles": {"otro-rol": {"modelo": "no-es-extract"}}}'        > "$MO_TMP/ajeno.json"
_override_de "$MO_TMP/ajeno.json" extract >/dev/null    # escribe "vacio" para el rol extract
CACHE_2="$(_override_de "$MO_TMP/real.json" extract)"
if [ "$CACHE_2" = "modelo-real-de-prueba||" ]; then
  _ok "el override real sobrevive a una consulta previa contra otro archivo"
else
  _falla "cache contagiada: el archivo bueno devolvio '$CACHE_2' despues de consultar otro archivo"
fi

# El truncado del identificador de archivo en la clave. `${id: -60}` sobre una cadena de menos de
# 60 caracteres devuelve VACIO en bash 5.3 (no la cadena entera, que es lo que uno supondria), y
# con id vacio la clave vuelve a ser la de antes y el bug reaparece intacto.
if grep -q '\${#id} -gt 60' "$HERE/engine/nv-lib.sh"; then
  _ok "el truncado de la clave esta condicionado a la longitud"
else
  _falla "nv-lib.sh trunca la clave sin chequear largo: id queda vacio y las fuentes vuelven a compartir celda"
fi

# --- 3ter. Deshacer devuelve el rol A DONDE ESTABA (regresion 2026-08-06) ---------------------
# 'revertir' borraba la entrada del override y anunciaba "vuelve a <anterior>". Pero borrar la
# entrada devuelve el rol al DEFAULT del case de ask-nvidia.sh, que no tiene por que ser lo que
# habia. Medido en vivo: "revertir" dijo "vuelve a z-ai/glm-5.2" y dejo a con
# deepseek-v4-pro -- 52 s hasta el primer token, el peor de la tabla, en el rol con consecuencia
# medica. El comando de deshacer empeoraba el sistema y decia lo contrario mientras lo hacia.
echo "-- deshacer deja lo que promete"
MO_REV="$MO_TMP/revertir.json"
printf '%s' '{"roles": {}}' > "$MO_REV"
MO_SALIDA="$(NV_OVERRIDE_FILE="$MO_REV" bash "$HERE/mentis-modelos.sh" revertir 2>&1)"
MO_QUEDO="$(NV_OVERRIDE_FILE="$MO_REV" bash -c 'source "'"$HERE"'/engine/nv-lib.sh" 2>/dev/null; nv_override_rol' 2>/dev/null)"
if printf '%s' "$MO_SALIDA" | grep -q "modelo-viejo" && [ "${MO_QUEDO%%|*}" = "modelo-viejo" ]; then
  _ok "revertir restaura la cadena anterior cuando no era el default"
else
  _falla "revertir prometio '$(printf '%s' "$MO_SALIDA" | tr -d '\n' | tail -c 60)' y dejo '${MO_QUEDO:-nada}'"
fi

# --- 4. El cableado en ask-nvidia.sh -----------------------------------------------------------
echo "-- el cableado dentro de ask-nvidia.sh"

if grep -q 'nv_override_rol' "$ASK"; then
  _ok "ask-nvidia.sh consulta el override"
else
  _falla "ask-nvidia.sh no consulta el override"
fi

# La PRIORIDAD es lo que hace que el usuario no pierda el control: lo que eligio a mano tiene que ganar
# sobre lo automatico. Se verifica por posicion en el archivo.
#
# SE BUSCA LA LLAMADA, NO LA PRIMERA MENCION. Antes esto era `grep -n 'nv_override_rol' | head -1`,
# que agarra tambien los COMENTARIOS. El 2026-08-03 se agrego un bloque de codigo entre el
# comentario que nombra la funcion y la llamada de verdad, y el chequeo empezo a fallar sin que
# la proteccion se hubiera roto en absoluto: el test media la posicion de una frase en prosa.
# Un test estructural tiene que anclarse en algo que solo exista en el codigo.
LIN_OVR="$(grep -n 'NVO_LINEA="\$(nv_override_rol' "$ASK" | head -1 | cut -d: -f1)"
LIN_CUSTOM="$(grep -n 'MC_CUSTOM_JSON=' "$ASK" | head -1 | cut -d: -f1)"
if [ -n "$LIN_OVR" ] && [ -n "$LIN_CUSTOM" ] && [ "$LIN_OVR" -lt "$LIN_CUSTOM" ]; then
  _ok "el override automatico va ANTES de customModels (lo elegido a mano gana)"
else
  _falla "orden de prioridad mal: override en linea '$LIN_OVR', customModels en '$LIN_CUSTOM'"
fi

# El override no puede pisar una invocacion con id de modelo suelto: si alguien pidio un modelo
# por nombre, ya dijo exactamente lo que queria.
#
# Se busca la rama del `case` que ENCIERRA la llamada, recorriendo hacia arriba hasta encontrarla,
# en vez de mirar una ventana fija de 12 lineas. La ventana fija se rompia con solo agregar un
# comentario, que es la peor propiedad que puede tener un test: falla cuando nada se rompio, y
# entrena a quien lo lee a ignorarlo.
RAMA=""
if [ -n "$LIN_OVR" ]; then
  for ((i=LIN_OVR; i>LIN_OVR-40 && i>0; i--)); do
    LINEA="$(sed -n "${i}p" "$ASK")"
    case "$LINEA" in
      *')'*) case "$LINEA" in *'code|reason|deep|ultra|general|extract|multimodal|fast)'*) RAMA="$LINEA"; break ;; esac ;;
    esac
    case "$LINEA" in 'case "$ROLE" in'*) break ;; esac
  done
fi
if [ -n "$RAMA" ]; then
  _ok "el override solo aplica a roles con nombre, no a un id de modelo suelto"
else
  _falla "el override podria pisar una llamada hecha con un id de modelo explicito"
fi

# --- 5. Sintaxis -------------------------------------------------------------------------------
for f in "$ASK" "$HERE/engine/nv-lib.sh"; do
  if bash -n "$f" 2>/dev/null; then _ok "sintaxis ok: $(basename "$f")"; else _falla "sintaxis rota: $f"; fi
done

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
