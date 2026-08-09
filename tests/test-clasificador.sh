#!/usr/bin/env bash
# test-clasificador.sh -- el "cerebro rapido" reescrito en bash tiene que decidir EXACTAMENTE lo
# mismo que la version original en python, pero sin arrancar un interprete por mensaje.
#
# POR QUE (medido en esta maquina el 2026-07-30):
#     clasificador en python............ 515 / 613 / 675 ms
#     arranque pelado de python3........ 475 ms   <- el 80% del costo, en CADA mensaje
#     spawn de cualquier proceso........ ~75 ms   (grep tampoco entra en el presupuesto)
#
# La reescritura solo vale si NO cambia ni una decision. Por eso esto no es un test de casos
# elegidos a mano: corre las DOS implementaciones sobre el mismo corpus y exige que coincidan.
#
# El corpus sale de tres lados, a proposito:
#   1. los mensajes REALES del usuario (conversations/ + history.jsonl) -- lo que de verdad escribe;
#   2. la lista cerrada de frases triviales -- todas tienen que seguir dando "trivial";
#   3. casos borde a mano -- los que rompieron esta heuristica antes (ver bitacora).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
_ok()  { echo "ok: $1"; PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$DIR/engine/nv-classify-lib.sh"

echo "== 0. GUARDIA: las dos implementaciones existen y contestan =="
R_RAPIDO="$(nv_classify_msg 'hola' 0)"
R_REF="$(nv_classify_msg_ref 'hola' 0)"
if [ -n "${R_RAPIDO// }" ] && [ -n "${R_REF// }" ]; then
  _ok "las dos responden (rapido='$R_RAPIDO', referencia='$R_REF')"
else
  _bad "alguna implementacion no contesta -- el resto del test no significa nada"
  echo; echo "RESULTADO: $PASS ok, $FAIL fallos."; exit 1
fi

# --- corpus -----------------------------------------------------------------------------------
CORPUS="$(mktemp)"
trap 'rm -f "$CORPUS"' EXIT

# 1) mensajes reales
MC_DIR="$(cygpath -w "$DIR" 2>/dev/null || printf '%s' "$DIR")"
# PYTHONIOENCODING es obligatorio: sin esto, python escribe el corpus en la pagina de codigos de
# la consola (CP850) y bash despues lee bytes que no son UTF-8. Los acentos dejan de coincidir con
# la tabla de _nv_norm y el test reporta diferencias que NO existen en el codigo -- me paso en la
# primera corrida: tres "cuantos..." daban distinto y era el archivo, no el clasificador.
MC_DIR="$MC_DIR" PYTHONIOENCODING=utf-8 python3 -c '
import glob, json, os
raiz = os.environ["MC_DIR"]
vistos = set()
for f in glob.glob(os.path.join(raiz, "conversations", "*.jsonl")) + [os.path.join(raiz, "history.jsonl")]:
    try:
        for linea in open(f, encoding="utf-8"):
            try:
                d = json.loads(linea)
            except Exception:
                continue
            if d.get("role") != "usuario":
                continue
            t = (d.get("text") or "").strip().replace("\n", " ")
            if t and len(t) < 300 and t not in vistos:
                vistos.add(t); print(t)
    except Exception:
        pass
' >> "$CORPUS" 2>/dev/null

REALES=$(grep -c. "$CORPUS" 2>/dev/null || echo 0)
if [ "$REALES" -ge 20 ]; then
  _ok "corpus con $REALES mensajes reales del usuario"
else
  _bad "solo $REALES mensajes reales -- el corpus quedo flaco, revisar la extraccion"
fi

# 2) toda la lista cerrada de triviales (tal cual la escribiria el usuario, con acentos incluidos)
for t in "${!NV_TRIVIAL[@]}"; do printf '%s\n' "$t"; done >> "$CORPUS"
printf '%s\n' "Hola" "GRACIAS" "¿Cómo estás?" "hasta mañana" "Hasta Mañana!" "Buenos días" >> "$CORPUS"

# 3) casos borde: los que rompieron esta heuristica antes, y los que separan una rama de otra
cat >> "$CORPUS" <<'CASOS'
hola, implementame una funcion en python
gracias, ahora implementame una funcion en python
dale, explicame como funciona el router
claro que si, podes escribir un script de bash?
buscame donde esta el archivo de configuracion del proyecto
en que archivo esta la funcion de login del repo
que es un decorator en python
como funciona async await
cuanto es la probabilidad de que salga cara
convien mas mongo o postgres para esto
compara redis vs memcached y decime cual conviene
generame una imagen de un perro
mandame una foto del informe
que hora es
contame como estas hoy con tus capacidades
abri la calculadora y calcula 47 por 89
escribi codigo para ordenar una lista
necesito una clase con herencia y polimorfismo
esto no tiene nada que ver con nada
por que fallo el ultimo turno
demostrame que esto es correcto
optimizame la query sql
un mensaje cualquiera sin ninguna palabra clave especial
CASOS

TOTAL=$(grep -c. "$CORPUS" 2>/dev/null || echo 0)
echo "== 1. las dos implementaciones coinciden en los $TOTAL casos del corpus =="

DIFERENCIAS=0; COMPARADOS=0
while IFS= read -r linea; do
  [ -n "${linea// }" ] || continue
  for hf in 0 1; do
    r_rapido="$(nv_classify_msg "$linea" "$hf")"
    r_ref="$(nv_classify_msg_ref "$linea" "$hf")"
    COMPARADOS=$((COMPARADOS+1))
    if [ "$r_rapido" != "$r_ref" ]; then
      DIFERENCIAS=$((DIFERENCIAS+1))
      [ "$DIFERENCIAS" -le 10 ] && echo "    DIFIERE (hasfiles=$hf): '$linea'"
      [ "$DIFERENCIAS" -le 10 ] && echo "        rapido='$r_rapido'  referencia='$r_ref'"
    fi
  done
done < "$CORPUS"

if [ "$DIFERENCIAS" -eq 0 ]; then
  _ok "$COMPARADOS comparaciones, cero diferencias"
else
  _bad "$DIFERENCIAS diferencias sobre $COMPARADOS comparaciones"
fi

echo "== 2. lo que el cerebro rapido tiene que seguir acertando =="
_clas() { nv_classify_msg "$1" 0 | cut -d' ' -f1; }
_espera() { local got; got="$(_clas "$1")"; if [ "$got" = "$2" ]; then _ok "\"$1\" -> $2"; else _bad "\"$1\" -> $got (esperaba $2)"; fi; }

_espera "gracias mentis" trivial
_espera "dale dale" trivial
_espera "¿Cómo estás?" trivial
_espera "hasta mañana" trivial      # antes era codigo muerto: la clave tenia eñe y el mensaje no
_espera "hola, implementame una funcion en python" code
_espera "gracias, ahora implementame una funcion en python" code
_espera "generame una imagen de un perro" multimodal
_espera "cuanto es la probabilidad de que salga cara" reason
_espera "un mensaje cualquiera sin ninguna palabra clave especial" general

echo "== 3. VELOCIDAD: el punto de todo esto =="
# Se mide la forma que USA el chat (nv_classify_msg_vars, sin subshell). La otra imprime, y
# capturar su salida con $(...) agrega ~26 ms que no tienen nada que ver con el clasificador.
INICIO=$(date +%s%N)
for i in $(seq 1 30); do nv_classify_msg_vars "gracias mentis" 0; done
FIN=$(date +%s%N)
MS_TOTAL=$(( (FIN - INICIO) / 1000000 ))
MS_UNO=$(( MS_TOTAL / 30 ))
echo "    30 clasificaciones en ${MS_TOTAL} ms -> ${MS_UNO} ms cada una"
if [ "$MS_UNO" -lt 50 ]; then
  _ok "menos de 50 ms por mensaje (objetivo cumplido)"
else
  _bad "${MS_UNO} ms por mensaje: no se cumplio el objetivo de <50 ms"
fi

# El chat tiene que estar usando la version rapida: si alguien vuelve a poner $(nv_classify_msg),
# el test de arriba sigue en verde y la mejora se pierde en silencio.
if grep -q 'nv_classify_msg_vars "\$MSG"' "$DIR/mentis-chat.sh"; then
  _ok "mentis-chat.sh usa la version sin subshell"
else
  _bad "mentis-chat.sh no esta usando nv_classify_msg_vars: la mejora no llega al producto"
fi

# Y la comparacion contra la version vieja, para que el numero tenga con que compararse.
INICIO=$(date +%s%N)
for i in 1 2 3; do nv_classify_msg_ref "gracias mentis" 0 >/dev/null; done
FIN=$(date +%s%N)
MS_REF=$(( (FIN - INICIO) / 1000000 / 3 ))
echo "    referencia (python): ${MS_REF} ms cada una"
if [ "$MS_UNO" -lt "$MS_REF" ]; then
  _ok "la version nueva es mas rapida que la vieja (${MS_UNO} ms vs ${MS_REF} ms)"
else
  _bad "no hubo mejora real (${MS_UNO} ms vs ${MS_REF} ms)"
fi

echo
echo "RESULTADO: $PASS ok, $FAIL fallos."
[ "$FAIL" -eq 0 ] || exit 1
