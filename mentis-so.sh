#!/usr/bin/env bash
# mentis-so.sh -- Mentis construye un sistema operativo: prueba, error, corrección, sigue.
#
# LA IDEA:
#   Ocho hitos, cada uno con una prueba que se verifica sola. El bucle avanza sólo cuando la
#   prueba se pone verde. El modelo escribe el código; ESTE arnés juzga. Nunca al revés.
#
# POR QUE EL ARNES ES DETERMINISTICO Y EL MODELO NO DECIDE NADA:
#   Un bucle "compilá, corré, corregí" sobre bare-metal RISC-V falla siempre por lo mismo: cuando
#   el kernel muere, no imprime nada. El modelo recibe "no hubo salida", que no dice nada, y
#   empieza a probar al azar. Por eso acá:
#     - El esqueleto trae un manejador de excepciones desde el primer hito, que convierte una
#       caída muda en "fallo de escritura (mcause=7) en mepc=0x80001234".
#     - Esa dirección se traduce a archivo:línea con addr2line antes de dársela al modelo.
#     - qemu corre SIEMPRE con techo de tiempo y se apaga solo por el dispositivo de salida: un
#       qemu colgado es el otro modo de falla clásico.
#
# LOS TRES FRENOS (sin ellos un bucle autónomo se envenena):
#   1. Las pruebas son de SOLO LECTURA. El modo de falla más común no es rendirse: es arreglar la
#      prueba en vez del código. Se les toma la huella antes de cada iteración; si cambian, corta.
#   2. Guardia de regresión: después de cada iteración se corren TODOS los hitos ya conseguidos.
#      Si algo que estaba verde se rompió, vuelve atrás solo.
#   3. Corte por estancamiento: si N iteraciones seguidas no cambian nada, para y reporta.
#
# Uso:
#   mentis-so.sh nuevo <carpeta>              arma el proyecto (esqueleto + pruebas + HAL)
#   mentis-so.sh hitos <carpeta>              en qué anda cada hito
#   mentis-so.sh probar <carpeta> [n]         corre la prueba de un hito (o del actual)
#   mentis-so.sh avanzar <carpeta> [-i N]     el bucle: hasta que el hito actual se ponga verde
#   mentis-so.sh revertir <carpeta>           vuelve a la última foto buena
set -uo pipefail
export PYTHONIOENCODING=utf-8

SO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SO_NVDIR="$SO_HERE/engine"
# shellcheck source=/dev/null
source "$SO_NVDIR/nv-lib.sh"
# shellcheck source=/dev/null
source "$SO_NVDIR/hw-backends.sh"
# shellcheck source=/dev/null
source "$SO_NVDIR/so-esqueleto.sh"

SO_HITOS_TOTAL=8
SO_MAX_ITER="${MENTIS_SO_MAX_ITER:-8}"
SO_ESTANCADO="${MENTIS_SO_ESTANCADO:-3}"
SO_QEMU_SEG="${MENTIS_SO_QEMU_SEG:-25}"

_so_die() { echo "ERROR: $1" >&2; exit 1; }

_so_nombre_hito() {
  case "$1" in
    1) echo "arranca sin caerse" ;;
    2) echo "imprime por la UART" ;;
    3) echo "el manejador de excepciones funciona" ;;
    4) echo "memoria: reservar y liberar" ;;
    5) echo "interrupciones de reloj" ;;
    6) echo "dos tareas que se alternan" ;;
    7) echo "entrada por la UART" ;;
    8) echo "video HDMI (NECESITA LA PLACA)" ;;
    *) echo "?" ;;
  esac
}

# --- herramientas: se avisa que falta y como se instala, nunca un "command not found" ---------
_so_gcc() {
  local c
  for c in riscv-none-elf-gcc riscv64-unknown-elf-gcc riscv32-unknown-elf-gcc; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
  done
  for c in "$HOME/AppData/Roaming/xPacks/@xpack-dev-tools/riscv-none-elf-gcc"/*/.content/bin/riscv-none-elf-gcc.exe; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

_so_qemu() {
  command -v qemu-system-riscv32 >/dev/null 2>&1 && { command -v qemu-system-riscv32; return 0; }
  [ -x "/c/Program Files/qemu/qemu-system-riscv32.exe" ] && { printf '%s' "/c/Program Files/qemu/qemu-system-riscv32.exe"; return 0; }
  return 1
}

_so_addr2line() {
  local g; g="$(_so_gcc)" || return 1
  local a="${g%gcc*}addr2line.exe"
  [ -x "$a" ] && { printf '%s' "$a"; return 0; }
  a="$(dirname "$g")/riscv-none-elf-addr2line.exe"
  [ -x "$a" ] && { printf '%s' "$a"; return 0; }
  return 1
}

_so_faltan_herramientas() {
  local falta=0
  if ! _so_gcc >/dev/null; then
    echo "Falta el compilador de RISC-V."
    echo "  Se instala con : npm i -g xpm && xpm install -g @xpack-dev-tools/riscv-none-elf-gcc"
    echo "  Ocupa          : ~700 MB"
    falta=1
  fi
  if ! _so_qemu >/dev/null; then
    echo "Falta qemu para RISC-V (es lo que corre el sistema operativo sin la placa)."
    echo "  Se instala con : winget install SoftwareFreedomConservancy.QEMU"
    echo "  Ocupa          : ~400 MB"
    falta=1
  fi
  [ "$falta" = "0" ] && return 0
  echo
  echo "No las instalo por mi cuenta: son descargas grandes y la decision es tuya."
  return 1
}

# --- huellas de las pruebas: el modelo NO puede tocarlas ----------------------------------------
_so_huellas() { ( cd "$1/pruebas" 2>/dev/null && ls *.c 2>/dev/null | sort | while read -r f; do printf '%s %s\n' "$(sha1sum "$f" | cut -d' ' -f1)" "$f"; done ) }
_so_sellar_pruebas()  { _so_huellas "$1" > "$1/pruebas/.huellas"; }
_so_pruebas_intactas() {
  [ -f "$1/pruebas/.huellas" ] || return 0
  local ahora esperado
  ahora="$(_so_huellas "$1")"; esperado="$(cat "$1/pruebas/.huellas")"
  [ "$ahora" = "$esperado" ]
}

# --- compilar y correr un hito -------------------------------------------------------------------
# Imprime la salida cruda; devuelve 0 si el hito paso, 1 si no, 2 si no compila.
_so_correr_hito() {
  local d="$1" n="$2" placa="${3:-virt}"
  local gcc qemu elf salida
  gcc="$(_so_gcc)" || return 3
  qemu="$(_so_qemu)" || return 3
  elf="$d/.build/hito$n.elf"
  mkdir -p "$d/.build" 2>/dev/null

  local fuentes=("$d/kernel/start.S" "$d/kernel/comun.c" "$d/kernel/trampa.c" "$d/kernel/hal_$placa.c")
  local f
  for f in "$d/kernel"/*.c; do
    case "$(basename "$f")" in
      comun.c|trampa.c|hal_virt.c|hal_tang.c) : ;;
      *) fuentes+=("$f") ;;
    esac
  done
  fuentes+=("$d/pruebas/hito$n.c")

  local errc
  errc="$("$gcc" -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
        -O1 -g -Wall -T "$d/kernel/$placa.ld" -o "$elf" "${fuentes[@]}" 2>&1)"
  if [ $? -ne 0 ]; then
    printf '%s\n' "$errc"
    return 2
  fi

  # Techo de tiempo SIEMPRE: un kernel en bucle infinito no puede colgar el arnes.
  salida="$(timeout "$SO_QEMU_SEG" "$qemu" -machine virt -bios none -nographic \
             -serial mon:stdio -kernel "$elf" 2>&1 </dev/null)"
  local rc=$?
  printf '%s\n' "$salida"
  if [ $rc -eq 124 ]; then
    echo "(el arnes corto qemu a los ${SO_QEMU_SEG}s: el kernel no termino solo)"
    return 1
  fi
  # El hito 3 se juzga distinto, y hay un motivo: prueba que el manejador de excepciones FUNCIONE,
  # y para eso provoca una excepcion a proposito. Como el manejador -- correctamente -- detiene la
  # ejecucion, el codigo nunca llega a imprimir "HITO3: OK". Buscar esa linea castigaria justo el
  # comportamiento que se quiere. Lo que prueba el exito acá es el informe de la excepcion en si.
  if [ "$n" = "3" ]; then
    printf '%s' "$salida" | grep -q "EXCEPCION" \
      && printf '%s' "$salida" | grep -qE "mcause=[0-9]+" \
      && ! printf '%s' "$salida" | grep -q "HITO3: FALLO" \
      && return 0
    return 1
  fi
  printf '%s' "$salida" | grep -q "HITO$n: OK" && return 0
  return 1
}

# Traduce las direcciones de una excepcion a archivo:linea. Es lo que convierte un volcado
# ilegible en algo accionable.
_so_explicar() {
  local d="$1" n="$2" texto="$3" a2l elf epc
  printf '%s' "$texto" | grep -q "EXCEPCION" || return 0
  a2l="$(_so_addr2line)" || return 0
  elf="$d/.build/hito$n.elf"
  [ -f "$elf" ] || return 0
  epc="$(printf '%s' "$texto" | grep -oE 'mepc[[:space:]]*:[[:space:]]*0x[0-9a-f]+' | grep -oE '0x[0-9a-f]+' | head -1)"
  [ -n "$epc" ] || return 0
  local donde; donde="$("$a2l" -e "$elf" -f -p "$epc" 2>/dev/null | tr -d '\r')"
  [ -n "$donde" ] && echo "  -> la excepcion ocurrio en: $donde"
}

SO_CMD="${1:-}"; shift || true

case "$SO_CMD" in

nuevo)
  D="${1:-}"; [ -n "$D" ] || _so_die "uso: mentis-so.sh nuevo <carpeta>"
  [ -e "$D/kernel" ] && _so_die "ya existe un proyecto en $D"
  so_escribir_esqueleto "$D" || _so_die "no pude crear el esqueleto"
  _so_sellar_pruebas "$D"
  echo "1" > "$D/.hito"
  cat > "$D/LEEME.md" <<'MD'
# Sistema operativo RISC-V

Ocho hitos. Cada uno tiene su prueba en `pruebas/`, que **no se toca**: son del arnés, y si
cambian, el bucle se detiene. Lo que se escribe es lo de `kernel/`.

- `mentis-so.sh hitos.`    en qué anda cada hito
- `mentis-so.sh probar.`   corre la prueba del hito actual
- `mentis-so.sh avanzar.`  el bucle hasta que el hito actual se ponga verde

Lo único que cambia entre qemu y la FPGA es `kernel/hal_virt.c` / `kernel/hal_tang.c` y su linker
script. Todo lo demás se escribe una sola vez.
MD
  echo "Proyecto creado en $D"
  echo "  kernel/   -> lo que hay que escribir (arranque, HAL, manejador de excepciones ya puestos)"
  echo "  pruebas/  -> las 8 pruebas, selladas: si cambian, el bucle corta"
  echo
  echo "Empeza con:  mentis-so.sh probar $D"
  exit 0
  ;;

hitos)
  D="${1:-.}"; [ -d "$D/pruebas" ] || _so_die "no hay proyecto en $D"
  ACTUAL="$(cat "$D/.hito" 2>/dev/null || echo 1)"
  echo "Hito actual: $ACTUAL"
  echo
  for n in $(seq 1 $SO_HITOS_TOTAL); do
    if [ "$n" -lt "$ACTUAL" ]; then est="verde"; elif [ "$n" = "$ACTUAL" ]; then est="EN CURSO"; else est="-"; fi
    printf '  %s. %-10s %s\n' "$n" "$est" "$(_so_nombre_hito "$n")"
  done
  echo
  _so_pruebas_intactas "$D" || echo "AVISO: las pruebas fueron modificadas respecto de su huella original."
  exit 0
  ;;

probar)
  D="${1:-.}"; N="${2:-}"
  [ -d "$D/pruebas" ] || _so_die "no hay proyecto en $D"
  _so_faltan_herramientas || exit 3
  [ -n "$N" ] || N="$(cat "$D/.hito" 2>/dev/null || echo 1)"
  if [ "$N" = "8" ]; then
    echo "El hito 8 (video HDMI) NECESITA la placa fisica: no se puede verificar en qemu."
    echo "No lo doy por bueno ni por malo -- queda pendiente para cuando exista el hardware."
    exit 2
  fi
  echo "== Hito $N: $(_so_nombre_hito "$N") =="
  SALIDA="$(_so_correr_hito "$D" "$N")"; RC=$?
  printf '%s\n' "$SALIDA"
  _so_explicar "$D" "$N" "$SALIDA"
  case $RC in
    0) echo "== VERDE ==" ;;
    2) echo "== NO COMPILA ==" ;;
    3) echo "== faltan herramientas ==" ;;
    *) echo "== ROJO ==" ;;
  esac
  exit $RC
  ;;

avanzar)
  D="${1:-.}"; shift || true
  ITER="$SO_MAX_ITER"
  while getopts ":i:" o; do case "$o" in i) ITER="$OPTARG" ;; *) : ;; esac; done
  [ -d "$D/pruebas" ] || _so_die "no hay proyecto en $D"
  _so_faltan_herramientas || exit 3
  N="$(cat "$D/.hito" 2>/dev/null || echo 1)"
  [ "$N" -gt "$SO_HITOS_TOTAL" ] && { echo "Ya estan todos los hitos."; exit 0; }
  if [ "$N" = "8" ]; then
    echo "El hito 8 necesita la placa fisica. No hay nada que iterar en qemu."
    exit 2
  fi

  AGENTE="$SO_NVDIR/nv-agent.sh"
  [ -f "$AGENTE" ] || _so_die "falta nv-agent.sh"

  echo "== Hito $N: $(_so_nombre_hito "$N") -- hasta $ITER intentos =="
  ULTIMO_ERROR=""; IGUALES=0

  for i in $(seq 1 "$ITER"); do
    # FRENO 1: las pruebas no se tocan.
    if ! _so_pruebas_intactas "$D"; then
      echo
      echo "CORTO: las pruebas fueron modificadas."
      echo "Las pruebas son del arnes, no del codigo a escribir. Si se pueden cambiar, el bucle"
      echo "deja de medir nada: se 'arregla' la prueba en vez del kernel."
      echo "Revisalas a mano; si el cambio es correcto, resellalas borrando pruebas/.huellas."
      exit 4
    fi

    SALIDA="$(_so_correr_hito "$D" "$N")"; RC=$?
    if [ $RC -eq 0 ]; then
      echo
      echo "== HITO $N VERDE (intento $i) =="
      # FRENO 2: no romper lo que ya andaba.
      REGRESION=""
      for p in $(seq 1 $((N-1))); do
        _so_correr_hito "$D" "$p" >/dev/null 2>&1 || REGRESION="$REGRESION $p"
      done
      if [ -n "$REGRESION" ]; then
        echo "PERO se rompieron hitos que ya estaban verdes:$REGRESION"
        echo "No avanzo. Hay que arreglar la regresion primero."
        exit 5
      fi
      echo $((N+1)) > "$D/.hito"
      echo "Siguiente: hito $((N+1)) -- $(_so_nombre_hito $((N+1)))"
      exit 0
    fi

    EXPLICACION="$(_so_explicar "$D" "$N" "$SALIDA")"
    echo "-- intento $i: rojo"
    printf '%s\n' "$SALIDA" | tail -6
    [ -n "$EXPLICACION" ] && echo "$EXPLICACION"

    # FRENO 3: si el error no cambia, no se esta avanzando.
    FIRMA="$(printf '%s' "$SALIDA" | tail -5 | sha1sum | cut -d' ' -f1)"
    if [ "$FIRMA" = "$ULTIMO_ERROR" ]; then
      IGUALES=$((IGUALES+1))
      if [ "$IGUALES" -ge "$SO_ESTANCADO" ]; then
        echo
        echo "CORTO: $IGUALES intentos con el MISMO error. No esta avanzando."
        echo "Seguir gastaria llamadas sin acercarse. El ultimo error fue:"
        printf '%s\n' "$SALIDA" | tail -8
        exit 6
      fi
    else
      IGUALES=0; ULTIMO_ERROR="$FIRMA"
    fi

    # Foto antes de dejar que el modelo toque nada.
    bash "$SO_HERE/mentis-deshacer.sh" foto "$D" "antes del intento $i del hito $N" >/dev/null 2>&1 || true

    TAREA="Estas escribiendo un sistema operativo bare-metal para RISC-V (rv32imac) que corre en qemu -machine virt.

HITO ACTUAL ($N): $(_so_nombre_hito "$N")
La prueba de este hito esta en pruebas/hito$N.c y es DE SOLO LECTURA: no la edites, no la borres,
no la muevas. Si la tocas, el sistema corta. Lo que hay que escribir o corregir esta en kernel/.

Lo que paso al correr la prueba:
---
$(printf '%s' "$SALIDA" | tail -25)
$EXPLICACION
---

Reglas del codigo:
- Nada de biblioteca estandar de C: no hay stdio, ni malloc, ni string.h. Solo lo que este en kernel/.
- Todo lo especifico de la placa va en kernel/hal_virt.c y kernel/hal_tang.c, detras de kernel/hal.h.
  Si metes una direccion de hardware en cualquier otro archivo, el dia que exista la FPGA no arranca.
- kernel/start.S y kernel/trampa.c ya andan: el manejador de excepciones es lo que hace que un
  fallo se pueda diagnosticar. No los rompas.
- Escribi el codigo minimo que haga pasar la prueba de ESTE hito. Nada de adelantarse a los que vienen.

Usa write para crear o reemplazar archivos dentro de kernel/. Cuando termines, usa done."

    echo "   (pensando...)"
    bash "$AGENTE" -d "$D" -m code -i 14 -w "$TAREA" >/dev/null 2>&1 || true
  done

  echo
  echo "Se agotaron los $ITER intentos sin poner verde el hito $N."
  echo "Volve a correr 'avanzar' para seguir, o mira el error a mano con 'probar'."
  exit 1
  ;;

revertir)
  D="${1:-.}"; [ -d "$D" ] || _so_die "no existe $D"
  bash "$SO_HERE/mentis-deshacer.sh" listar "$D"
  echo
  echo "Para volver a una:  mentis-deshacer.sh volver $D <id>"
  exit 0
  ;;

""|-h|--help|ayuda)
  sed -n '2,40p' "$0"
  exit 0
  ;;

*)
  _so_die "comando desconocido: '$SO_CMD'"
  ;;
esac
