#!/usr/bin/env bash
# test-verificador.sh -- el paso de verificacion por ensemble de mentis-chat.sh (2026-08-03).
#
# QUE PROTEGE:
#   El ensemble (3 modelos + juez) bloqueaba el turno SIN TECHO despues de que el agente ya tenia
#   la respuesta escrita. Medido: 26,8 / 138,4 / 198,9 segundos, sobre turnos de ~37 s. Ahora
#   arranca APAGADO y se prende con MENTIS_VERIFY_ESPERA=<segundos>, que ademas es su techo.
#
#   Estos chequeos son estructurales y no gastan una sola llamada. Es a proposito: lo que puede
#   romperse aca no es el resultado de un modelo, es que alguien vuelva a poner un `wait` pelado
#   o cambie el default sin darse cuenta. Eso se ve leyendo el codigo, y se ve GRATIS -- asi que
#   este test puede correr siempre, que es la unica forma de que sirva de red.
#
#   La pregunta de si el ensemble MEJORA la respuesta no se contesta aca: se contesta con
#   tests/comparar-verificador.sh, que corre los dos caminos y los deja lado a lado para leerlos.
set -uo pipefail
TV_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TV_ROOT="$(cd "$TV_HERE/.." && pwd)"
CHAT="$TV_ROOT/mentis-chat.sh"

TV_OK=0; TV_MAL=0
_ok()  { TV_OK=$((TV_OK+1));  echo "  OK   $1"; }
_mal() { TV_MAL=$((TV_MAL+1)); echo "  MAL  $1  ($2)"; }

[ -f "$CHAT" ] || { echo "ABORTA: no existe $CHAT" >&2; exit 1; }

echo "== el paso de verificacion =="

# 1. Apagado por defecto. Es LA decision: 12 s por turno a cambio de algo sin evidencia.
if grep -q 'MC_VERIFY_ESPERA_MAX="${MENTIS_VERIFY_ESPERA:-0}"' "$CHAT"; then
  _ok "1 arranca apagado por defecto (MENTIS_VERIFY_ESPERA=0)"
else
  _mal "1 apagado por defecto" "el default ya no es 0: $(grep -o 'MENTIS_VERIFY_ESPERA:-[0-9]*' "$CHAT" | head -1)"
fi

# 2. UNA sola asignacion del presupuesto. Bug real cometido el 2026-08-03: quedaron dos, con
#    defaults distintos (0 arriba, 10 abajo) -- la de arriba decidia si lanzarlo y la de abajo
#    cuanto esperarlo, asi que "apagado" y "esperando" podian no coincidir.
N_ASIG="$(grep -c 'MC_VERIFY_ESPERA_MAX="\${MENTIS_VERIFY_ESPERA' "$CHAT")"
if [ "$N_ASIG" = "1" ]; then
  _ok "2 el presupuesto se asigna en un solo lugar"
else
  _mal "2 una sola asignacion" "hay $N_ASIG asignaciones con defaults posiblemente distintos"
fi

# 3. Con el presupuesto en 0 no se lanza nada. Esperar 0 segundos igual costaria tres llamadas.
if grep -q 'if \[ "\$MC_VERIFY_ESPERA_MAX" = "0" \]; then' "$CHAT"; then
  _ok "3 con presupuesto 0 ni se lanza (no gasta las 3 llamadas del ensemble)"
else
  _mal "3 con 0 no se lanza" "no aparece la guarda antes de lanzar nv-verify.sh"
fi

# 4. NUNCA MAS UN `wait` PELADO. Es el defecto original: un turno bloqueado sin techo.
if grep -nE '^\s*wait "\$MC_VERIFY_PID"\s*$' "$CHAT" >/dev/null; then
  _mal "4 sin espera sin techo" "volvio el 'wait \$MC_VERIFY_PID' sin timeout"
else
  _ok "4 no hay ningun 'wait' sin techo sobre el verificador"
fi

# 5. La espera tiene tope real y da de baja al que no llego (si no, sigue gastando cuota por una
#    respuesta que ya nadie va a mirar).
if grep -q 'kill "\$MC_VERIFY_PID"' "$CHAT"; then
  _ok "5 al vencer el presupuesto, da de baja al verificador"
else
  _mal "5 da de baja al que no llego" "no lo mata: seguiria gastando cuota"
fi

# 6. Si el verificador no llego, la respuesta del agente se conserva. Sin esto el turno quedaria
#    vacio, que es peor que una respuesta sin verificar.
if grep -q 'MC_VERIFY_ATIEMPO" = "true" \] && VERIFIED=' "$CHAT"; then
  _ok "6 si no llego a tiempo, se conserva la respuesta del agente"
else
  _mal "6 conserva la del agente" "VERIFIED podria pisar la respuesta con algo incompleto"
fi

# 7. Se sigue midiendo. Apagar algo sin dejar como medirlo es cerrar la puerta a revisarlo.
if grep -q 'rol="verify-gate"' "$CHAT"; then
  _ok "7 el paso deja telemetria (cuanto espero, si cambio algo)"
else
  _mal "7 deja telemetria" "sin datos no se puede revisar la decision de apagarlo"
fi

# 8. Y existe la herramienta para decidir con evidencia si se vuelve a prender.
if [ -f "$TV_ROOT/tests/comparar-verificador.sh" ]; then
  _ok "8 existe comparar-verificador.sh para juzgar si vale la pena prenderlo"
else
  _mal "8 herramienta de comparacion" "se apago el ensemble sin dejar como evaluarlo"
fi

echo
echo "== $TV_OK OK, $TV_MAL MAL =="
[ "$TV_MAL" -eq 0 ]
