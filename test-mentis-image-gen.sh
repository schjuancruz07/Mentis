#!/usr/bin/env bash
set -uo pipefail
fail=0
SCRIPT="$HOME/Mentis/mentis-image-gen.sh"
TMPOUT="$(mktemp -d)"

# Test 1: sin prompt, debe rechazar con error legible y exit != 0
OUT="$(bash "$SCRIPT" -o "$TMPOUT/sin-prompt.jpg" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then echo "FAIL: deberia rechazar sin prompt"; fail=1
else case "$OUT" in *ERROR*) echo "ok: rechaza sin prompt con mensaje ERROR" ;; *) echo "FAIL: mensaje de error no legible: $OUT"; fail=1 ;; esac
fi

# Test 2: con prompt real, genera un archivo JPEG valido en la ruta pedida
OUT="$(bash "$SCRIPT" -o "$TMPOUT/real.jpg" "a small blue circle on white background" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then echo "FAIL: deberia generar la imagen real (rc=$RC, out=$OUT)"; fail=1
elif [ ! -s "$TMPOUT/real.jpg" ]; then echo "FAIL: el archivo de salida no existe o esta vacio"; fail=1
else
  MAGIC="$(head -c 3 "$TMPOUT/real.jpg" | xxd -p)"
  case "$MAGIC" in ffd8ff) echo "ok: genera un JPEG valido de verdad" ;; *) echo "FAIL: no es un JPEG valido (magic bytes: $MAGIC)"; fail=1 ;; esac
fi

# Test 3: FLUX/NVIDIA es el camino principal -- se comprueba por el LADO del que no puede mentir:
# la imagen de arriba tiene que haber salido sin pasar por Pollinations (que avisa por stderr).
case "$OUT" in *"probando con Pollinations"*) echo "FAIL: cayo a Pollinations, el camino principal (NVIDIA) no funciono"; fail=1 ;; *) echo "ok: la imagen la genero el camino principal (FLUX/NVIDIA), sin fallback" ;; esac

# Test 4: si NVIDIA falla, Pollinations lo cubre. Se simula apuntando el endpoint a una URL rota:
# es la unica forma de probar el fallback sin esperar a que el free tier se sature de verdad.
OUT4="$(NVIDIA_IMG_URL="https://ai.api.nvidia.com/v1/genai/no/existe" bash "$SCRIPT" -o "$TMPOUT/fb.jpg" "a small red square on white background" 2>&1)"
RC4=$?
case "$OUT4" in *"probando con Pollinations"*) echo "ok: avisa que cae al fallback cuando NVIDIA falla" ;; *) echo "FAIL: no aviso del fallback"; fail=1 ;; esac
if [ "$RC4" -ne 0 ] || [ ! -s "$TMPOUT/fb.jpg" ]; then
  echo "FAIL: con NVIDIA caido, Pollinations deberia haber generado igual (rc=$RC4)"; fail=1
else
  MAGIC4="$(head -c 3 "$TMPOUT/fb.jpg" | xxd -p)"
  case "$MAGIC4" in ffd8ff) echo "ok: con NVIDIA caido, el fallback genera un JPEG valido igual" ;; *) echo "FAIL: el fallback no dio un JPEG (magic: $MAGIC4)"; fail=1 ;; esac
fi

rm -rf "$TMPOUT"
if [ "$fail" -eq 0 ]; then echo "TODOS LOS TESTS OK"; else echo "HAY TESTS FALLANDO"; fi
exit $fail
