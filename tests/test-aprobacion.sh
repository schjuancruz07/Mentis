#!/usr/bin/env bash
# test-aprobacion.sh — aprobación por acción: el motor pide permiso para UN comando y espera.
#
# Se prueba la función real extraída de nv-agent.sh (no una copia), simulando el lado de la app:
# un proceso aparte que ve el pedido y escribe la respuesta, igual que hace main.js.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTE="$DIR/engine/nv-agent.sh"
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fi; [ "$1" = "$2" ] || fail=1; }

# La función se toma del archivo real: si alguien la cambia, este test la prueba cambiada.
FUENTE="$(sed -n '/^_pedir_aprobacion()/,/^}/p' "$AGENTE")"
[ -n "$FUENTE" ] || { echo "FAIL: no se encontro _pedir_aprobacion en nv-agent.sh"; exit 1; }

_correr() {  # _correr <respuesta_a_escribir|""> <timeout> ; imprime "rc=<n>" y el stderr
  local respuesta="$1" tmo="$2" dir rc
  dir="$(mktemp -d)"
  if [ -n "$respuesta" ]; then
    # El lado "app": espera a que aparezca el pedido y contesta, como hace main.js.
    ( for _ in $(seq 1 80); do
        p="$(ls "$dir"/*.pedido 2>/dev/null | head -1)"
        if [ -n "$p" ]; then printf '%s' "$respuesta" > "${p%.pedido}.respuesta"; exit 0; fi
        sleep 0.1
      done ) &
  fi
  salida="$(MENTIS_APROBACION_DIR="$dir" NV_APROB_TIMEOUT="$tmo" bash -c "
    set -uo pipefail
    $FUENTE
    _pedir_aprobacion 'borrar una carpeta entera' 'rm -rf /tmp/algo'
  " 2>&1)"; rc=$?
  wait 2>/dev/null
  rm -rf "$dir"
  printf 'rc=%s\n%s' "$rc" "$salida"
}

echo "== 1. el usuario aprueba =="
RES="$(_correr si 10)"
chk "$(printf '%s' "$RES" | head -1)" "rc=0" "si el usuario dice que si, la accion se autoriza"
case "$RES" in *"QUE SI"*) echo "ok: queda registrado en el log que lo aprobo";; *) echo "FAIL: no se registro la aprobacion"; fail=1;; esac

echo "== 2. el usuario rechaza =="
RES="$(_correr no 10)"
chk "$(printf '%s' "$RES" | head -1)" "rc=1" "si el usuario dice que no, la accion se rechaza"

echo "== 3. nadie contesta =="
# El caso que importa de verdad: el silencio NO puede valer como permiso.
INICIO="$(date +%s)"
RES="$(_correr "" 2)"
DUR=$(( $(date +%s) - INICIO ))
chk "$(printf '%s' "$RES" | head -1)" "rc=1" "sin respuesta se rechaza (el silencio no es un permiso)"
if [ "$DUR" -ge 2 ] && [ "$DUR" -le 8 ]; then echo "ok: espero el tiempo pedido y despues se rindio ($DUR s)"; else echo "FAIL: el tiempo de espera no se respeto ($DUR s para un timeout de 2)"; fail=1; fi

echo "== 4. sin app no hay a quien preguntar =="
# Sin MENTIS_APROBACION_DIR (motor corriendo desde una consola) rechaza YA, sin esperar.
INICIO="$(date +%s)"
salida="$(bash -c "set -uo pipefail; $FUENTE; unset MENTIS_APROBACION_DIR; _pedir_aprobacion 'x' 'y'" 2>&1)"; rc=$?
DUR=$(( $(date +%s) - INICIO ))
chk "$rc" "1" "sin canal de aprobacion, rechaza"
if [ "$DUR" -le 2 ]; then echo "ok: rechaza al instante en vez de colgarse esperando a nadie"; else echo "FAIL: se quedo esperando $DUR s sin tener a quien preguntar"; fail=1; fi

echo "== 5. el pedido queda escrito para que la app lo lea =="
dir="$(mktemp -d)"
( MENTIS_APROBACION_DIR="$dir" NV_APROB_TIMEOUT=3 bash -c "
    set -uo pipefail
    $FUENTE
    _pedir_aprobacion 'borrar una carpeta' 'rm -rf /tmp/x'
  " >/dev/null 2>&1 ) &
sleep 1
PEDIDO="$(ls "$dir"/*.pedido 2>/dev/null | head -1)"
if [ -n "$PEDIDO" ]; then
  echo "ok: el pedido queda en un archivo que la app puede leer"
  grep -q "rm -rf /tmp/x" "$PEDIDO" && echo "ok: el pedido incluye el comando exacto que se va a ejecutar" || { echo "FAIL: el pedido no dice que comando es"; fail=1; }
  grep -q "borrar una carpeta" "$PEDIDO" && echo "ok: el pedido explica en castellano que se va a hacer" || { echo "FAIL: el pedido no explica la accion"; fail=1; }
else
  echo "FAIL: no se escribio el archivo de pedido"; fail=1
fi
wait 2>/dev/null; rm -rf "$dir"

echo "== 6. el limpiado no deja basura =="
dir="$(mktemp -d)"
MENTIS_APROBACION_DIR="$dir" NV_APROB_TIMEOUT=1 bash -c "set -uo pipefail; $FUENTE; _pedir_aprobacion 'x' 'y'" >/dev/null 2>&1
QUEDAN="$(ls "$dir" 2>/dev/null | wc -l)"
chk "$QUEDAN" "0" "un pedido vencido no queda tirado en la carpeta"
rm -rf "$dir"

echo "== 7. esta cableado donde importa =="
# La función puede estar perfecta y no servir de nada si nadie la llama. El punto donde tiene que
# estar es la rama de la blocklist de 'exec': ahí es donde antes se rechazaba a ciegas.
if grep -q '_blocked_cmd "$CODE".*&&' "$AGENTE" && grep -q '_pedir_aprobacion "ejecutar un comando' "$AGENTE"; then
  echo "ok: la blocklist de exec pide aprobacion en vez de rechazar de una"
else
  echo "FAIL: _pedir_aprobacion no esta cableada a la blocklist de exec"; fail=1
fi
# Y el modo sin frenos (-x) tiene que seguir salteando la pregunta: si ya dijo que si a todo, no
# tiene sentido preguntarle comando por comando.
grep -q 'ALLOW_DANGEROUS:-0}" != "1" \] && MATCH=' "$AGENTE" && echo "ok: con el modo sin frenos activo no se pregunta nada" || { echo "FAIL: se perdio el atajo del modo sin frenos"; fail=1; }

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
