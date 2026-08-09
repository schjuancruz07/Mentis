#!/usr/bin/env bash
# test-cwd-servidores.sh -- ERR-106: ningun servidor de larga vida puede quedarse con la carpeta
# desde la que lo llamaron como directorio de trabajo.
#
# POR QUE ESTE TEST Y NO OTRO: en Windows, un proceso que tiene una carpeta abierta como cwd la
# BLOQUEA -- no se puede borrar ni reemplazar. Eso es exactamente lo que rompia el empaquetado de
# la app con EBUSY, y costo un dia entero de trabajo descubrirlo porque el error no nombra al
# culpable. Asi que el test no mira el codigo ni parsea comentarios: reproduce el sintoma real.
#   1. crea una carpeta descartable
#   2. lanza el servidor DESDE ahi (como hace la app)
#   3. intenta borrar la carpeta
# Si se borra, el servidor no la esta reteniendo y el arreglo funciona. Si no se borra, volvimos
# a ERR-106. No hay forma de que este test de verde por accidente.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; FALLA=0

_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }

# Lanza un proceso de larga vida con el MISMO patron que usan los servidores reales y devuelve
# 0 si la carpeta desde la que se lanzo se puede borrar despues.
# $1 = "con-cd" (el arreglo) | "sin-cd" (el bug, para probar que el test detecta de verdad)
_carpeta_liberada() {
  local modo="$1" jaula rc
  jaula="$(mktemp -d)" || return 2
  # Un python que solo duerme: alcanza para retener el cwd, no carga ningun modelo, no come RAM.
  if [ "$modo" = "con-cd" ]; then
    ( cd "${HOME:-/}" 2>/dev/null || cd /
      nohup python3 -c 'import time; time.sleep(25)' >/dev/null 2>&1 & )
  else
    ( cd "$jaula" 2>/dev/null || return 2
      nohup python3 -c 'import time; time.sleep(25)' >/dev/null 2>&1 & )
  fi
  # Darle tiempo a python a arrancar de verdad y tomar el cwd (arrancar cuesta ~475 ms aca).
  sleep 2
  rm -rf "$jaula" 2>/dev/null
  if [ -d "$jaula" ]; then rc=1; else rc=0; fi
  rm -rf "$jaula" 2>/dev/null || true
  return $rc
}

echo "== ERR-106: los servidores no bloquean la carpeta que los lanzo =="

# --- 0. El test se prueba a si mismo -------------------------------------------------------
# Sin esto, un test que siempre da verde (porque en esta maquina borrar nunca falla, por ejemplo)
# pasaria por bueno y no protegeria de nada. Primero confirmamos que el test SABE ver el bug.
echo "-- control: el test detecta el bug cuando el bug esta presente"
if _carpeta_liberada "sin-cd"; then
  _falla "control: se pudo borrar la carpeta con un proceso adentro -- este test no prueba nada en esta maquina"
else
  _ok "control: con el bug presente la carpeta queda bloqueada (el test sirve)"
fi

echo "-- el patron del arreglo libera la carpeta"
if _carpeta_liberada "con-cd"; then
  _ok "patron con cd: la carpeta se borro sin problemas"
else
  _falla "patron con cd: la carpeta quedo bloqueada"
fi

# --- 1. Los tres scripts reales usan el arreglo ---------------------------------------------
# Complemento del test funcional de arriba: que NADIE agregue un cuarto servidor sin el cd.
echo "-- los lanzadores reales llevan el arreglo"

if grep -qE 'cd "\$\{HOME:-/\}"' "$HERE/mentis-transcribe.sh" 2>/dev/null; then
  _ok "mentis-transcribe.sh (servidor STT) sale de la carpeta antes de lanzar"
else
  _falla "mentis-transcribe.sh lanza el servidor STT sin cambiar de carpeta"
fi

if grep -qE 'cd "\$\{HOME:-/\}"' "$HERE/mentis-tts.sh" 2>/dev/null; then
  _ok "mentis-tts.sh (servidor de voz) sale de la carpeta antes de lanzar"
else
  _falla "mentis-tts.sh lanza el servidor de voz sin cambiar de carpeta"
fi

if grep -q 'WorkingDirectory' "$HERE/mentis-telefono.sh" 2>/dev/null; then
  _ok "mentis-telefono.sh (kdeconnectd) pasa -WorkingDirectory"
else
  _falla "mentis-telefono.sh lanza kdeconnectd sin -WorkingDirectory"
fi

if grep -q 'WorkingDirectory' "$HERE/mentis-web.sh" 2>/dev/null; then
  _ok "mentis-web.sh (servidor web) pasa -WorkingDirectory (ya estaba)"
else
  _falla "mentis-web.sh lanza el servidor web sin -WorkingDirectory"
fi

# --- 2. No quedaron lanzadores de larga vida sin arreglar ------------------------------------
# Barrido: cualquier nohup de un servidor del motor tiene que estar precedido por un cd.
echo "-- barrido: ningun servidor nuevo quedo sin arreglar"
SIN_CD=0
while IFS= read -r linea; do
  archivo="${linea%%:*}"; nlinea="${linea#*:}"; nlinea="${nlinea%%:*}"
  # Mirar las 3 lineas previas al nohup buscando el cd de escape.
  desde=$(( nlinea > 3 ? nlinea - 3 : 1 ))
  if ! sed -n "${desde},${nlinea}p" "$archivo" 2>/dev/null | grep -qE 'cd "\$\{HOME:-/\}"|cd /'; then
    _falla "lanzador sin cd de escape: $archivo linea $nlinea"
    SIN_CD=$((SIN_CD+1))
  fi
done < <(grep -rnE 'nohup python3.*engine/nv_.*server\.py' "$HERE"/mentis-*.sh 2>/dev/null)
[ "$SIN_CD" = "0" ] && _ok "todos los lanzadores de servidores del motor tienen el cd de escape"

# --- 3. El empaquetado dice QUIEN lo bloquea, no solo "EBUSY" -------------------------------
# La secuela de ERR-106: aun con los servicios arreglados, si la app esta abierta el empaquetado
# falla con un "EBUSY: resource busy or locked" que no nombra al culpable. Ese mensaje mudo ya
# costo un dia. El chequeo previo tiene que identificarlo y salir con codigo != 0.
echo "-- el empaquetado identifica al que bloquea la carpeta"

if [ -f "$HERE/app/empaquetar.js" ]; then
  # 3a. Camino feliz: carpeta vacia, nadie la retiene -> deja pasar.
  LIMPIA="$(mktemp -d)"
  mkdir -p "$LIMPIA/Mentis-win32-x64"
  SALIDA_OK="$(MENTIS_DIST_DIR="$(cygpath -w "$LIMPIA" 2>/dev/null || printf '%s' "$LIMPIA")" \
                node "$HERE/app/empaquetar.js" --solo-chequeo 2>&1)"; RC_OK=$?
  if [ "$RC_OK" = "0" ] && printf '%s' "$SALIDA_OK" | grep -q "se puede empaquetar"; then
    _ok "carpeta libre: el chequeo deja pasar (exit 0)"
  else
    _falla "carpeta libre: el chequeo bloqueo sin motivo (exit $RC_OK): $SALIDA_OK"
  fi
  rm -rf "$LIMPIA" 2>/dev/null || true

  # 3b. Camino real: si la app esta abierta AHORA, el chequeo tiene que nombrarla y fallar.
  #     Si no esta abierta, no hay nada que detectar y se informa sin dar rojo -- un test no
  #     puede exigir que el usuario tenga la app abierta para pasar.
  if tasklist 2>/dev/null | grep -qi "Mentis.exe"; then
    SALIDA_BLOQ="$(node "$HERE/app/empaquetar.js" --solo-chequeo 2>&1)"; RC_BLOQ=$?
    if [ "$RC_BLOQ" != "0" ] && printf '%s' "$SALIDA_BLOQ" | grep -qi "Mentis.exe"; then
      _ok "app abierta: el chequeo la nombra y sale con codigo $RC_BLOQ (no un EBUSY mudo)"
    else
      _falla "app abierta: el chequeo no la detecto (exit $RC_BLOQ)"
    fi
  else
    echo "  --   -- la app no esta abierta; no hay bloqueo real que detectar en este momento"
  fi
else
  _falla "falta app/empaquetar.js (el chequeo previo del empaquetado)"
fi

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
