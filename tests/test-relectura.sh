#!/usr/bin/env bash
# test-relectura.sh -- que el turno no relea, paso tras paso, los archivos que acaba de escribir.
#
# DE DONDE SALE: del duelo contra Goose (2026-08-15). Mismo cerebro, misma tarea, mismo juez:
# Goose 85 segundos, Mentis 159. Las trazas lo explicaban solas --
#   Goose:  write, write, write, shell, listo.
#   Mentis: write, write, write, write, read, read, done.
# Mentis releia los cuatro archivos que acababa de escribir. Cada relectura es una llamada entera
# al modelo: ahi estaban los 70 segundos de diferencia.
#
# POR QUE NO LO ATRAPABA NADA: el detector de bucles de aciertos mira la MISMA accion repetida, y
# aca cada lectura es de un archivo distinto y ninguna se repite.
#
# LO QUE NO HACE, Y ES DELIBERADO: no bloquea la lectura. Devuelve el contenido igual con un aviso
# adelante. Y si el archivo cambio desde que se escribio, no dice nada -- releer eso es correcto.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el cableado =="
grep -q 'declare -A ESCRITO_HUELLA=()' "$A" && _ok "hay registro de lo que escribio el turno" || _mal "ESCRITO_HUELLA" "sin registro no hay con que comparar"
grep -q 'ESCRITO_HUELLA\["\$REL"\]=' "$A" && _ok "el write guarda la huella del contenido" || _mal "guardar huella" "nunca se marcaria nada"
grep -q 'MENTIS_RELECTURA_OFF' "$A" && _ok "se puede apagar con MENTIS_RELECTURA_OFF=1" || _mal "apagado" "un cambio de comportamiento sin escape"
# La huella tiene que ser del CONTENIDO. Si fuera solo la ruta, un archivo modificado por un
# comando seguiria contando como "ya lo sabes" y el aviso mentiria.
if awk '/¿ESTE MISMO TURNO LO ESCRIBIO/,/^      fi$/' "$A" | grep -q 'cksum'; then
  _ok "se compara la huella actual del archivo, no solo la ruta"
else
  _mal "compara contenido" "un archivo modificado por un comando contaria como 'ya lo sabes'"
fi

echo ""
echo "== la regla, con la huella REAL de cksum =="
huella() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
declare -A ESCRITO=()
ESCRITO["a.txt"]="$(huella 'hola')"

# mismo contenido -> es relectura de lo propio
[ "$(huella 'hola')" = "${ESCRITO["a.txt"]}" ] \
  && _ok "leer lo propio sin cambios: se detecta" \
  || _mal "detecta lo propio" "la huella no coincide consigo misma"
# contenido cambiado (lo toco un comando) -> NO se avisa
[ "$(huella 'hola, cambiado por un comando')" != "${ESCRITO["a.txt"]}" ] \
  && _ok "si el archivo cambio, NO se avisa (releerlo es lo correcto)" \
  || _mal "archivo cambiado" "avisaria sobre contenido que ya no es el suyo"
# archivo que el turno no escribio -> no hay entrada, no hay aviso
[ -z "${ESCRITO["b.txt"]:-}" ] \
  && _ok "un archivo ajeno no dispara nada" \
  || _mal "archivo ajeno" "avisaria sobre algo que nunca escribio"

echo ""
echo "== el caso que rompio el turno en vivo (2026-08-15) =="
# Un 'read' sin path deja $REL vacio. Bajo `set -u`, indexar un array asociativo con subscript
# vacio aborta TODO el turno con "bad array subscript". Paso de verdad: la corrida murio a la
# mitad y el duelo la anoto como 7/11 en 74 segundos -- parecia "mas rapido pero peor", y estaba
# rota. Por eso el guard de "$REL" no vacio va ANTES de tocar el array.
if awk '/¿ESTE MISMO TURNO LO ESCRIBIO/,/^      fi$/' "$A" | grep -q 'n "${REL:-}"'; then
  _ok "se comprueba que la ruta no este vacia ANTES de indexar el array"
else
  _mal "subscript vacio" "un read sin path vuelve a matar el turno entero"
fi
# Y se prueba de verdad: indexar con vacio bajo set -u tiene que ser el error que fue.
# La reproduccion fiel usa una VARIABLE vacia, no comillas vacias literales: con `${X[""]:-}`
# bash no se queja, con `R=""; ${X["$R"]:-}` si. Esa diferencia es la que hizo que el primer
# intento de este test diera verde sobre un bug que estaba vivo.
if bash -c 'set -u; declare -A X=(); R=""; v="${X["$R"]:-}"' 2>&1 | grep -q 'bad array subscript'; then
  _ok "confirmado: indexar con una variable vacia bajo set -u revienta (por eso el guard)"
else
  _mal "reproduce el bug" "este bash no lo reproduce; el guard igual queda puesto"
fi

echo ""
echo "== la guarda REAL, ejecutada =="
BLOQUE="$(mktemp)"
awk '/# YA LO ESCRIBISTE VOS \(2026-08-15/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 10 ]; then
  _mal "se extrae la guarda" "no se encontro en $A"
else
  _ok "la guarda se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"
  correr() { # $1=TOOL $2=RELEE_PROPIO $3=OBS $4=apagado
    ( set +e
      TOOL="$1"; RELEE_PROPIO="$2"; OBS="$3"; MENTIS_RELECTURA_OFF="$4"; REL="a.txt"; it=2
      source "$BLOQUE"
      printf '%s' "${OBS:0:12}" ) 2>/dev/null
  }
  case "$(correr read 1 'hola mundo' 0)" in
    AVISO*) _ok "leyendo lo propio: el aviso va ADELANTE del contenido" ;;
    *)      _mal "avisa" "obtuvo: $(correr read 1 'hola mundo' 0)" ;;
  esac
  case "$(correr read 0 'hola mundo' 0)" in
    hola*) _ok "si no es propio, el contenido sale intacto" ;;
    *)     _mal "no molesta" "obtuvo: $(correr read 0 'hola mundo' 0)" ;;
  esac
  case "$(correr write 1 'OK: archivo' 0)" in
    OK:*) _ok "solo aplica a 'read' (un write no se toca)" ;;
    *)    _mal "solo read" "obtuvo: $(correr write 1 'OK: archivo' 0)" ;;
  esac
  case "$(correr read 1 'ERROR: no existe' 0)" in
    ERROR*) _ok "sobre un error no se agrega nada" ;;
    *)      _mal "errores intactos" "obtuvo: $(correr read 1 'ERROR: no existe' 0)" ;;
  esac
  case "$(correr read 1 'hola mundo' 1)" in
    hola*) _ok "MENTIS_RELECTURA_OFF=1 lo desactiva de verdad" ;;
    *)     _mal "apagado" "obtuvo: $(correr read 1 'hola mundo' 1)" ;;
  esac
fi
rm -f "$BLOQUE"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
