#!/usr/bin/env bash
# test-arduino.sh -- tool 'arduino' de nv-agent.sh. 'boards' no necesita hardware conectado (lista
# puertos, puede dar lista vacía y aun así ser correcto). 'verify'/'upload'/'monitor' necesitan un
# sketch real y opcionalmente una placa conectada por USB -- se prueba 'verify' con un sketch de
# ejemplo (no necesita placa), 'upload'/'monitor' se documentan como dependientes de hardware.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT/sketch-prueba"
cat > "$ROOT/sketch-prueba/sketch-prueba.ino" << 'EOF'
void setup() {
  pinMode(13, OUTPUT);
}
void loop() {
  digitalWrite(13, HIGH);
  delay(500);
  digitalWrite(13, LOW);
  delay(500);
}
EOF

_sk_section "arduino (arduino-cli real)"

if ! command -v arduino-cli >/dev/null 2>&1; then
  _sk_skip "boards + verify" "arduino-cli no está instalado/en PATH en esta máquina -- no es un bug de Mentis."
else
  _sk_case "boards: listar placas reales conectadas" \
    bash "$TOOLSDIR/nv-agent.sh" -a -d "$ROOT" -m general -i 5 \
    "Listá qué placas Arduino reales están conectadas ahora mismo."

  _sk_case "verify: compilar un sketch de ejemplo de verdad" \
    bash "$TOOLSDIR/nv-agent.sh" -a -d "$ROOT" -m general -i 6 \
    "Compilá el sketch en sketch-prueba/ (fqbn arduino:avr:uno si hace falta especificarlo) y decime si compiló bien o qué error dio."
fi

_sk_skip "upload / monitor" "requieren una placa real conectada por USB -- fuera de alcance de un test automatizado sin hardware presente."
