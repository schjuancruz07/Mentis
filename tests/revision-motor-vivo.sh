#!/usr/bin/env bash
# revision-motor-vivo.sh -- un turno REAL en cada modo, contra el modelo de verdad.
#
# POR QUE HACE FALTA ADEMAS DE LOS TESTS: los 376 casos de tests prueban las piezas -- que el
# protocolo se arme, que las guardas corten, que el compilador valide. Ninguno prueba lo unico que
# le importa al usuario: que si abre Mentis y le pide algo, funcione. Este archivo hace eso, modo por
# modo, con una tarea propia de cada oficio.
#
# NO INVENTA UN VEREDICTO: mira tres cosas concretas por turno --
#   1. que no haya errores de shell (command not found, unbound variable, syntax error),
#   2. que el turno TERMINE con una respuesta y no con "no llegue a una respuesta final",
#   3. que la herramienta propia del modo se haya usado de verdad (aparece en el log).
#
# Uso:  bash tests/revision-motor-vivo.sh [modo...]     (sin argumentos: todos)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$HERE/engine/nv-modos-lib.sh"
SAL="$HERE/eval/revision-motor"; mkdir -p "$SAL"
RMV_TMP="$(mktemp -d)"; trap 'rm -rf "$RMV_TMP"' EXIT   # RMV_ y no TMP: ERR-002

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# Un video corto de verdad para el modo Editor: sin material, ese modo no se puede probar.
VIDEO="$RMV_TMP/muestra.mp4"
ffmpeg -y -v error -f lavfi -i testsrc2=size=640x360:rate=25:duration=8 \
       -f lavfi -i sine=frequency=440:duration=8 -c:v libx264 -preset ultrafast -c:a aac -shortest \
       "$VIDEO" 2>/dev/null
VIDEO_M="$(cygpath -m "$VIDEO" 2>/dev/null || printf '%s' "$VIDEO")"

# La tarea de cada modo pide justo lo que ese modo sabe hacer, y nada mas. Pedirle codigo a Study
# probaria que Study no programa, que ya lo prueba test-modos.sh sin gastar una llamada.
_tarea() {
  case "$1" in
    mentis)  echo "Decime en una sola linea que es la fotosintesis." ;;
    code)    echo "Escribi un archivo suma.sh que imprima la suma de 2 y 3, corrélo y decime que imprimio." ;;
    designe) echo "Genera un documento word de media pagina sobre el mate y decime donde quedo." ;;
    cowork)  echo "Armá dos listas en paralelo: una con 3 frutas y otra con 3 verduras, y dejalas en listas.md" ;;
    study)   echo "Segun el material que te di, ¿que es la fotosintesis? Cita el archivo." ;;
    science) echo "Calculá la media y la desviacion estandar de estos numeros: 2, 4, 4, 4, 5, 5, 7, 9. Mostrá la cuenta." ;;
    editor)  echo "Inspeccioná el video $VIDEO_M y decime cuanto dura, que resolucion tiene y si trae audio." ;;
    *)       echo "Decime hola en una linea." ;;
  esac
}

# La herramienta que ese modo TIENE que haber usado para resolver su tarea.
_herramienta_esperada() {
  case "$1" in
    code)    echo "exec" ;;
    designe) echo "gen" ;;
    science) echo "run|exec" ;;   # dentro de grep -E la barra sola alcanza
    editor)  echo "video" ;;
    *)       echo "" ;;
  esac
}

MODOS="${*:-$(bash "$LIB" lista | cut -f1)}"
echo "== revision del motor en vivo: $(echo $MODOS | wc -w) modo(s) =="
echo ""

for m in $MODOS; do
  echo "-- $(bash "$LIB" titulo "$m")"
  dir="$RMV_TMP/$m"; mkdir -p "$dir"
  log="$SAL/$m.txt"
  banderas="$(bash "$LIB" banderas "$m")"
  sin="$(bash "$LIB" sin-tools "$m")"
  tarea="$(_tarea "$m")"

  ini=$(date +%s)
  # shellcheck disable=SC2086
  MENTIS_MODO="$m" timeout 400 bash "$HERE/engine/nv-agent.sh" $banderas -n "$sin" -i 12 \
      -d "$dir" "$tarea" > "$log" 2>&1
  rc=$?
  seg=$(( $(date +%s) - ini ))

  if grep -qiE 'command not found|unbound variable|syntax error|unexpected token|bad array subscript' "$log"; then
    _mal "$m: sin errores de shell" "$(grep -iEm1 'command not found|unbound variable|syntax error|unexpected token|bad array subscript' "$log" | cut -c1-90)"
  else
    _ok "$m: sin errores de shell (${seg}s)"
  fi

  # Que haya TERMINADO: o el agente cerro con done, o hubo un cierre con respuesta.
  if grep -q 'no llegué a una respuesta final\|Reporte parcial honesto' "$log"; then
    _mal "$m: termina con respuesta" "el turno murio sin responder (rc=$rc)"
  elif [ "$rc" = "0" ] || grep -q 'iter.*: done' "$log"; then
    _ok "$m: el turno cierra con una respuesta"
  else
    _mal "$m: termina con respuesta" "rc=$rc y no aparece 'done' en el log"
  fi

  esperada="$(_herramienta_esperada "$m")"
  if [ -n "$esperada" ]; then
    if grep -qE "iter [0-9]+: ($esperada)" "$log"; then
      _ok "$m: uso su herramienta propia ($esperada)"
    else
      _mal "$m: usa su herramienta" "no aparece '$esperada' en el log -- resolvio de otra forma o no resolvio"
    fi
  fi
done

echo ""
printf 'revision-motor-vivo: %d ok, %d fallas\n' "$ok" "$fallo"
echo "Los logs completos quedaron en $SAL"
[ "$fallo" -eq 0 ]
