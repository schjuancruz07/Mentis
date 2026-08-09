#!/usr/bin/env bash
# test-verify-escalera.sh -- verificacion independiente del codigo que escribe el agente.
#
# Prueba el loop REAL de nv-agent.sh (no una simulacion de la funcion suelta): se copia el motor
# a un dir temporal y se reemplaza ask-nvidia.sh por un stub deterministico. Asi se ejercita el
# camino completo write -> done -> tester independiente -> sandbox -> observacion, sin gastar una
# sola llamada de API y con resultado reproducible.
#
# OJO CON EL DISEÑO (cambio del 2026-07-26): la verificacion ya NO corre en cada 'write', corre
# UNA vez cuando el agente dice 'done'. Medido sobre la misma tarea real:
#     sin verificacion            25 s   3 iteraciones
#     verificando en cada write  373 s   8 iteraciones
#     verificando al cierre      500 s  13 iteraciones
# Por eso ademas quedo APAGADA por defecto y estos tests la activan con NV_AGENT_VERIFY=1.
#
# Cubre:
#   1. FAIL       -- tests que no pasan -> el 'done' se RECHAZA y el agente recibe el error real.
#   2. PASS       -- tests que pasan y mueren sin la implementacion -> VERIFICADO.
#   3. MUTATION   -- tests que pasan igual sin la implementacion -> NO CONCLUYENTE (no "pass").
#   4. DEPS       -- falta un modulo en el sandbox aislado -> NO CONCLUYENTE (no "fail").
#   5. UNA SOLA   -- varios writes del mismo archivo gastan UNA sola verificacion.
#   6. APAGADA    -- por defecto no se verifica nada.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../engine"
PASS=0; FAIL=0

_ok()   { echo "  OK   -- $1"; PASS=$((PASS+1)); }
_bad()  { echo "  FALLO-- $1"; FAIL=$((FAIL+1)); }
_expect()     { if printf '%s' "$2" | grep -qE "$3"; then _ok "$1"; else _bad "$1 (no aparece: $3)"; fi; }
_expect_not() { if printf '%s' "$2" | grep -qE "$3"; then _bad "$1 (aparece y no deberia: $3)"; else _ok "$1"; fi; }

# El sandbox imita la estructura REAL de Mentis: raíz/ + raíz/engine/. Antes el motor se copiaba
# suelto en un temporal, así que MENTIS_ROOT (que nv-agent.sh calcula como "la carpeta de arriba")
# apuntaba a /tmp -- y todo lo que el agente busca en la raíz de Mentis no existía ahí.
# Eso fue exactamente lo que rompió esta suite en silencio (ERR-095): antes de cada 'write' el
# agente saca una foto de seguridad con mentis-deshacer.sh, no lo encontraba, y bajo `set -e` la
# asignación fallida lo mataba justo antes de la primera escritura. Como la mayoría de las
# aserciones eran del tipo "que NO aparezca X", un agente que no arrancaba las cumplía todas: la
# suite daba 6 de 18 en verde sin haber ejecutado una sola línea del código que dice probar.
SB_RAIZ="$(mktemp -d)"
trap 'rm -rf "$SB_RAIZ"' EXIT
SB="$SB_RAIZ/engine"
mkdir -p "$SB"
cp "$ENGINE/nv-agent.sh" "$ENGINE/nv-lib.sh" "$ENGINE/nv-verify.sh" "$SB/" 2>/dev/null || \
  cp "$ENGINE/nv-agent.sh" "$ENGINE/nv-lib.sh" "$SB/"

# Stub de mentis-deshacer.sh: el sandbox NO puede tocar el repo sombra real del usuario. Devuelve un
# id falso, que es todo lo que el agente necesita para seguir.
cat > "$SB_RAIZ/mentis-deshacer.sh" <<'DESHACER'
#!/usr/bin/env bash
echo "foto-de-prueba-0000"
DESHACER
chmod +x "$SB_RAIZ/mentis-deshacer.sh"

# ---- stub deterministico de ask-nvidia.sh -------------------------------------------------
cat > "$SB/ask-nvidia.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
# ERR-002: nada de nombres de env genericos (PROMPT, TEMP, OS...) en Windows/Git Bash.
STUB_ROL="${@: -1}"
STUB_PROMPT="$(cat)"
STATE="${STUB_STATE:?}"
STUB_ESC="${STUB_ESC:?}"

if printf '%s' "$STUB_PROMPT" | grep -q "Escribi SOLO un bloque de tests"; then
  echo "tester:$STUB_ROL" >> "$STATE.testers"
  case "$STUB_ESC" in
    mutation) printf 'assert True\n' ;;                     # no ejercita nada -> mutation check
    *)        printf 'assert suma(2, 2) == 4\n' ;;
  esac
  exit 0
fi

STUB_N="$(cat "$STATE" 2>/dev/null || echo 0)"; STUB_N=$((STUB_N+1)); echo "$STUB_N" > "$STATE"
echo "agente:$STUB_ROL:$STUB_N" >> "$STATE.agent"

# Los cuerpos superan NV_AGENT_VERIFY_MINBYTES (80): un archivo de dos lineas se saltea a
# proposito, porque no justifica gastar una llamada al modelo tester.
STUB_BUENO='"""Utilidades aritmeticas de prueba."""


def suma(a, b):
    """Devuelve la suma de dos numeros."""
    return a + b


def suma_lista(valores):
    """Suma acumulada de una lista de numeros."""
    total = 0
    for v in valores:
        total = suma(total, v)
    return total'
STUB_MALO="${STUB_BUENO/return a + b/return a - b}"

case "$STUB_ESC" in
  fail)      STUB_BODY="$STUB_MALO"  ; STUB_LIMIT=1 ;;
  pass)      STUB_BODY="$STUB_BUENO" ; STUB_LIMIT=1 ;;
  mutation)  STUB_BODY="$STUB_BUENO" ; STUB_LIMIT=1 ;;
  deps)      STUB_BODY="import modulo_inexistente_xyz

$STUB_BUENO" ; STUB_LIMIT=1 ;;
  # varios writes del MISMO archivo: tiene que gastar una sola verificacion, no tres
  unasola)   STUB_BODY="$STUB_BUENO" ; STUB_LIMIT=3 ;;
  apagada)   STUB_BODY="$STUB_BUENO" ; STUB_LIMIT=1 ;;
esac

if [ "$STUB_N" -le "$STUB_LIMIT" ]; then
  # en 'unasola' se reescribe SIEMPRE el mismo archivo, para probar que no se re-verifica
  STUB_ARCH="art${STUB_N}.py"
  [ "$STUB_ESC" = "unasola" ] && STUB_ARCH="art1.py"
  STUB_BODY="$STUB_BODY" STUB_ARCH="$STUB_ARCH" python3 -c '
import json, os
print(json.dumps({"tool": "write", "path": os.environ["STUB_ARCH"],
                  "content": os.environ["STUB_BODY"] + "\n"}))'
else
  printf '{"tool":"done","answer":"listo"}\n'
fi
STUB
chmod +x "$SB/ask-nvidia.sh"

_run() {   # _run <escenario> <verificacion 0|1> <max-iter>
  local esc="$1" verif="$2" iters="$3" work
  work="$SB/work-$esc"; mkdir -p "$work"
  rm -f "$SB/state-$esc" "$SB/state-$esc".*
  STUB_ESC="$esc" STUB_STATE="$SB/state-$esc" NV_AGENT_VERIFY="$verif" \
  MENTIS_SETTINGS_FILE="$SB/nope.json" \
    bash "$SB/nv-agent.sh" -d "$work" -m code -i "$iters" -w "tarea de prueba" 2>&1
}

# ---- GUARDIA DE ARRANQUE (agregada 2026-07-29, ERR-095) ------------------------------------
# La lección que dejó esta suite: casi todas sus aserciones son del tipo "que NO aparezca X", y
# esas se cumplen solas cuando el agente ni siquiera arranca. Estuvo así vaya a saber cuánto,
# dando 6 de 18 en verde sin ejecutar una línea del código que dice probar.
# Esto se corre PRIMERO y corta todo si el sandbox no ejecuta de verdad: es la única aserción
# POSITIVA de la que dependen todas las demás. Si esta falla, el resto no significa nada.
echo "== 0. el agente ARRANCA de verdad en el sandbox =="
ARRANQUE="$(_run pass 0 2)"
if printf '%s' "$ARRANQUE" | grep -qE '\[nv-agent\] iter 1: (write|read|done|search)'; then
  _ok "el agente ejecuta al menos una iteración en el sandbox"
else
  _bad "el agente NO ejecuta NADA en el sandbox -- todo lo que siga es humo"
  echo "     salida real:"; printf '%s\n' "$ARRANQUE" | head -6 | sed 's/^/     /'
  echo
  echo "RESULTADO: $PASS OK, $FAIL fallos (abortado: sin arranque no hay nada que probar)."
  exit 1
fi

echo "== 1. FALLO: el 'done' se rechaza y el agente recibe el error =="
OUT="$(_run fail 1 6)"
_expect "el fallo real llega a la observacion del agente" "$OUT" "FALLO DE VERIFICACION"
_expect "el veredicto es 'fail'"                          "$OUT" "verificacion final de 'art1\.py' -> fail"
_expect "el 'done' se rechaza explicitamente"             "$OUT" "'done' RECHAZADO"
TESTERS="$(cat "$SB/state-fail.testers" 2>/dev/null || true)"
_expect_not "el tester NUNCA es el autor (code)"          "$TESTERS" "tester:code"
_expect "el tester es un modelo independiente"            "$TESTERS" "tester:general"

echo "== 2. PASS: tests que pasan y mueren sin la implementacion =="
OUT="$(_run pass 1 4)"
_expect "el artefacto queda VERIFICADO"                   "$OUT" "VERIFICADO: un modelo independiente"
_expect "el veredicto es 'pass'"                          "$OUT" "verificacion final de 'art1\.py' -> pass"
_expect_not "el 'done' NO se rechaza"                     "$OUT" "'done' RECHAZADO"

echo "== 3. MUTATION: tests que pasan igual sin la implementacion =="
OUT="$(_run mutation 1 4)"
_expect "se detecta que los tests no ejercitan el codigo" "$OUT" "no probaron nada"
_expect "el veredicto NO es 'pass'"                       "$OUT" "verificacion final de 'art1\.py' -> unverifiable"
_expect_not "no se declara VERIFICADO"                    "$OUT" "VERIFICADO: un modelo independiente"

echo "== 4. DEPS: dependencia ausente en el sandbox aislado =="
OUT="$(_run deps 1 4)"
_expect "se reporta como no concluyente"                  "$OUT" "verificacion final de 'art1\.py' -> unverifiable"
_expect "se le pide verificar con exec en el repo real"   "$OUT" "Verificalo vos con \"exec\""
_expect_not "NO se acusa al codigo de estar roto"         "$OUT" "FALLO DE VERIFICACION"

echo "== 5. UNA SOLA verificacion aunque haya varios writes =="
OUT="$(_run unasola 1 8)"
NTEST="$(wc -l < "$SB/state-unasola.testers" 2>/dev/null || echo 0)"
if [ "$NTEST" -eq 1 ]; then _ok "3 writes del mismo archivo gastaron 1 sola llamada al tester"
else _bad "se gastaron $NTEST llamadas al tester, se esperaba 1 (esto costaba 15x en produccion)"; fi
_expect "igual se verifica al cerrar" "$OUT" "verificacion final de"

echo "== 6. APAGADA por defecto =="
OUT="$(_run apagada 0 4)"
_expect_not "no se verifica nada sin NV_AGENT_VERIFY=1" "$OUT" "verificacion final de"
# El archivo no existe justamente cuando la verificación está apagada -- que es el caso bueno.
# El `wc` sobre un archivo inexistente escupía un error a stderr que ensuciaba la corrida.
NTEST0="$([ -f "$SB/state-apagada.testers" ] && wc -l < "$SB/state-apagada.testers" || echo 0)"
[ "$NTEST0" -eq 0 ] && _ok "cero llamadas al tester con la verificacion apagada" \
                    || _bad "gasto $NTEST0 llamadas al tester estando apagada"

echo
echo "RESULTADO: $PASS OK, $FAIL fallos."
[ "$FAIL" -eq 0 ]
