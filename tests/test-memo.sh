#!/usr/bin/env bash
# test-memo.sh -- la memoria corta de nv-lib.sh (nv_cache_ttl / nv_memo_limpiar), 2026-08-03.
#
# QUE SE PRUEBA Y POR QUE:
#   nv_override_rol y nv_model_health arrancaban un interprete de Python por llamada para leer
#   archivos que casi nunca cambian: 522 ms y 626 ms medidos sobre un saludo de 5.098 ms. La
#   memoria corta los evita.
#
#   Pero un cache mal hecho es peor que ninguno, de dos maneras distintas, y las dos se prueban:
#     1. Que CUESTE mas de lo que ahorra. La primera version usaba date+stat+mkdir por consulta;
#        en MSYS cada proceso son ~76 ms y casi se comio su propio ahorro. Por eso hay un
#        chequeo de que la version cacheada sea MEDIBLEMENTE mas rapida, no solo "que ande".
#     2. Que sirva un dato viejo despues de un cambio. Si revertir un modelo no se siente hasta
#        dentro de 10 minutos, el mecanismo de recuperacion del usuario queda roto.
set -uo pipefail
TM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_ROOT="$(cd "$TM_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TM_OK=0; TM_MAL=0
_ok()  { TM_OK=$((TM_OK+1));  echo "  OK   $1"; }
_mal() { TM_MAL=$((TM_MAL+1)); echo "  MAL  $1  ($2)"; }

TM_TMP="$(mktemp -d)"
case "$TM_TMP" in
  "$TM_ROOT"|"$TM_ROOT"/*) echo "ABORTA: el temporal cae dentro de Mentis" >&2; exit 1 ;;
esac
trap 'rm -rf "$TM_TMP"' EXIT

# El memo se manda a un directorio propio: este test NO puede tocar el cache real de Mentis.
export NV_CACHE_MEMO="$TM_TMP/memo"
# shellcheck source=/dev/null
source "$TM_ROOT/engine/nv-lib.sh" 2>/dev/null || { echo "ABORTA: no pude sourcear nv-lib.sh" >&2; exit 1; }

case "${NV_CACHE_MEMO:-}" in
  "$TM_TMP"/*) : ;;
  *) echo "ABORTA: sourcear piso NV_CACHE_MEMO ('$NV_CACHE_MEMO'); el test tocaria el cache real" >&2; exit 1 ;;
esac

echo "== memoria corta de nv-lib.sh =="

# --- A. lo basico ---------------------------------------------------------------------------------
CUENTA="$TM_TMP/veces.txt"; : > "$CUENTA"
_caro() { echo "x" >> "$CUENTA"; sleep 0.4; echo "resultado-$1"; }

R1="$(nv_cache_ttl prueba 60 _caro uno)"
R2="$(nv_cache_ttl prueba 60 _caro dos)"
[ "$R1" = "resultado-uno" ] && [ "$R2" = "resultado-uno" ] \
  && _ok "A1 la segunda consulta devuelve lo cacheado, no lo recalcula" \
  || _mal "A1 devuelve lo cacheado" "R1='$R1' R2='$R2'"

[ "$(wc -l < "$CUENTA")" = "1" ] \
  && _ok "A2 la funcion cara corrio UNA sola vez" \
  || _mal "A2 corrio una vez" "corrio $(wc -l < "$CUENTA") veces"

# A3: que de verdad sea mas rapido. Un cache que "anda" pero tarda igual no sirve de nada, y es
# el error que tuvo la primera version de esta funcion.
T0=$(date +%s%3N); nv_cache_ttl prueba 60 _caro tres >/dev/null; T1=$(date +%s%3N)
MS=$(( T1 - T0 ))
[ "$MS" -lt 200 ] \
  && _ok "A3 la consulta cacheada tarda ${MS} ms (la real tarda 400+)" \
  || _mal "A3 el cache es mas rapido" "tardo ${MS} ms, no ahorra nada"

# A4: sin procesos externos adentro. Es LA razon de que ahorre; si alguien vuelve a meter un
# `date` o un `stat` ahi adentro, el ahorro desaparece y nadie se entera.
DEF="$(declare -f nv_cache_ttl)"
if echo "$DEF" | grep -qE '\$\((date|stat|mkdir)|`(date|stat)'; then
  _mal "A4 sin procesos externos" "nv_cache_ttl volvio a llamar a date/stat/mkdir"
else
  _ok "A4 nv_cache_ttl no arranca ningun proceso externo"
fi

# --- B. vencimiento --------------------------------------------------------------------------------
: > "$CUENTA"
nv_cache_ttl corto 1 _caro uno >/dev/null
sleep 2
R="$(nv_cache_ttl corto 1 _caro dos)"
[ "$R" = "resultado-dos" ] && [ "$(wc -l < "$CUENTA")" = "2" ] \
  && _ok "B1 vencido el TTL, recalcula" \
  || _mal "B1 vence el TTL" "R='$R' corrio $(wc -l < "$CUENTA") veces"

ls "$NV_CACHE_MEMO"/ttl.corto.* 2>/dev/null | wc -l | grep -q '^1$' \
  && _ok "B2 no se acumulan archivos vencidos (queda uno por clave)" \
  || _mal "B2 no acumula" "hay $(ls "$NV_CACHE_MEMO"/ttl.corto.* 2>/dev/null | wc -l) archivos"

# --- C. claves independientes -----------------------------------------------------------------------
A="$(nv_cache_ttl clave-a 60 echo valor-a)"
B="$(nv_cache_ttl clave-b 60 echo valor-b)"
[ "$A" = "valor-a" ] && [ "$B" = "valor-b" ] \
  && _ok "C1 dos claves distintas no se pisan" \
  || _mal "C1 claves independientes" "A='$A' B='$B'"

# Un modelo trae barras y puntos en el nombre; si eso no se sanea, el cache escribe fuera del
# directorio o directamente falla.
S="$(nv_cache_ttl "salud.$(printf '%s' 'z-ai/glm-5.2' | tr -c 'A-Za-z0-9._-' '_')" 60 echo ok)"
[ "$S" = "ok" ] \
  && _ok "C2 un nombre de modelo con barras y puntos no rompe la clave" \
  || _mal "C2 clave saneada" "'$S'"

# --- D. el fallo que importa: un dato viejo despues de un cambio -------------------------------------
nv_cache_ttl paraborrar 600 echo primero >/dev/null
nv_memo_limpiar
R="$(nv_cache_ttl paraborrar 600 echo segundo)"
[ "$R" = "segundo" ] \
  && _ok "D1 nv_memo_limpiar invalida todo (una reversion se siente YA)" \
  || _mal "D1 nv_memo_limpiar" "todavia devuelve '$R'"

# D2: y que los scripts que escriben el override lo llamen de verdad. Sin esto la funcion existe
# y no la usa nadie, que es la peor de las dos situaciones: parece resuelto y no lo esta.
for archivo in mentis-modelos.sh mentis-modelos-reparar.sh; do
  if grep -q "nv_memo_limpiar" "$TM_ROOT/$archivo"; then
    _ok "D2 $archivo limpia el memo despues de escribir el override"
  else
    _mal "D2 $archivo limpia el memo" "no llama a nv_memo_limpiar"
  fi
done

# --- E. degradar sin romper ---------------------------------------------------------------------
R="$(NV_CACHE_MEMO=/ruta/que/no/se/puede/crear/nunca nv_cache_ttl x 60 echo igual-funciona)"
[ "$R" = "igual-funciona" ] \
  && _ok "E1 si el directorio no se puede crear, ejecuta igual (no rompe el turno)" \
  || _mal "E1 degrada bien" "'$R'"

R="$(nv_cache_ttl fallo 60 false)"; RC=$?
[ "$RC" != "0" ] && [ -z "$R" ] \
  && _ok "E2 si la funcion cara falla, no se cachea el fallo" \
  || _mal "E2 no cachea fallos" "rc=$RC salida='$R'"

echo
echo "== $TM_OK OK, $TM_MAL MAL =="
[ "$TM_MAL" -eq 0 ]
