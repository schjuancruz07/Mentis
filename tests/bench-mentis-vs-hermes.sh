#!/usr/bin/env bash
# bench-mentis-vs-hermes.sh -- comparativa objetiva entre los dos agentes (2026-07-26).
#
# el usuario pidió que la convivencia entre Mentis y Hermes se decida "en base a resultados". Para que
# eso signifique algo hay que fijar las reglas ANTES de ver los numeros -- si no, uno elige el
# criterio que favorece a lo que ya prefiere (el mismo sesgo autor=verificador que ataca
# nv-verify.sh).
#
# REGLAS, fijadas antes de la primera corrida:
#   1. MISMO MODELO para los dos (glm-5.2 via NVIDIA). Lo que se compara es el ANDAMIAJE
#      (loop, herramientas, verificacion), no que un modelo sea mejor que otro.
#   2. MISMA tarea, mismo texto, misma carpeta vacia de trabajo para cada uno.
#   3. Aprobacion OBJETIVA: un verificador externo corre despues y decide por exit code.
#      Ninguno de los dos agentes opina sobre su propio resultado.
#   4. Se mide: aprobado si/no, segundos, y si dejo el archivo pedido.
#   5. Un fallo de entorno (no arranca, se cuelga) cuenta como no aprobado, no se repite
#      "hasta que salga": en la vida real el usuario tampoco lo reintentaria diez veces.
set -uo pipefail

MENTIS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_DIR="${HERMES_DIR:-$HOME/Hermes}"
SALIDA="${1:-$MENTIS/tests/bench-mentis-vs-hermes-resultado.md}"
BENCH_TMP="$(mktemp -d)"
trap 'rm -rf "$BENCH_TMP"' EXIT

# uv se rompe si ve los shims de python de ~/bin (scripts con nombre.exe, ERR-011/070).
PATH_LIMPIO="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$HOME/bin$" | grep -v "^/c/Users/<usuario>/bin$" | paste -sd: -)"

# tarea ::: archivo esperado ::: verificador python (recibe la carpeta como argv[1])
CASOS=(
"Escribi un archivo cuit.py con una funcion validar_cuit(cuit) que reciba un CUIT argentino como string (formato NN-NNNNNNNN-N o 11 digitos seguidos) y devuelva True o False segun el digito verificador. El algoritmo: se multiplican los primeros 10 digitos por 5,4,3,2,7,6,5,4,3,2 respectivamente, se suman, se calcula 11 menos el resto de dividir por 11; si da 11 el verificador es 0, si da 10 es 9, si no es ese numero. No expliques nada, solo escribi el archivo.:::cuit.py:::
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location('cuit', os.path.join(sys.argv[1], 'cuit.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.validar_cuit('20-12345678-6') is True, 'deberia aceptar un CUIT valido'
assert m.validar_cuit('20-12345678-5') is False, 'deberia rechazar un verificador incorrecto'
assert m.validar_cuit('20123456786') is True, 'deberia aceptar sin guiones'
print('OK')
"
"Escribi un archivo plata.py con una funcion repartir(total, partes) que reparta un monto en pesos entre N partes iguales SIN perder centavos por redondeo: la suma de las partes tiene que dar exactamente el total. Recibe total como float (ej 100.00) y partes como int, y devuelve una lista de floats con 2 decimales. No expliques nada, solo escribi el archivo.:::plata.py:::
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location('plata', os.path.join(sys.argv[1], 'plata.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.repartir(100.00, 3)
assert len(r) == 3, 'tienen que ser 3 partes'
assert abs(sum(r) - 100.00) < 0.0001, 'la suma tiene que dar exactamente 100, dio %r' % sum(r)
r2 = m.repartir(10.00, 4)
assert abs(sum(r2) - 10.00) < 0.0001, 'la suma tiene que dar exactamente 10'
print('OK')
"
)

_verificar() {   # _verificar <carpeta> <codigo_python>
  local carpeta="$1" codigo="$2" archivo="$BENCH_TMP/verificador.py"
  printf '%s' "$codigo" > "$archivo"
  ( cd "$carpeta" && timeout 60 python3 "$(cygpath -w "$archivo" 2>/dev/null || printf '%s' "$archivo")" "$(cygpath -w "$carpeta" 2>/dev/null || printf '%s' "$carpeta")" ) >/dev/null 2>&1
}

{
  echo "# Mentis vs Hermes -- comparativa objetiva"
  echo
  echo "Fecha: $(date '+%Y-%m-%d %H:%M') | Modelo comun: **z-ai/glm-5.2** (via NVIDIA)"
  echo
  echo "Reglas fijadas ANTES de correr: misma tarea, misma carpeta vacia, verificador externo"
  echo "que aprueba por exit code. Ninguno de los dos evalua su propio trabajo."
  echo
  echo "| # | Tarea | Agente | Aprobado | Segundos | Dejo el archivo |"
  echo "|---|---|---|---|---|---|"
} > "$SALIDA"

N=0
for caso in "${CASOS[@]}"; do
  N=$((N+1))
  TAREA="${caso%%:::*}"
  RESTO="${caso#*:::}"
  ARCHIVO="${RESTO%%:::*}"
  VERIF="${RESTO#*:::}"
  NOMBRE_CORTO="$(printf '%s' "$TAREA" | cut -c1-42)..."

  # ---------- MENTIS ----------
  DIR_M="$BENCH_TMP/mentis-$N"; mkdir -p "$DIR_M"
  T0="$(date +%s)"
  ( cd "$DIR_M" && timeout 600 bash "$MENTIS/engine/nv-agent.sh" -w -m code -d "$DIR_M" -i 15 "$TAREA" ) >/dev/null 2>&1
  T_M=$(( $(date +%s) - T0 ))
  [ -s "$DIR_M/$ARCHIVO" ] && ARCH_M="si" || ARCH_M="no"
  if _verificar "$DIR_M" "$VERIF"; then OK_M="**si**"; else OK_M="no"; fi
  echo "| $N | $NOMBRE_CORTO | Mentis | $OK_M | ${T_M}s | $ARCH_M |" >> "$SALIDA"
  echo "  [$N] Mentis: aprobado=$OK_M ${T_M}s archivo=$ARCH_M" >&2

  # ---------- HERMES ----------
  DIR_H="$BENCH_TMP/hermes-$N"; mkdir -p "$DIR_H"
  T0="$(date +%s)"
  ( cd "$DIR_H" && PATH="$HOME/.local/bin:$PATH_LIMPIO" UV_PYTHON_DOWNLOADS=never \
      timeout 600 uv run --project "$HERMES_DIR" hermes --yolo -z "$TAREA" ) >/dev/null 2>&1
  T_H=$(( $(date +%s) - T0 ))
  [ -s "$DIR_H/$ARCHIVO" ] && ARCH_H="si" || ARCH_H="no"
  if _verificar "$DIR_H" "$VERIF"; then OK_H="**si**"; else OK_H="no"; fi
  echo "| $N | $NOMBRE_CORTO | Hermes | $OK_H | ${T_H}s | $ARCH_H |" >> "$SALIDA"
  echo "  [$N] Hermes: aprobado=$OK_H ${T_H}s archivo=$ARCH_H" >&2
done

echo >> "$SALIDA"
cat "$SALIDA"
