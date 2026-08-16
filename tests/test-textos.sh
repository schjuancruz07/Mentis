#!/usr/bin/env bash
# test-textos.sh -- que los textos que lee el modelo sigan viviendo en archivos, completos.
#
# QUE SE PRUEBA (2026-08-15): el protocolo -- las lineas que le explican al modelo que
# herramientas tiene -- se saco de los strings de bash y se puso en engine/textos/protocolo/*.txt.
# El motivo esta en nv-textos-lib.sh: escritos en bash hay que escapar cada comilla del JSON de
# ejemplo, y al editarlos los backslashes se colapsan (ERR-159: cuatro parches rotos, uno en
# silencio).
#
# EL CASO QUE JUSTIFICA ESTE ARCHIVO. Durante el propio refactor, el indice de capacidades quedo
# VACIO: la funcion partia los pares clave=valor por salto de linea y el indice es multilinea, asi
# que se perdia entero. El protocolo seguia armandose, el motor seguia arrancando y todos los
# tests seguian pasando -- pero el modelo dejaba de saber que existian ocho capacidades suyas.
# Eso es exactamente el modo de falla de ERR-084: no falla, dice que no puede hacer algo que si
# puede. Lo agarro una comparacion byte a byte contra el protocolo anterior. Estos casos son esa
# comparacion, convertida en algo que se puede correr siempre.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTE="$HERE/engine/nv-agent.sh"
LIB="$HERE/engine/nv-textos-lib.sh"
DIR="$HERE/engine/textos"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== los archivos estan =="
# shellcheck source=/dev/null
source "$LIB"

# Todo lo que nv-agent.sh pide tiene que existir. Un texto que falta no rompe nada visible: el
# motor arranca igual y al modelo le falta una ficha.
PEDIDOS="$(grep -oE 'nv_texto [a-z/-]+' "$AGENTE" | awk '{print $2}' | sort -u)"
FALTAN="$(nv_textos_faltantes $PEDIDOS)"
if [ -z "${FALTAN// }" ]; then
  _ok "los $(printf '%s\n' "$PEDIDOS" | wc -l | tr -d ' ') textos que pide el motor existen"
else
  _mal "no falta ningun texto" "faltan: $FALTAN"
fi

# Si aparece un \" en un.txt casi siempre es que alguien volvio a escapar como si fuera bash. El
# archivo se lee TAL CUAL, asi que ese \" llega al modelo y rompe el JSON de ejemplo.
#
# del texto -- muestra comillas ADENTRO de un valor JSON (ej. \"200g\"), que es exactamente como
# el modelo tiene que escribirlas. Se lista por nombre en vez de aflojar la regla: el dia que
# aparezca un archivo nuevo con escapes, este test lo tiene que cantar igual.
ESCAPES_PERMITIDOS=".txt"
CON_ESCAPES=""
for f in $(grep -rl '\\"' "$DIR" 2>/dev/null || true); do
  case " $ESCAPES_PERMITIDOS " in
    *" $(basename "$f") "*) : ;;
    *) CON_ESCAPES="$CON_ESCAPES $(basename "$f")" ;;
  esac
done
if [ -z "${CON_ESCAPES// }" ]; then
  _ok "ningun texto trae escapes de bash (salvo la excepcion declarada: $ESCAPES_PERMITIDOS)"
else
  _mal "sin escapes de bash" "los tienen:$CON_ESCAPES"
fi

# Y ningun.txt puede tener un $ suelto: el archivo NO se expande, asi que un $VAR llegaria
# literal al modelo. Los datos calculados se pasan con {{LLAVES}}.
CON_VARS="$(grep -rlE '\$[A-Za-z_]' "$DIR" 2>/dev/null || true)"
if [ -z "${CON_VARS// }" ]; then
  _ok "ningun texto tiene variables de bash sin resolver"
else
  _mal "sin variables de bash" "las tienen: $(printf '%s' "$CON_VARS" | tr '\n' ' ')"
fi

echo "== la carga =="
T1="$(nv_texto protocolo/base 2>/dev/null)"
case "$T1" in
  *'{"tool":"read"'*) _ok "el texto base llega con el JSON limpio (sin escapar)" ;;
  *) _mal "texto base legible" "no encontre la ficha de read tal cual" ;;
esac

# EL BUG DEL REFACTOR, como caso fijo: un valor MULTILINEA tiene que entrar entero.
MULTI="$(printf 'linea uno\nlinea dos\nlinea tres')"
PRUEBA_DIR="$(mktemp -d)"; mkdir -p "$PRUEBA_DIR/protocolo"
printf 'antes\n{{X}}\ndespues\n' > "$PRUEBA_DIR/protocolo/prueba.txt"
SALIDA="$(MENTIS_TEXTOS_DIR="$PRUEBA_DIR" bash "$LIB" protocolo/prueba "X=$MULTI")"
if [ "$(printf '%s' "$SALIDA" | grep -c 'linea')" = "3" ]; then
  _ok "un valor multilinea entra entero (el bug del indice)"
else
  _mal "valor multilinea" "entraron $(printf '%s' "$SALIDA" | grep -c 'linea') de 3 lineas"
fi
rm -rf "$PRUEBA_DIR"

if nv_texto protocolo/no-existe-esto >/dev/null 2>&1; then
  _mal "un texto que falta devuelve error" "devolvio exito"
else
  _ok "un texto que falta devuelve error y no rompe el turno"
fi

echo "== el protocolo real =="
# Con todo prendido, las ocho capacidades bajo demanda tienen que estar EN EL INDICE. Este es el
# caso que estuvo roto: el protocolo se armaba, el motor arrancaba y el indice venia vacio.
PROTO="$(NVA_SOLO_PROTOCOLO=1 timeout 60 bash "$AGENTE" -w -b -g -K -t -e -D -C -V -s -c -P -a -d "$HERE" -m reason "x" 2>/dev/null)"
for cap in arduino control datos webcam telefono drive; do
  case "$PROTO" in
    *"\"$cap\":"*) _ok "la capacidad '$cap' aparece en el indice" ;;
    *) _mal "capacidad '$cap' en el indice" "no esta -- el modelo no sabe que existe" ;;
  esac
done

# Y las fichas base tienen que seguir enteras, con su JSON bien formado.
for ficha in read search run done write exec browse; do
  case "$PROTO" in
    *"{\"tool\":\"$ficha\""*) _ok "la ficha de '$ficha' esta bien formada" ;;
    *) _mal "ficha de '$ficha'" "no aparece con su JSON correcto" ;;
  esac
done

echo
printf 'test-textos: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
