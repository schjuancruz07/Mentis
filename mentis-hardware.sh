#!/usr/bin/env bash
# mentis-hardware.sh -- una sola forma de pedirle a Mentis que programe cualquier hardware.
#
# REEMPLAZA a mentis-arduino.sh, que sabía hacer cuatro cosas con arduino-cli y nada más. El
# objetivo del usuario es construir su propia tecnología: una computadora RISC-V sobre FPGA, una
# interfaz 3D y una impresora 3D. Eso son seis cadenas de herramientas distintas, y aprenderse
# seis interfaces distintas sería el verdadero obstáculo. Acá hay UN juego de verbos: los mismos
# para un Arduino, una FPGA o la impresora. Lo que cambia por debajo es el backend.
#
# EL EJE DEL DISEÑO -- CON PLACA vs SIN PLACA:
#   Todo lo que se puede simular es verificable HOY, sin comprar nada: escribir Verilog y correr
#   su testbench, compilar el kernel RISC-V y arrancarlo en qemu, compilar el firmware de la
#   impresora, laminar un modelo. Eso es la fase 2A y es donde una IA de verdad aporta, porque
#   puede leer el resultado y corregirse sola.
#   Lo que necesita la placa fisica (cargar la FPGA, flashear, imprimir) es la fase 2B: está
#   cableado y listo, y se verifica cuando el hardware exista.
#
# NUNCA INSTALA NADA SOLO. Un `verificar` de una placa nueva puede bajarse cientos de megas sin
# avisar. Acá, si falta una herramienta, se dice cuál, con qué comando se instala y cuánto ocupa.
#
# Uso:
#   mentis-hardware.sh backends                      que hay instalado y que falta
#   mentis-hardware.sh placas                        que hay conectado por USB ahora
#   mentis-hardware.sh nuevo <carpeta> <placa>       arma un proyecto listo para compilar
#   mentis-hardware.sh verificar <proyecto> [placa]  compila de verdad
#   mentis-hardware.sh simular <archivo.v|proyecto>  corre el testbench SIN placa
#   mentis-hardware.sh laminar <modelo.stl> [salida] modelo 3D -> G-code
#   mentis-hardware.sh subir <proyecto> [placa]      graba en la placa real   (2B)
#   mentis-hardware.sh monitor <puerto> [segundos]   lee el puerto serie      (2B)
#   mentis-hardware.sh bibliotecas <buscar|instalar> <nombre>
#   mentis-hardware.sh respaldar <puerto> <salida.bin>   copia la flash antes de pisarla (2B)
set -uo pipefail
export PYTHONIOENCODING=utf-8

HW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HW_HERE/engine/hw-backends.sh"

_hw_die()  { echo "ERROR: $1" >&2; exit 1; }
_hw_info() { echo "$*"; }

# Falta una herramienta: se dice CUAL, COMO se instala y CUANTO ocupa. Nunca un "command not found".
_hw_falta() {
  local b="$1"
  echo "Falta la herramienta '$b'."
  echo "  Para que sirve : $(hw_backend_campo "$b" 4)"
  echo "  Se instala con : $(hw_backend_campo "$b" 5)"
  echo "  Ocupa          : $(hw_backend_campo "$b" 6)"
  echo
  echo "No la instalo por mi cuenta a proposito: son descargas grandes y la decision es tuya."
  return 1
}

_hw_requiere() {
  local b="$1"
  hw_instalado "$b" && return 0
  _hw_falta "$b"
  exit 3
}

# --- que placa es esto: del nombre corto al backend + identificador real --------------------
# Un "alias" corto para que nadie tenga que recordar un FQBN. Formato: backend|identificador
_hw_placa() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    uno|arduino-uno)            echo "arduino-cli|arduino:avr:uno" ;;
    nano|arduino-nano)          echo "arduino-cli|arduino:avr:nano" ;;
    mega|arduino-mega)          echo "arduino-cli|arduino:avr:mega" ;;
    esp32)                      echo "arduino-cli|esp32:esp32:esp32" ;;
    esp8266)                    echo "arduino-cli|esp8266:esp8266:generic" ;;
    pico|rp2040)                echo "platformio|raspberrypi/pico" ;;
    skr-mini-e3|impresora)      echo "platformio|STM32G0B1RE_btt" ;;
    bluepill|stm32)             echo "platformio|bluepill_f103c8" ;;
    tang-primer-20k|tang|fpga)  echo "yosys|GW2A-18" ;;
    micropython-pico)           echo "mpremote|rp2" ;;
    *)                          echo "" ;;
  esac
}

_hw_placas_conocidas() {
  echo "uno nano mega esp32 esp8266 pico skr-mini-e3 bluepill tang-primer-20k micropython-pico"
}

# ============================================================================================
CMD="${1:-}"; shift || true

case "$CMD" in

# --- que tengo y que me falta ---------------------------------------------------------------
backends)
  printf '%-16s %-6s %-4s %s\n' "HERRAMIENTA" "ESTADO" "FASE" "PARA QUE SIRVE"
  printf '%s\n' "--------------------------------------------------------------------------------------------"
  FALTAN=0; HAY=0
  while IFS='|' read -r nombre _bin fase cubre _inst _tam; do
    [ -n "$nombre" ] || continue
    if hw_instalado "$nombre"; then est="ok"; HAY=$((HAY+1)); else est="FALTA"; FALTAN=$((FALTAN+1)); fi
    printf '%-16s %-6s %-4s %s\n' "$nombre" "$est" "$fase" "$cubre"
  done < <(hw_backends)
  echo
  echo "Instaladas: $HAY.  Faltan: $FALTAN."
  if [ "$FALTAN" -gt 0 ]; then
    echo
    echo "Como instalar las que faltan (ninguna se instala sola):"
    while IFS='|' read -r nombre _bin _fase _cubre inst tam; do
      [ -n "$nombre" ] || continue
      hw_instalado "$nombre" || printf '  %-16s %s\n%-18s (%s)\n' "$nombre" "$inst" "" "$tam"
    done < <(hw_backends)
  fi
  echo
  echo "Fase 2A = anda sin ninguna placa conectada.  Fase 2B = necesita el hardware fisico."
  exit 0
  ;;

# --- que hay conectado ------------------------------------------------------------------------
placas)
  ENCONTRE=0
  if hw_instalado arduino-cli; then
    ACLI="$(hw_binario_de arduino-cli)"
    SALIDA="$("$ACLI" board list --format json 2>/dev/null)"
    if [ -n "$SALIDA" ]; then
      DETALLE="$(printf '%s' "$SALIDA" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in d.get("detected_ports") or []:
    port = p.get("port") or {}
    addr = port.get("address", "?")
    props = port.get("properties") or {}
    vid, pid = props.get("vid", ""), props.get("pid", "")
    ident = (" [VID:PID %s:%s]" % (vid, pid)) if vid else ""
    matched = p.get("matched_boards") or []
    if matched:
        for b in matched:
            print("PLACA|%s|%s|%s%s" % (addr, b.get("name", "?"), b.get("fqbn", "?"), ident))
    else:
        print("PUERTO|%s|%s|%s" % (addr, port.get("protocol_label", "?"), ident))
' 2>/dev/null | tr -d '\r')"
      if [ -n "$DETALLE" ]; then
        while IFS='|' read -r tipo addr a b; do
          [ -n "$tipo" ] || continue
          if [ "$tipo" = "PLACA" ]; then
            echo "  $addr  --  $a  (identificador: $b)"; ENCONTRE=1
          else
            echo "  $addr  --  puerto serie sin placa reconocida (protocolo: $a)$b"
          fi
        done <<< "$DETALLE"
      fi
    fi
  fi
  # Herramientas que ven placas que arduino-cli no reconoce.
  if hw_instalado esptool; then
    echo "  (esptool disponible: puede identificar un ESP aunque arduino-cli no lo reconozca)"
  fi
  if [ "$ENCONTRE" = "0" ]; then
    echo
    echo "No hay ninguna placa reconocida conectada ahora mismo."
    hw_instalado arduino-cli || echo "(Ademas falta arduino-cli, que es lo que detecta las placas: mentis-hardware.sh backends)"
    echo "Esto NO es un error: casi todo lo de fase 2A (simular, compilar, laminar) anda sin placa."
  fi
  exit 0
  ;;

# --- armar un proyecto listo para compilar ------------------------------------------------------
nuevo)
  DEST="${1:-}"; PLACA="${2:-}"
  [ -n "$DEST" ] && [ -n "$PLACA" ] || _hw_die "uso: mentis-hardware.sh nuevo <carpeta> <placa>. Placas: $(_hw_placas_conocidas)"
  RESUELTA="$(_hw_placa "$PLACA")"
  [ -n "$RESUELTA" ] || _hw_die "no conozco la placa '$PLACA'. Conocidas: $(_hw_placas_conocidas)"
  BACKEND="${RESUELTA%%|*}"; IDENT="${RESUELTA##*|}"
  mkdir -p "$DEST" || _hw_die "no pude crear $DEST"
  NOMBRE="$(basename "$DEST")"

  case "$BACKEND" in
    arduino-cli)
      mkdir -p "$DEST"
      cat > "$DEST/$NOMBRE.ino" <<'INO'
// Esqueleto minimo. setup() corre una vez al encender; loop() se repite para siempre.
void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  digitalWrite(LED_BUILTIN, HIGH);
  delay(500);
  digitalWrite(LED_BUILTIN, LOW);
  delay(500);
  Serial.println("vivo");
}
INO
      echo "$IDENT" > "$DEST/.placa"
      _hw_info "Proyecto Arduino creado en $DEST (placa $IDENT)."
      _hw_info "Compilalo con:  mentis-hardware.sh verificar $DEST"
      ;;
    platformio)
      cat > "$DEST/platformio.ini" <<INI
; Generado por mentis-hardware.sh
[env:$IDENT]
platform = ststm32
board = $IDENT
framework = arduino
monitor_speed = 115200
INI
      mkdir -p "$DEST/src"
      cat > "$DEST/src/main.cpp" <<'CPP'
#include <Arduino.h>

void setup() {
  Serial.begin(115200);
}

void loop() {
  Serial.println("vivo");
  delay(1000);
}
CPP
      _hw_info "Proyecto PlatformIO creado en $DEST (entorno $IDENT)."
      _hw_info "Compilalo con:  mentis-hardware.sh verificar $DEST"
      ;;
    yosys)
      # Proyecto de FPGA: un modulo y su testbench. El testbench es lo que permite SIMULAR sin
      # tener la placa -- es la parte que de verdad se puede iterar hoy.
      cat > "$DEST/top.v" <<'V'
// Modulo de ejemplo: un contador que parpadea un LED.
module top (
    input  wire clk,
    output wire led
);
    reg [23:0] cuenta = 0;
    always @(posedge clk) cuenta <= cuenta + 1;
    assign led = cuenta[23];
endmodule
V
      cat > "$DEST/top_tb.v" <<'V'
// Testbench: NO necesita placa. Simula el reloj y verifica que el LED cambie de estado.
// La linea que empieza con "RESULTADO:" es lo que lee mentis-hardware.sh para decidir si paso.
`timescale 1ns/1ps
module top_tb;
    reg clk = 0;
    wire led;
    integer cambios = 0;
    reg previo;

    top dut (.clk(clk),.led(led));

    always #5 clk = ~clk;

    initial begin
        previo = led;
        #200000000;
        if (cambios > 0) $display("RESULTADO: OK -- el led cambio %0d vez/veces", cambios);
        else             $display("RESULTADO: FALLO -- el led nunca cambio de estado");
        $finish;
    end

    always @(led) begin
        if (led !== previo) begin
            cambios = cambios + 1;
            previo = led;
        end
    end
endmodule
V
      echo "$IDENT" > "$DEST/.placa"
      _hw_info "Proyecto de FPGA creado en $DEST (familia $IDENT, Tang Primer 20K)."
      _hw_info "Simulalo SIN placa con:  mentis-hardware.sh simular $DEST"
      ;;
    mpremote)
      cat > "$DEST/main.py" <<'PY'
# MicroPython: esto corre solo al encender la placa.
import time
from machine import Pin

led = Pin("LED", Pin.OUT)
while True:
    led.toggle()
    print("vivo")
    time.sleep(0.5)
PY
      _hw_info "Proyecto MicroPython creado en $DEST."
      _hw_info "Se sube con:  mentis-hardware.sh subir $DEST $PLACA   (necesita la placa conectada)"
      ;;
    *) _hw_die "no se armar un proyecto para el backend '$BACKEND'." ;;
  esac
  exit 0
  ;;

# --- compilar de verdad --------------------------------------------------------------------------
verificar)
  PROY="${1:-}"; PLACA="${2:-}"
  [ -n "$PROY" ] || _hw_die "uso: mentis-hardware.sh verificar <proyecto> [placa]"
  [ -e "$PROY" ] || _hw_die "no existe: $PROY"

  # Que tipo de proyecto es, mirando lo que hay adentro.
  if [ -f "$PROY/platformio.ini" ]; then
    _hw_requiere platformio
    PIO="$(hw_binario_de platformio)"
    # PlatformIO se baja la plataforma de la placa SOLO Y SIN AVISAR la primera vez: entre 200 MB
    # y 1 GB segun la placa. Un `verificar` que parece gratis no puede tragarse eso a espaldas de
    # el usuario, asi que primero se mira si ya esta y, si no, se dice el comando y el tamano.
    PLAT="$(grep -E '^\s*platform\s*=' "$PROY/platformio.ini" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '\r ')"
    if [ -n "$PLAT" ]; then
      if ! "$PIO" platform list 2>/dev/null | tr -d '\r' | grep -qi "^$PLAT"; then
        echo "Falta la plataforma '$PLAT' de PlatformIO (la cadena de compilacion de esa placa)."
        echo "  Se instala con : $PIO platform install $PLAT"
        echo "  Ocupa          : entre 200 MB y 1 GB segun la placa"
        echo
        echo "No la bajo solo: PlatformIO lo haria sin preguntar y son cientos de megas."
        exit 3
      fi
    fi
    _hw_info "Compilando con PlatformIO..."
    ( cd "$PROY" && "$PIO" run ) 2>&1
    exit $?
  fi

  if ls "$PROY"/*.v >/dev/null 2>&1; then
    _hw_info "Es un proyecto de FPGA (Verilog)."
    _hw_info "Para comprobar que FUNCIONA sin la placa, lo que sirve es simular:"
    _hw_info "    mentis-hardware.sh simular $PROY"
    _hw_requiere yosys
    YS="$(hw_binario_de yosys)"
    FAM="$(cat "$PROY/.placa" 2>/dev/null || echo GW2A-18)"
    _hw_info "Sintetizando para $FAM..."
    ( cd "$PROY" && "$YS" -p "read_verilog top.v; synth_gowin -top top -json top.json" ) 2>&1
    exit $?
  fi

  if ls "$PROY"/*.ino >/dev/null 2>&1 || [ -f "$PROY" ]; then
    _hw_requiere arduino-cli
    ACLI="$(hw_binario_de arduino-cli)"
    FQBN="$PLACA"
    if [ -z "$FQBN" ] && [ -f "$PROY/.placa" ]; then FQBN="$(cat "$PROY/.placa")"; fi
    if [ -z "$FQBN" ]; then
      # Una sola placa conectada: se infiere. Con cero o varias hay que decirlo a mano.
      FQBN="$("$ACLI" board list --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
m = [b.get("fqbn","") for p in (d.get("detected_ports") or []) for b in (p.get("matched_boards") or [])]
if len(m) == 1:
    print(m[0])
' 2>/dev/null | tr -d '\r')"
    fi
    [ -n "$FQBN" ] || _hw_die "no se cual es la placa. Pasala como 2do argumento (ej: uno) o conecta una sola."
    RES="$(_hw_placa "$FQBN")"; [ -n "$RES" ] && FQBN="${RES##*|}"
    _hw_info "Compilando para $FQBN..."
    # NUNCA descargar el nucleo solo: si falta, se avisa y se corta.
    if ! "$ACLI" core list 2>/dev/null | grep -q "$(printf '%s' "$FQBN" | cut -d: -f1,2 | tr ':' '.')"; then
      NUCLEO="$(printf '%s' "$FQBN" | cut -d: -f1,2)"
      if ! "$ACLI" core list 2>/dev/null | awk '{print $1}' | grep -q "^${NUCLEO}$"; then
        echo "Falta el nucleo '$NUCLEO' para esa placa."
        echo "  Se instala con : arduino-cli core install $NUCLEO"
        echo "  Ocupa          : entre 200 y 500 MB segun la placa"
        echo
        echo "No lo bajo solo: es una descarga grande y la decision es tuya."
        exit 3
      fi
    fi
    "$ACLI" compile --fqbn "$FQBN" "$PROY" 2>&1
    exit $?
  fi

  _hw_die "no reconozco el tipo de proyecto en '$PROY' (no hay platformio.ini, ni.v, ni.ino)."
  ;;

# --- simular: la parte que de verdad se puede iterar sin placa -----------------------------------
simular)
  OBJ="${1:-}"
  [ -n "$OBJ" ] || _hw_die "uso: mentis-hardware.sh simular <archivo.v|carpeta>"
  [ -e "$OBJ" ] || _hw_die "no existe: $OBJ"
  _hw_requiere iverilog
  IV="$(hw_binario_de iverilog)"
  VVP="$(dirname "$IV")/vvp"
  [ -x "$VVP" ] || VVP="vvp"

  if [ -d "$OBJ" ]; then
    FUENTES="$(ls "$OBJ"/*.v 2>/dev/null)"
    [ -n "$FUENTES" ] || _hw_die "no hay archivos.v en $OBJ"
    TB="$(ls "$OBJ"/*_tb.v 2>/dev/null | head -1)"
    DIRT="$OBJ"
  else
    FUENTES="$OBJ"; TB="$OBJ"; DIRT="$(dirname "$OBJ")"
  fi
  [ -n "$TB" ] || _hw_die "no encontre ningun testbench (*_tb.v) en $OBJ. Sin testbench no hay nada que verificar."

  SALIDA="$(mktemp -u).vvp"
  # shellcheck disable=SC2086
  if ! "$IV" -o "$SALIDA" $FUENTES 2>&1; then
    echo "RESULTADO: FALLO -- el Verilog no compila (ver los errores de arriba)."
    exit 1
  fi
  RES="$("$VVP" "$SALIDA" 2>&1)"
  rm -f "$SALIDA" 2>/dev/null
  printf '%s\n' "$RES"
  # El testbench declara su veredicto con una linea "RESULTADO:". Que el simulador termine sin
  # error NO significa que el diseno funcione -- significa que no exploto.
  if printf '%s' "$RES" | grep -q "RESULTADO: OK"; then exit 0; fi
  if printf '%s' "$RES" | grep -q "RESULTADO: FALLO"; then exit 1; fi
  echo "AVISO: el testbench no declaro ningun RESULTADO. Corrio, pero no verifico nada."
  exit 2
  ;;

# --- laminar: modelo 3D -> G-code ------------------------------------------------------------------
laminar)
  MOD="${1:-}"; SAL="${2:-}"
  [ -n "$MOD" ] || _hw_die "uso: mentis-hardware.sh laminar <modelo.stl|.3mf|.obj> [salida.gcode]"
  [ -f "$MOD" ] || _hw_die "no existe el modelo: $MOD"
  _hw_requiere laminador
  PS="$(hw_binario_de laminador)"
  [ -n "$SAL" ] || SAL="${MOD%.*}.gcode"
  _hw_info "Laminando $MOD -> $SAL"
  "$PS" --export-gcode --output "$SAL" "$MOD" 2>&1
  RC=$?
  if [ $RC -eq 0 ] && [ -s "$SAL" ]; then
    _hw_info "Listo: $SAL ($(wc -l < "$SAL") lineas de G-code)"
  else
    echo "El laminado no produjo G-code utilizable." >&2
  fi
  exit $RC
  ;;

# --- bibliotecas -------------------------------------------------------------------------------------
bibliotecas)
  ACC="${1:-}"; NOM="${2:-}"
  [ -n "$ACC" ] && [ -n "$NOM" ] || _hw_die "uso: mentis-hardware.sh bibliotecas <buscar|instalar> <nombre>"
  _hw_requiere arduino-cli
  ACLI="$(hw_binario_de arduino-cli)"
  case "$ACC" in
    buscar)   "$ACLI" lib search "$NOM" 2>&1 | head -40 ;;
    instalar) "$ACLI" lib install "$NOM" 2>&1 ;;
    *) _hw_die "accion desconocida '$ACC'. Usa buscar o instalar." ;;
  esac
  exit $?
  ;;

# --- 2B: lo que necesita la placa fisica -------------------------------------------------------------
subir|monitor|respaldar|borrar)
  bash "$HW_HERE/engine/hw-fisico.sh" "$CMD" "$@"
  exit $?
  ;;

""|-h|--help|ayuda)
  sed -n '2,40p' "$0"
  exit 0
  ;;

*)
  _hw_die "comando desconocido: '$CMD'. Corre 'mentis-hardware.sh' sin argumentos para ver el uso."
  ;;
esac
