#!/usr/bin/env bash
# test-cierre-turno.sh -- que el agente TERMINE cuando ya cumplio, en vez de seguir dando vueltas.
#
# POR QUE EXISTE (medido el 2026-08-08):
#   Pedido: "un documento word sobre el ciclo del agua con una imagen". El documento quedo listo y
#   correcto en la iteracion 3, con la imagen adentro. El turno siguio hasta la 8 haciendo
#   busquedas que no encontraban nada y listados de directorios, y la respuesta final que leyo
#   el usuario fue un 'ls' -- ni una palabra del documento que ya existia. 299 segundos para algo que
#   estaba hecho a los 60.
#
#   EL AGUJERO ERA DE DISEÑO, no de ese modelo ni de ese pedido: las 12 guardas del agente miran
#   en UNA sola direccion -- que no afirme cosas que no hizo. Hay nota para "pediste un documento
#   y todavia no lo generaste" y rechazo para "decis que lo hiciste y no existe". No habia NADA
#   para "ya lo hiciste, termina". Se verifico recorriendo los 12 puntos que marcan una accion
#   real: ninguno empujaba a cerrar.
#
# POR QUE ESTE TEST NO CORRE UN TURNO DE VERDAD:
#   Porque dependeria de que el modelo se porte mal HOY para probar que la red lo atrapa. En la
#   corrida de verificacion el modelo cerro solo en la iteracion 6 y la red nunca se activo: si
#   el test fuera "correr un turno y ver", habria dado verde sin haber probado nada. Se prueba la
#   MECANICA con el contador simulado, que es lo unico que se puede afirmar sin mentir.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== todas las acciones reales cuentan =="
# Si alguien agrega una accion nueva y pone HAD_REAL_ACTION=1 sin sumar al contador, el turno
# creeria que esa vuelta no produjo nada y podria cortar en el medio de un trabajo util.
n_had="$(grep -c 'HAD_REAL_ACTION=1' "$A" || true)"
n_cnt="$(grep -c 'ACCIONES_N=\$((ACCIONES_N+1))' "$A" || true)"
if [ "$n_had" -eq "$n_cnt" ] && [ "$n_had" -gt 0 ]; then
  _ok "los $n_had puntos de accion real suman al contador"
else
  _mal "cada accion real suma al contador" "hay $n_had acciones y $n_cnt contadores"
fi
grep -q "^ACCIONES_N=0" "$A" && _ok "el contador arranca en cero" || _mal "ACCIONES_N inicializado" "sin inicializar no cuenta"

echo "== la mecanica de 'vuelta perdida' =="
# Misma regla que usa el loop: hubo logro previo y el contador no se movio -> vuelta perdida.
vuelta() {
  local had="$1" ahora="$2" antes="$3" acum="$4"
  if [ "$had" = "1" ] && [ "$ahora" -eq "$antes" ]; then echo $((acum+1)); else echo 0; fi
}
check() { [ "$2" = "$3" ] && _ok "$1" || _mal "$1" "esperaba $2, obtuvo $3"; }
check "sin logro previo no cuenta como perdida"      "0" "$(vuelta 0 5 5 0)"
check "con logro y sin producir -> suma"             "1" "$(vuelta 1 5 5 0)"
check "dos seguidas sin producir -> 2"               "2" "$(vuelta 1 5 5 1)"
check "una accion nueva REINICIA la cuenta"          "0" "$(vuelta 1 6 5 3)"
# Esto es lo que protege a "hacete tres documentos": cada documento resetea.
check "tarea larga: produce, se reinicia, sigue"     "0" "$(vuelta 1 9 8 3)"

echo "== los dos umbrales =="
umbral() {
  local v="$1"
  if [ "$v" -ge 4 ]; then echo "CORTA"
  elif [ "$v" -ge 2 ]; then echo "avisa"
  else echo "sigue"; fi
}
check "1 vuelta perdida: no molesta"   "sigue" "$(umbral 1)"
check "2 vueltas: avisa"               "avisa" "$(umbral 2)"
check "3 vueltas: sigue avisando"      "avisa" "$(umbral 3)"
check "4 vueltas: CORTA"               "CORTA" "$(umbral 4)"
check "el caso real medido (5 vueltas)" "CORTA" "$(umbral 5)"

echo "== el corte es un numero, no un pedido =="
# Leccion de ERR-133: una defensa redactada como instruccion al modelo es una sugerencia.
if awk '/VUELTAS_SIN_PRODUCIR" -ge 4/,/fi/' "$A" | grep -q "break"; then
  _ok "a las 4 vueltas se corta el loop de verdad"
else
  _mal "el corte usa break" "sin break solo se le pide al modelo que pare"
fi
grep -q "CIERRE_FORZADO=1" "$A" && _ok "el corte queda marcado para el cierre" || _mal "marca CIERRE_FORZADO" "el final no sabria distinguirlo"

echo "== un corte NO es un fracaso =="
# Lo mas importante: al cortar hay artefactos REALES hechos. Si eso cayera en la rama de "no
# llegue a una respuesta final", Mentis le diria al usuario que la tarea no se resolvio con su
# documento ya guardado.
if awk '/CIERRE_FORZADO:-0/,/^fi$/' "$A" | grep -q 'STATUS="done"'; then
  _ok "el cierre forzado termina en done, no en fracaso"
else
  _mal "el cierre forzado da done" "reportaria como fallida una tarea que produjo resultados"
fi
# ANCLA CORREGIDA (2026-08-18): estas dos aserciones buscaban desde /_cierre_prompt=/ en
# adelante, pero el prompt se partió en _cierre_cab/_cierre_pie y el texto que se verifica
# vive en el PIE, que se asigna ANTES. O sea que fallaban con el codigo correcto: el rango
# del awk arrancaba despues del texto. Se ancla al bloque entero.
if awk '/_cierre_cab=/,/_cierre_prompt=/' "$A" | grep -q "NO listes directorios"; then
  _ok "la respuesta final tiene prohibido el listado de directorios"
else
  _mal "prohibe el listado de directorios" "era literalmente lo que le contesto al usuario"
fi
if awk '/_cierre_cab=/,/_cierre_prompt=/' "$A" | grep -q "donde quedo guardado\|dónde quedó guardado"; then
  _ok "pide decir QUE genero y DONDE quedo"
else
  _mal "pide que y donde" "sin eso vuelve a contar lo que busco en vez de lo que hizo"
fi
# Y si el modelo no contesta, igual no se miente en ninguna de las dos direcciones.
if awk '/if \[ -z "\$FINAL" \]/,/fi/' "$A" | grep -q "Terminé la tarea"; then
  _ok "hay respuesta de ultimo recurso si el modelo no contesta"
else
  _mal "respuesta de ultimo recurso" "el turno quedaria mudo con trabajo hecho"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
