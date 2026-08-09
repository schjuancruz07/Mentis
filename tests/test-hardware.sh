#!/usr/bin/env bash
# test-hardware.sh -- mentis-hardware.sh, el despachador de cadenas de herramientas.
#
# REGLA DE ORO DE ESTE TEST: corre SIN NINGUNA PLACA CONECTADA y sin exigir que estén instaladas
# las 14 cadenas de herramientas. Un test que necesitara una FPGA sobre la mesa no lo podría
# correr nadie, y uno que necesitara 3 GB de toolchains daría rojo en una máquina limpia.
# Lo que se prueba es lo que tiene que andar siempre: que detecte bien, que NO descargue nada por
# su cuenta, y que cuando algo falta lo diga con el comando exacto en vez de un "command not found".
#
# Las partes que necesitan una herramienta real se saltean solas si no está.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HW="$HERE/mentis-hardware.sh"
OK=0; FALLA=0
_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }
_salteo(){ echo "  --   -- (salteado) $1"; }

TH_TMP="$(mktemp -d)"
trap 'rm -rf "$TH_TMP" 2>/dev/null' EXIT

# shellcheck source=/dev/null
source "$HERE/engine/hw-backends.sh"

echo "== mentis-hardware.sh =="

# --- 0. sintaxis ---------------------------------------------------------------------------------
for f in "$HW" "$HERE/engine/hw-backends.sh" "$HERE/engine/hw-fisico.sh" "$HERE/mentis-arduino.sh"; do
  if bash -n "$f" 2>/dev/null; then _ok "sintaxis ok: $(basename "$f")"; else _falla "sintaxis rota: $f"; fi
done

# --- 1. la tabla de backends esta completa ---------------------------------------------------------
echo "-- la tabla de backends"
N_BACK="$(hw_backends | grep -c.)"
if [ "$N_BACK" -ge 10 ]; then _ok "hay $N_BACK backends declarados"; else _falla "solo $N_BACK backends"; fi

# Cada backend tiene que tener los 6 campos. Uno vacio significa que, el dia que falte esa
# herramienta, el mensaje va a salir cojo justo cuando mas se necesita.
INCOMPLETOS=""
while IFS='|' read -r n b f c i t; do
  [ -n "$n" ] || continue
  for v in "$b" "$f" "$c" "$i" "$t"; do
    [ -z "$v" ] && { INCOMPLETOS="$INCOMPLETOS $n"; break; }
  done
done < <(hw_backends)
if [ -z "$INCOMPLETOS" ]; then
  _ok "todos los backends declaran binario, fase, para-que-sirve, como-instalar y tamano"
else
  _falla "backends con campos vacios:$INCOMPLETOS"
fi

# La fase solo puede ser 2A o 2B: es lo que le dice al usuario si algo necesita hardware o no.
MALFASE="$(hw_backends | awk -F'|' '$3 != "2A" && $3 != "2B" {print $1}')"
if [ -z "$MALFASE" ]; then _ok "todas las fases son 2A o 2B"; else _falla "fase invalida en: $MALFASE"; fi

# --- 2. backends: informa sin romper aunque no haya NADA instalado ----------------------------------
echo "-- el listado de backends"
SAL="$("$HW" backends 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then _ok "'backends' sale con codigo 0 aunque falten herramientas"; else _falla "'backends' salio con $RC"; fi
if printf '%s' "$SAL" | grep -q "Instaladas:"; then _ok "informa cuantas hay y cuantas faltan"; else _falla "no informa el resumen"; fi
# Lo que hace util al mensaje: el comando de instalacion.
if printf '%s' "$SAL" | grep -qE "pip install|winget install|oss-cad-suite"; then
  _ok "para lo que falta muestra el comando de instalacion"
else
  # Si estan TODAS instaladas no hay nada que mostrar, y eso no es una falla.
  if printf '%s' "$SAL" | grep -q "Faltan: 0"; then _ok "no falta ninguna herramienta"; else _falla "no muestra como instalar lo que falta"; fi
fi

# --- 3. placas: sin placa conectada NO es un error ---------------------------------------------------
echo "-- deteccion de placas"
SAL="$("$HW" placas 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then
  _ok "'placas' sale con codigo 0 aunque no haya nada conectado"
else
  _falla "'placas' salio con $RC sin placa conectada -- eso no es un error"
fi

# --- 4. NUNCA instala nada solo -----------------------------------------------------------------------
# Es la regla que protege la conexion y el disco del usuario. Se verifica que exista el aviso y que la
# salida sea 3 (distinguible de un fallo de compilacion, que es 1).
echo "-- nunca instala nada por su cuenta"
for b in yosys qemu-riscv laminador; do
  if hw_instalado "$b"; then
    _salteo "'$b' ya esta instalado; no se puede probar el aviso de faltante"
  else
    SAL="$(hw_backend_campo "$b" 5)"
    [ -n "$SAL" ] && _ok "'$b' declara como se instala: $SAL" || _falla "'$b' no dice como se instala"
  fi
done
# El texto del compromiso tiene que estar en el codigo, para que nadie lo saque sin darse cuenta.
if grep -q "No la instalo por mi cuenta" "$HW"; then
  _ok "el aviso de 'no instalo nada solo' sigue en el codigo"
else
  _falla "se perdio el aviso de que no instala nada solo"
fi
if grep -q "No la bajo solo" "$HW"; then
  _ok "PlatformIO tampoco puede bajarse la plataforma sin avisar"
else
  _falla "falta la guarda de descarga de plataformas de PlatformIO"
fi

# --- 5. crear proyectos ---------------------------------------------------------------------------------
echo "-- armar proyectos"
"$HW" nuevo "$TH_TMP/p_fpga" tang >/dev/null 2>&1
if [ -f "$TH_TMP/p_fpga/top.v" ] && [ -f "$TH_TMP/p_fpga/top_tb.v" ]; then
  _ok "proyecto de FPGA: crea el modulo Y su testbench"
else
  _falla "el proyecto de FPGA quedo incompleto"
fi
"$HW" nuevo "$TH_TMP/p_ard" uno >/dev/null 2>&1
if ls "$TH_TMP/p_ard"/*.ino >/dev/null 2>&1; then _ok "proyecto Arduino: crea el sketch"; else _falla "falta el.ino"; fi
"$HW" nuevo "$TH_TMP/p_pio" skr-mini-e3 >/dev/null 2>&1
if [ -f "$TH_TMP/p_pio/platformio.ini" ] && grep -q "STM32G0B1RE_btt" "$TH_TMP/p_pio/platformio.ini"; then
  _ok "proyecto de la impresora: platformio.ini con el entorno correcto de la SKR Mini E3 V3"
else
  _falla "el platformio.ini de la impresora esta mal"
fi
"$HW" nuevo "$TH_TMP/p_no" placa-que-no-existe >/dev/null 2>&1; RC=$?
if [ "$RC" != "0" ]; then _ok "una placa desconocida se rechaza"; else _falla "acepto una placa inexistente"; fi

# --- 6. SIMULAR: lo mas importante de la fase 2A ------------------------------------------------------
# Un simulador que dice OK a todo no sirve para nada. Se prueba con un diseno bueno y DOS rotos.
echo "-- simulacion (la parte que anda sin placa)"
if ! hw_instalado iverilog; then
  _salteo "iverilog no esta instalado; no se puede probar la simulacion"
else
  "$HW" simular "$TH_TMP/p_fpga" >/dev/null 2>&1; RC=$?
  if [ "$RC" = "0" ]; then _ok "un diseno correcto simula y sale con 0"; else _falla "el diseno de ejemplo no paso su propio testbench (exit $RC)"; fi

  # Roto A: no compila.
  cp -r "$TH_TMP/p_fpga" "$TH_TMP/p_rotoA"
  sed -i 's/assign led = cuenta\[23\];/assign led = cuenta[23]/' "$TH_TMP/p_rotoA/top.v"
  SAL="$("$HW" simular "$TH_TMP/p_rotoA" 2>&1)"; RC=$?
  if [ "$RC" != "0" ] && printf '%s' "$SAL" | grep -q "no compila"; then
    _ok "un Verilog que no compila da FALLO y devuelve los errores del compilador"
  else
    _falla "no detecto el Verilog roto (exit $RC)"
  fi

  # Roto B: compila pero el diseno esta mal. Es el caso que separa un simulador util de uno inutil.
  cp -r "$TH_TMP/p_fpga" "$TH_TMP/p_rotoB"
  sed -i "s/assign led = cuenta\[23\];/assign led = 1'b0;/" "$TH_TMP/p_rotoB/top.v"
  SAL="$("$HW" simular "$TH_TMP/p_rotoB" 2>&1)"; RC=$?
  if [ "$RC" != "0" ] && printf '%s' "$SAL" | grep -q "nunca cambio"; then
    _ok "un diseno que compila pero NO funciona tambien da FALLO"
  else
    _falla "un diseno roto que compila paso como bueno (exit $RC) -- el simulador no sirve asi"
  fi

  # Sin testbench no se puede afirmar nada, y hay que decirlo en vez de dar verde.
  mkdir -p "$TH_TMP/p_sintb" && cp "$TH_TMP/p_fpga/top.v" "$TH_TMP/p_sintb/"
  SAL="$("$HW" simular "$TH_TMP/p_sintb" 2>&1)"; RC=$?
  if [ "$RC" != "0" ]; then _ok "sin testbench no da verde (no hay nada que verificar)"; else _falla "sin testbench dio por bueno el diseno"; fi
fi

# --- 7. compilar de verdad -------------------------------------------------------------------------------
echo "-- compilacion"
if ! hw_instalado arduino-cli; then
  _salteo "arduino-cli no esta instalado"
else
  SAL="$("$HW" verificar "$TH_TMP/p_ard" 2>&1)"; RC=$?
  if [ "$RC" = "0" ]; then
    _ok "compila un sketch Arduino de verdad"
  elif [ "$RC" = "3" ]; then
    _salteo "falta el nucleo AVR (y avisa en vez de bajarlo solo, que es lo correcto)"
  else
    _falla "la compilacion Arduino fallo (exit $RC): $(printf '%s' "$SAL" | tail -2)"
  fi
fi
if hw_instalado platformio; then
  SAL="$("$HW" verificar "$TH_TMP/p_pio" 2>&1)"; RC=$?
  if [ "$RC" = "3" ] && printf '%s' "$SAL" | grep -q "No la bajo solo"; then
    _ok "PlatformIO sin la plataforma instalada avisa y NO descarga (exit 3)"
  elif [ "$RC" = "0" ]; then
    _ok "PlatformIO compila (la plataforma ya estaba instalada)"
  else
    _falla "PlatformIO salio con $RC de forma inesperada"
  fi
else
  _salteo "platformio no esta instalado"
fi

# --- 8. un proyecto que no se entiende no puede pasar por bueno ----------------------------------------------
mkdir -p "$TH_TMP/p_nada" && echo "hola" > "$TH_TMP/p_nada/leeme.txt"
"$HW" verificar "$TH_TMP/p_nada" >/dev/null 2>&1; RC=$?
if [ "$RC" != "0" ]; then _ok "una carpeta sin proyecto reconocible se rechaza"; else _falla "acepto una carpeta sin proyecto"; fi

# --- 9. el puente desde el nombre viejo ----------------------------------------------------------------------
echo "-- compatibilidad con mentis-arduino.sh"
SAL="$("$HERE/mentis-arduino.sh" boards 2>&1)"; RC=$?
if [ "$RC" = "0" ] && printf '%s' "$SAL" | grep -q "reenviando a"; then
  _ok "mentis-arduino.sh sigue funcionando y reenvia al despachador nuevo"
else
  _falla "el puente desde el nombre viejo no funciona (exit $RC)"
fi

# --- 10. el agente ve las herramientas nuevas ------------------------------------------------------------------
echo "-- integracion con el agente"
if grep -q 'tool\\":\\"hardware' "$HERE/engine/nv-agent.sh"; then
  _ok "nv-agent.sh le ofrece al modelo la herramienta 'hardware'"
else
  _falla "nv-agent.sh no declara la herramienta 'hardware'"
fi
if grep -q 'arduino|hardware)' "$HERE/engine/nv-agent.sh"; then
  _ok "el nombre viejo 'arduino' se sigue aceptando"
else
  _falla "se perdio la compatibilidad con el nombre de tool viejo"
fi
# Que una herramienta falte no puede reportarse como un fallo del modelo.
if grep -q 'falta una herramienta' "$HERE/engine/nv-agent.sh"; then
  _ok "'falta una herramienta' se distingue de 'la accion fallo'"
else
  _falla "el agente confunde herramienta faltante con accion fallida"
fi

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
