#!/usr/bin/env bash
# test-computer-use.sh -- tools 'screen' (captura+descripcion, solo lectura) y 'control'
# (mouse/teclado real) de nv-agent.sh -- las dos que en la app se unificaron en el boton
# "Computer-use" (pedido del usuario, 2026-07-16). 'screen' es de solo lectura, se automatiza sin
# problema. 'control' hace acciones REALES sobre el escritorio -- a proposito NO se automatiza
# acá (riesgo real de clickear/tipear algo no deseado sin supervision); queda documentado como
# pendiente de verificacion supervisada con computer-use en vivo (mismo criterio que se uso hoy
# para probar el boton Detener).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "computer-use (screen + control, unificados en la UI)"

_sk_case "screen: capturar la pantalla real y describirla" \
  bash "$TOOLSDIR/nv-agent.sh" -s -d "$ROOT" -m general -i 5 \
  "Sacá una captura de mi pantalla ahora y describime en una oración qué ventanas o contenido ves."

_sk_skip "control: mover el mouse / clickear / tipear real" \
  "acción real sobre el escritorio del usuario -- requiere supervisión en vivo con computer-use (no un test desatendido). Ver verificación supervisada aparte."
