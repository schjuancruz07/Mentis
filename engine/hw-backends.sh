#!/usr/bin/env bash
# hw-backends.sh -- el catálogo de cadenas de herramientas de hardware, en un solo lugar.
#
# POR QUE EXISTE:
#   "Programar cualquier hardware" no es una herramienta, son seis, y ninguna viene instalada.
#   Este archivo dice, para cada una: cómo se llama el binario, qué cubre, cómo se instala, y
#   cuánto pesa. Nada de eso se adivina en el momento.
#
# REGLA DURA -- NUNCA SE INSTALA NADA SOLO:
#   Un `verificar` de una placa nueva puede bajarse el núcleo de esa placa: cientos de megas, sin
#   avisar, en la conexión del usuario. Así que las herramientas se detectan y se informan, con el
#   comando exacto y el tamaño, pero la decisión de instalar es siempre de él. Un "no está
#   instalado, se instala así, ocupa tanto" es infinitamente más útil que un cuelgue de 20 minutos.
#
# Los comandos de instalación de acá están VERIFICADOS contra esta máquina (winget 2026-08-01):
# los ids existen. verilator, gtkwave y openFPGALoader NO están en winget y van por el paquete
# único de YosysHQ (OSS CAD Suite), que trae toda la cadena de FPGA junta.

# Formato de cada backend: nombre|binario|fase|que_cubre|como_instalar|tamano_aprox
#   fase = 2A (no necesita hardware conectado) | 2B (necesita la placa fisica)
hw_backends() {
  cat <<'TABLA'
arduino-cli|arduino-cli|2B|Arduino UNO/Nano/Mega y, con board managers, ESP32/ESP8266/RP2040/STM32|winget install ArduinoSA.CLI|~50 MB (mas ~300 MB por cada nucleo de placa)
platformio|pio|2A|+1000 placas: STM32, nRF, SAMD, Teensy, ESP, AVR. Compila Marlin para la impresora|python3 -m pip install platformio|~200 MB (mas la plataforma de cada placa)
esptool|esptool|2B|ESP32/ESP8266 a bajo nivel: leer, borrar y RESPALDAR la flash antes de pisarla|python3 -m pip install esptool|~15 MB
mpremote|mpremote|2B|MicroPython en RP2040/ESP32: subir.py, correr, consola interactiva|python3 -m pip install mpremote|~5 MB
yosys|yosys|2A|Sintesis de Verilog para la FPGA (Gowin GW2A-18 del Tang Primer 20K)|OSS CAD Suite: https://github.com/YosysHQ/oss-cad-suite-build/releases|~1,5 GB (trae yosys+nextpnr+iverilog+openFPGALoader juntos)
nextpnr|nextpnr-himbaechel|2A|Place and route para la FPGA Gowin|viene en el OSS CAD Suite (ver yosys)|incluido
apicula|gowin_pack|2A|Genera el bitstream de la FPGA Gowin sin las herramientas del fabricante|python3 -m pip install apycula|~30 MB
openFPGALoader|openFPGALoader|2B|Carga el bitstream a la placa (SRAM para iterar, flash para lo definitivo)|viene en el OSS CAD Suite (ver yosys)|incluido
iverilog|iverilog|2A|Simula el Verilog y corre los testbench SIN placa: donde mas sirve la IA|winget install Icarus.Verilog|~30 MB
verilator|verilator|2A|Simulacion rapida de Verilog para disenos grandes|viene en el OSS CAD Suite (ver yosys)|incluido
qemu-riscv|qemu-system-riscv32|2A|Corre tu sistema operativo RISC-V sin la placa|winget install SoftwareFreedomConservancy.QEMU|~400 MB
riscv-gcc|riscv-none-elf-gcc|2A|Compila C para tu procesador RISC-V|npm i -g xpm && xpm install -g @xpack-dev-tools/riscv-none-elf-gcc|~700 MB
rust-riscv|cargo|2A|Compila Rust para RISC-V (rustup target add riscv32imac-unknown-none-elf)|winget install Rustlang.Rustup|~1 GB
laminador|prusa-slicer-console|2A|Convierte un modelo 3D en G-code para imprimir|winget install Prusa3D.PrusaSlicer|~250 MB
TABLA
}

# hw_backend_campo <nombre> <n_campo> -> imprime ese campo, o nada si el backend no existe
hw_backend_campo() {
  hw_backends | awk -F'|' -v n="$1" -v c="$2" '$1==n {print $c; exit}'
}

# hw_binario_de <nombre> -> la ruta del binario si esta instalado, vacio si no.
# Busca en el PATH y tambien en las rutas donde winget deja las cosas: un proceso que arranco
# ANTES de la instalacion no hereda el PATH nuevo hasta reiniciarse, asi que "no esta en el PATH
# ahora" no es lo mismo que "no esta instalado" (la misma leccion que ya estaba en mentis-arduino.sh).
hw_binario_de() {
  local bin extra
  bin="$(hw_backend_campo "$1" 2)"
  [ -n "$bin" ] || return 1
  if command -v "$bin" >/dev/null 2>&1; then command -v "$bin"; return 0; fi
  for extra in \
    "/c/Program Files/Arduino CLI/$bin.exe" \
    "/c/Program Files/qemu/$bin.exe" \
    "/c/iverilog/bin/$bin.exe" \
    "/c/Program Files/iverilog/bin/$bin.exe" \
    "/c/Program Files/qemu/$bin" \
    "/c/Program Files/Prusa3D/PrusaSlicer/prusa-slicer-console.exe" \
    "/c/Program Files/Prusa3D/PrusaSlicer/$bin.exe" \
    "/c/oss-cad-suite/bin/$bin.exe" \
    "$HOME/AppData/Local/Programs/oss-cad-suite/bin/$bin.exe" \
    "$HOME/AppData/Roaming/Python/Python314/Scripts/$bin.exe" \
    "$HOME/AppData/Local/Python/pythoncore-3.14-64/Scripts/$bin.exe"
  do
    [ -x "$extra" ] && { printf '%s' "$extra"; return 0; }
  done
  return 1
}

# hw_instalado <nombre> -> 0 si esta, 1 si no
hw_instalado() { hw_binario_de "$1" >/dev/null 2>&1; }
