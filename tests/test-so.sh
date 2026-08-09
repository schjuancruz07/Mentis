#!/usr/bin/env bash
# test-so.sh -- el arnés que construye el sistema operativo.
#
# QUE SE PRUEBA Y POR QUE:
#   Un bucle autónomo que escribe código se puede envenenar solo de tres formas, y las tres tienen
#   su freno. Este test verifica LOS FRENOS, que es lo único que hace aceptable dejarlo correr:
#     1. que no pueda arreglar la prueba en vez del código,
#     2. que no pueda romper un hito que ya estaba verde,
#     3. que no pueda girar en falso gastando llamadas.
#   Y verifica lo que hace que el bucle converja: que un kernel que se cae produzca un diagnóstico
#   útil (archivo y línea) y no un silencio.
#
# Las partes que necesitan el compilador de RISC-V y qemu se saltean solas si no están: son ~1 GB
# de descargas y este test tiene que poder correr en una máquina limpia.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SO="$HERE/mentis-so.sh"
OK=0; FALLA=0
_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }
_salteo(){ echo "  --   -- (salteado) $1"; }

TS_TMP="$(mktemp -d)"
trap 'rm -rf "$TS_TMP" 2>/dev/null' EXIT
P="$TS_TMP/so"

echo "== mentis-so.sh: el constructor del sistema operativo =="

# --- 0. sintaxis ---------------------------------------------------------------------------------
for f in "$SO" "$HERE/engine/so-esqueleto.sh"; do
  if bash -n "$f" 2>/dev/null; then _ok "sintaxis ok: $(basename "$f")"; else _falla "sintaxis rota: $f"; fi
done

# --- 1. el esqueleto ------------------------------------------------------------------------------
echo "-- el esqueleto"
"$SO" nuevo "$P" >/dev/null 2>&1
for f in kernel/start.S kernel/hal.h kernel/hal_virt.c kernel/hal_tang.c kernel/trampa.c \
         kernel/virt.ld kernel/tang.ld pruebas/hito1.c pruebas/hito8.c.hito; do
  [ -f "$P/$f" ] || _falla "falta $f"
done
[ -f "$P/kernel/trampa.c" ] && _ok "el esqueleto trae el manejador de excepciones desde el hito 1"

# LA HAL DE DOS PLACAS: es lo que evita descubrir al final que nada anda en la FPGA.
if [ -f "$P/kernel/hal_virt.c" ] && [ -f "$P/kernel/hal_tang.c" ] && [ -f "$P/kernel/tang.ld" ]; then
  _ok "hay HAL y linker para las DOS placas (qemu y Tang Primer 20K) desde el principio"
else
  _falla "falta la capa de la segunda placa: iterar solo en qemu no transfiere a la FPGA"
fi

# La direccion de la UART no puede estar fuera de la HAL.
FUGAS=""
for f in "$P/kernel/comun.c" "$P/kernel/trampa.c"; do
  grep -qE '0x1000000|0x0200000' "$f" 2>/dev/null && FUGAS="$FUGAS $(basename "$f")"
done
if [ -z "$FUGAS" ]; then
  _ok "ninguna direccion de hardware se escapo fuera de la HAL"
else
  _falla "hay direcciones de hardware fuera de la HAL en:$FUGAS"
fi

# Los 8 hitos tienen prueba.
N_PRUEBAS="$(ls "$P/pruebas"/hito*.c 2>/dev/null | wc -l)"
if [ "$N_PRUEBAS" = "8" ]; then _ok "los 8 hitos tienen su prueba"; else _falla "hay $N_PRUEBAS pruebas, deberian ser 8"; fi

# --- 2. FRENO 1: las pruebas son de solo lectura -----------------------------------------------------
echo "-- freno 1: no se puede arreglar la prueba en vez del codigo"
[ -f "$P/pruebas/.huellas" ] && _ok "las pruebas quedaron selladas con su huella" || _falla "no se sellaron las pruebas"

cp "$P/pruebas/hito1.c" "$TS_TMP/hito1.original"
echo '/* modificado a mano */' >> "$P/pruebas/hito1.c"
SAL="$("$SO" avanzar "$P" 2>&1)"; RC=$?
if [ "$RC" = "4" ] || printf '%s' "$SAL" | grep -q "pruebas fueron modificadas"; then
  _ok "si una prueba cambia, el bucle CORTA"
elif [ "$RC" = "3" ]; then
  _salteo "faltan compilador/qemu; no se pudo llegar al chequeo de huellas"
else
  _falla "una prueba modificada no detuvo el bucle (exit $RC)"
fi
cp "$TS_TMP/hito1.original" "$P/pruebas/hito1.c"

# Y el estado de las huellas se refleja en 'hitos'.
echo '/* otra vez */' >> "$P/pruebas/hito2.c"
SAL="$("$SO" hitos "$P" 2>&1)"
printf '%s' "$SAL" | grep -q "modificadas" && _ok "'hitos' avisa si las pruebas fueron tocadas" || _falla "'hitos' no avisa de pruebas modificadas"
"$SO" nuevo "$TS_TMP/so2" >/dev/null 2>&1   # proyecto limpio para el resto
P2="$TS_TMP/so2"

# --- 3. el hito 8 no se puede fingir -------------------------------------------------------------------
echo "-- honestidad sobre lo que no se puede verificar"
SAL="$("$SO" probar "$P2" 8 2>&1)"; RC=$?
if printf '%s' "$SAL" | grep -qiE "NECESITA la placa|placa fisica" && [ "$RC" != "0" ]; then
  _ok "el hito de video NO se da por bueno en qemu: dice que necesita la placa"
elif [ "$RC" = "3" ]; then
  _salteo "faltan herramientas"
else
  _falla "el hito 8 no deberia poder darse por verde sin hardware (exit $RC)"
fi

# --- 4. avisos de herramientas faltantes ------------------------------------------------------------------
echo "-- herramientas"
TIENE_GCC=0; TIENE_QEMU=0
ls "$HOME/AppData/Roaming/xPacks/@xpack-dev-tools/riscv-none-elf-gcc"/*/.content/bin/riscv-none-elf-gcc.exe >/dev/null 2>&1 && TIENE_GCC=1
command -v riscv-none-elf-gcc >/dev/null 2>&1 && TIENE_GCC=1
[ -x "/c/Program Files/qemu/qemu-system-riscv32.exe" ] && TIENE_QEMU=1
command -v qemu-system-riscv32 >/dev/null 2>&1 && TIENE_QEMU=1

if [ "$TIENE_GCC" = "0" ] || [ "$TIENE_QEMU" = "0" ]; then
  SAL="$("$SO" probar "$P2" 1 2>&1)"; RC=$?
  if [ "$RC" = "3" ] && printf '%s' "$SAL" | grep -qE "winget install|xpm install"; then
    _ok "si falta el compilador o qemu, lo dice con el comando de instalacion"
  else
    _falla "no aviso bien de las herramientas faltantes (exit $RC)"
  fi
else
  _ok "el compilador de RISC-V y qemu estan instalados"
fi

# --- 5. EN VIVO: compilar y correr de verdad -----------------------------------------------------------------
echo "-- en vivo (compilar y arrancar el kernel)"
if [ "$TIENE_GCC" = "0" ] || [ "$TIENE_QEMU" = "0" ]; then
  _salteo "sin compilador de RISC-V y/o qemu no se puede probar el kernel de verdad"
else
  # El hito 1 tiene que pasar con el esqueleto tal cual sale: si el arranque base no funciona,
  # el modelo arrancaria depurando codigo que no escribio.
  SAL="$("$SO" probar "$P2" 1 2>&1)"; RC=$?
  if [ "$RC" = "0" ]; then
    _ok "el esqueleto arranca y pasa el hito 1 sin que nadie lo toque"
  else
    _falla "el esqueleto no pasa su propio hito 1 (exit $RC): $(printf '%s' "$SAL" | tail -4)"
  fi

  # El hito 2 (imprimir) tambien deberia salir del esqueleto: la HAL ya lo cubre.
  SAL="$("$SO" probar "$P2" 2 2>&1)"; RC=$?
  [ "$RC" = "0" ] && _ok "el hito 2 (imprimir por la UART) sale con la HAL del esqueleto" \
                  || _salteo "el hito 2 no pasa todavia (exit $RC) -- es trabajo del bucle"

  # LA PIEZA CLAVE: una caida tiene que producir un diagnostico util, no silencio.
  SAL="$("$SO" probar "$P2" 3 2>&1)"; RC=$?
  if printf '%s' "$SAL" | grep -q "EXCEPCION"; then
    _ok "cuando el kernel se cae, informa la excepcion en vez de quedarse mudo"
    if printf '%s' "$SAL" | grep -qE "mcause=|motivo"; then
      _ok "el diagnostico incluye el motivo de la excepcion"
    else
      _falla "la excepcion no dice por que"
    fi
    if printf '%s' "$SAL" | grep -q "la excepcion ocurrio en:"; then
      _ok "y traduce la direccion a archivo:linea (es lo que hace corregible el error)"
    else
      _salteo "no se pudo traducir la direccion a archivo:linea (falta addr2line)"
    fi
  else
    _falla "una caida no produjo diagnostico: el bucle iria a ciegas. Salida: $(printf '%s' "$SAL" | tail -4)"
  fi

  # Un kernel que se cuelga no puede colgar el arnes.
  cp "$P2/pruebas/hito1.c" "$TS_TMP/h1.bak"
  cat > "$P2/pruebas/hito1.c" <<'C'
#include "../kernel/hal.h"
void kmain(void) { hal_uart_init(); kputs("colgado a proposito\n"); for(;;){} }
C
  T0=$(date +%s)
  MENTIS_SO_QEMU_SEG=8 "$SO" probar "$P2" 1 >/dev/null 2>&1
  T1=$(date +%s)
  cp "$TS_TMP/h1.bak" "$P2/pruebas/hito1.c"
  if [ $((T1-T0)) -lt 30 ]; then
    _ok "un kernel colgado se corta por tiempo ($((T1-T0))s), no cuelga el arnes"
  else
    _falla "el arnes se quedo $((T1-T0))s con un kernel colgado"
  fi
fi

# --- 6. los frenos declarados siguen en el codigo ---------------------------------------------------------
echo "-- los tres frenos siguen puestos"
grep -q "_so_pruebas_intactas" "$SO" && _ok "freno 1: chequeo de huellas de las pruebas" || _falla "se perdio el chequeo de huellas"
grep -q "REGRESION" "$SO"            && _ok "freno 2: guardia de regresion sobre los hitos ya verdes" || _falla "se perdio la guardia de regresion"
grep -q "ESTANCADO"  "$SO"           && _ok "freno 3: corte por estancamiento" || _falla "se perdio el corte por estancamiento"
grep -q "mentis-deshacer.sh" "$SO"   && _ok "saca foto antes de dejar que el modelo toque archivos" || _falla "no saca foto antes de iterar"

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
