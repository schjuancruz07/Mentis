#!/usr/bin/env bash
set -uo pipefail
fail=0
SCRIPT="$HOME/Mentis/mentis-3d-gen.sh"
TMPOUT="$(mktemp -d)"

# Test 1: sin --prompt ni --image, debe rechazar
OUT="$(bash "$SCRIPT" -o "$TMPOUT/sin-nada.glb" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then echo "FAIL: deberia rechazar sin --prompt ni --image"; fail=1
else case "$OUT" in *ERROR*) echo "ok: rechaza sin --prompt ni --image" ;; *) echo "FAIL: mensaje no legible: $OUT"; fail=1 ;; esac
fi

# Test 2: flujo real completo con --prompt (genera imagen y la convierte a 3D)
OUT="$(bash "$SCRIPT" -o "$TMPOUT/real.glb" --prompt "a small red apple on white background" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then echo "FAIL: deberia generar el modelo 3D real (rc=$RC, out=$OUT)"; fail=1
elif [ ! -s "$TMPOUT/real.glb" ]; then echo "FAIL: el archivo GLB no existe o esta vacio"; fail=1
else
  MAGIC="$(head -c 4 "$TMPOUT/real.glb")"
  if [ "$MAGIC" = "glTF" ]; then echo "ok: genera un GLB valido de verdad"; else echo "FAIL: no es un GLB valido (magic: $MAGIC)"; fail=1; fi
fi

rm -rf "$TMPOUT"
if [ "$fail" -eq 0 ]; then echo "TODOS LOS TESTS OK"; else echo "HAY TESTS FALLANDO"; fi
exit $fail
