#!/usr/bin/env bash
# test-hooks.sh -- el motor de hooks: que corra los que hay, que NO pague nada cuando no hay
# ninguno, y que un hook roto no pueda frenar el turno.
#
# POR QUE EXISTE (2026-08-20): el motor no tenia test. Se descubrio midiendo: con hooks.json
# vacio -- que es el estado de hoy -- cada llamada costaba 439 ms porque arrancaba python3 para
# descubrir que no habia nada que hacer. Se invoca dos veces por turno (UserPromptSubmit y Stop),
# o sea 878 ms por turno tirados. La correccion (salida temprana leyendo el archivo con bash puro)
# lo dejo en 50 ms, con el piso de arrancar bash en 56.
#
# La parte de la VELOCIDAD se prueba de verdad, no por inspeccion del codigo: un test que hace
# grep de "exit 0" pasaria aunque la salida temprana estuviera despues del python.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOTOR="$HERE/mentis-hooks.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# Cada caso corre en su propia carpeta con su propio hooks.json: el motor lee el que esta al lado
# suyo, asi que se copia. Nunca se toca el hooks.json de produccion (un test que escribe en el
# estado real es como se rompieron reason y extract por 46 horas -- ver ERR-119).
_caja() {
  local dir; dir="$(mktemp -d)"
  cp "$MOTOR" "$dir/mentis-hooks.sh"
  printf '%s\n' "$1" > "$dir/hooks.json"
  printf '%s' "$dir"
}

echo "== corre lo que hay =="
CAJA="$(_caja '{"hooks":{"UserPromptSubmit":[{"command":"echo HOLA-DESDE-EL-HOOK"}]}}')"
SAL="$(bash "$CAJA/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
[ "$SAL" = "HOLA-DESDE-EL-HOOK" ] && _ok "un hook registrado corre y su stdout sale" \
  || _mal "hook simple" "salio: '$SAL'"

# Dos hooks en el mismo evento: los dos, en orden.
CAJA2="$(_caja '{"hooks":{"Stop":[{"command":"echo UNO"},{"command":"echo DOS"}]}}')"
SAL="$(bash "$CAJA2/mentis-hooks.sh" Stop 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
[ "$SAL" = "UNO DOS " ] && _ok "dos hooks del mismo evento corren en orden" || _mal "dos hooks" "salio: '$SAL'"

# SIN \r. Lo que sale de aca se inyecta en el prompt del modelo, y el python de Windows escribe
# en modo texto: cada \n salia como \r\n. Se mira el byte, no la cadena -- bash con `igncr` (que
# es como corre en MSYS) compara "UNO" contra "UNO\r" y dice que son iguales, asi que una
# comparacion de texto NO detecta esto. Fue exactamente lo que paso: el test decia ok.
if bash "$CAJA2/mentis-hooks.sh" Stop 2>/dev/null | od -An -c | grep -q '\\r'; then
  _mal "sin retornos de carro" "la salida trae \\r y eso se inyecta en el contexto del modelo"
else
  _ok "la salida no trae \\r (se mira el byte, no la cadena)"
fi

# El evento importa: un hook de Stop no puede dispararse en UserPromptSubmit.
SAL="$(bash "$CAJA2/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
[ -z "$SAL" ] && _ok "un hook de otro evento no se dispara" || _mal "evento cruzado" "salio: '$SAL'"

echo ""
echo "== las variables de entorno llegan =="
SAL="$(MENTIS_HOOK_MSG="hola usuario" bash "$CAJA/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
[ -n "$SAL" ] && _ok "el hook corre con las variables del turno puestas" || _mal "entorno" "no corrio"
CAJA3="$(_caja '{"hooks":{"UserPromptSubmit":[{"command":"echo MSG=$MENTIS_HOOK_MSG"}]}}')"
SAL="$(MENTIS_HOOK_MSG="hola" bash "$CAJA3/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
[ "$SAL" = "MSG=hola" ] && _ok "MENTIS_HOOK_MSG llega al comando" || _mal "MENTIS_HOOK_MSG" "salio: '$SAL'"

echo ""
echo "== fail-safe: un hook roto NO puede frenar el turno =="
CAJA4="$(_caja '{"hooks":{"Stop":[{"command":"exit 7"},{"command":"echo IGUAL-SIGO"}]}}')"
SAL="$(bash "$CAJA4/mentis-hooks.sh" Stop 2>/dev/null)"; RC=$?
[ "$RC" = "0" ] && _ok "un hook que falla no cambia el codigo de salida" || _mal "rc con hook roto" "rc=$RC"
[ "$SAL" = "IGUAL-SIGO" ] && _ok "los hooks siguientes corren igual" || _mal "hook posterior" "salio: '$SAL'"

CAJA5="$(_caja '{"hooks":{"Stop":[{"command":"comando-que-no-existe-en-ningun-lado"}]}}')"
bash "$CAJA5/mentis-hooks.sh" Stop >/dev/null 2>&1
[ "$?" = "0" ] && _ok "un comando inexistente no rompe nada" || _mal "comando inexistente" "devolvio $?"

# El stderr del hook NO se inyecta: si un hook escribe ruido de debug, no tiene que terminar
# adentro del contexto del modelo.
CAJA6="$(_caja '{"hooks":{"Stop":[{"command":"echo RUIDO >&2; echo LIMPIO"}]}}')"
SAL="$(bash "$CAJA6/mentis-hooks.sh" Stop 2>/dev/null)"
[ "$SAL" = "LIMPIO" ] && _ok "el stderr del hook no se inyecta" || _mal "stderr" "salio: '$SAL'"

echo ""
echo "== el JSON roto no rompe el turno =="
CAJA7="$(_caja '{"hooks": {"Stop": [ esto no es json')"
bash "$CAJA7/mentis-hooks.sh" Stop >/dev/null 2>&1
[ "$?" = "0" ] && _ok "un hooks.json invalido sale limpio" || _mal "json roto" "devolvio $?"

echo ""
echo "== el apagado general =="
SAL="$(MENTIS_HOOKS_OFF=1 bash "$CAJA/mentis-hooks.sh" UserPromptSubmit 2>/dev/null)"
[ -z "$SAL" ] && _ok "MENTIS_HOOKS_OFF=1 apaga todo el motor" || _mal "apagado" "salio: '$SAL'"

echo ""
echo "== se puede invocar de las tres formas =="
# La salida temprana usa ${BASH_SOURCE[0]%/*} en vez de un subshell con cd+pwd (60 ms menos).
# Eso tiene un caso borde real: invocado SIN barra, esa expansion devuelve el nombre del archivo
# en lugar del directorio. Las tres formas se prueban porque las tres se usan.
CAJA8="$(_caja '{"hooks":{"Stop":[{"command":"echo VIVO"}]}}')"
[ "$(cd /tmp && bash "$CAJA8/mentis-hooks.sh" Stop 2>/dev/null)" = "VIVO" ] \
  && _ok "con ruta absoluta desde otra carpeta" || _mal "ruta absoluta" "no encontro su hooks.json"
[ "$(cd "$CAJA8" && bash mentis-hooks.sh Stop 2>/dev/null)" = "VIVO" ] \
  && _ok "sin barra, parado en su carpeta" || _mal "sin barra" "no encontro su hooks.json"
[ "$(cd "$CAJA8" && bash./mentis-hooks.sh Stop 2>/dev/null)" = "VIVO" ] \
  && _ok "con./" || _mal "con./" "no encontro su hooks.json"

echo ""
echo "== y lo que motivo todo esto: sin hooks no se paga nada =="
# El numero no se compara contra una constante inventada: se compara contra el PISO de esta
# maquina (arrancar un bash que no hace nada). Un tope fijo tipo "menos de 100 ms" seria un test
# que falla en una maquina mas lenta sin que nada este roto.
_medir() { # <carpeta> <evento> -> ms promedio de 5 corridas
  local t0 t1
  t0=$(date +%s%N)
  for _ in 1 2 3 4 5; do bash "$1/mentis-hooks.sh" "$2" >/dev/null 2>&1; done
  t1=$(date +%s%N)
  echo $(( (t1-t0)/5000000 ))
}
T0=$(date +%s%N); for _ in 1 2 3 4 5; do bash -c 'exit 0'; done; T1=$(date +%s%N)
PISO=$(( (T1-T0)/5000000 ))
CAJA9="$(_caja '{"hooks":{"SessionStart":[],"UserPromptSubmit":[],"Stop":[]}}')"
VACIO="$(_medir "$CAJA9" UserPromptSubmit)"
TECHO=$(( PISO * 2 + 30 ))
printf '  (piso de esta maquina: %s ms | con hooks.json vacio: %s ms | techo: %s ms)\n' "$PISO" "$VACIO" "$TECHO"
if [ "$VACIO" -le "$TECHO" ]; then
  _ok "con los tres eventos vacios sale sin arrancar python"
else
  _mal "salida temprana" "tarda ${VACIO} ms contra un piso de ${PISO} ms: volvio a pagar el interprete"
fi

rm -rf "$CAJA" "$CAJA2" "$CAJA3" "$CAJA4" "$CAJA5" "$CAJA6" "$CAJA7" "$CAJA8" "$CAJA9"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
