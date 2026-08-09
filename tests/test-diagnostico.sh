#!/usr/bin/env bash
# test-diagnostico.sh — el auto-diagnóstico de Mentis.
#
# La pregunta que este test contesta NO es "¿dice que está todo bien?" -- eso lo dice cualquiera,
# y es justo lo que hizo Kai Vault durante ocho días. La pregunta es: **¿se da cuenta cuando algo
# está roto?**. Así que acá se rompen cosas a propósito y se exige que las encuentre.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/mentis-diagnostico.sh"
fail=0
ROTO_TMP="$DIR/zz-roto-de-prueba.sh"

# Pase lo que pase, el archivo roto de prueba no queda en la carpeta del usuario.
limpiar() { rm -f "$ROTO_TMP"; }
trap limpiar EXIT INT TERM

bash -n "$SCRIPT" && echo "ok: mentis-diagnostico.sh parsea sin errores" || { echo "FAIL: sintaxis"; fail=1; }

echo "== 1. encuentra un script con sintaxis rota =="
# Un `if` sin `fi`: bash -n lo rechaza, así que el diagnóstico TIENE que verlo.
printf '#!/usr/bin/env bash\nif [ 1 = 1 ]; then\n  echo hola\n' > "$ROTO_TMP"
SALIDA="$(bash "$SCRIPT" --mirar 2>&1)"; RC=$?
if printf '%s' "$SALIDA" | grep -q "error de sintaxis en zz-roto-de-prueba.sh"; then
  echo "ok: detecta el script roto y lo nombra"
else
  echo "FAIL: NO detecto un script con sintaxis rota (es el chequeo mas barato que existe)"; fail=1
fi
[ "$RC" -ne 0 ] && echo "ok: sale con codigo != 0 cuando hay algo roto" || { echo "FAIL: dijo que estaba todo bien"; fail=1; }
rm -f "$ROTO_TMP"

echo "== 2. con todo sano, sale limpio =="
SALIDA2="$(bash "$SCRIPT" --mirar 2>&1)"; RC2=$?
if [ "$RC2" -eq 0 ]; then
  echo "ok: sin nada roto, sale con 0"
else
  # Puede fallar legitimamente (un servidor caido de verdad): se muestra para poder mirarlo.
  echo "aviso: reporto algo roto -- puede ser real:"; printf '%s\n' "$SALIDA2" | grep -E "ROTO" | head -3
fi

echo "== 3. --mirar NO repara =="
# Se mata el servidor de voz: en modo mirar tiene que reportarlo y dejarlo muerto.
powershell.exe -NoProfile -NonInteractive -Command "
  Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" |
    Where-Object { \$_.CommandLine -like '*nv_tts_server*' } |
    ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1 || true
sleep 2
SALIDA3="$(bash "$SCRIPT" --mirar 2>&1)"
if printf '%s' "$SALIDA3" | grep -q "el servidor de voz no responde"; then
  echo "ok: detecta el servidor de voz caido"
else
  echo "FAIL: no detecto que el servidor de voz estaba muerto"; fail=1
fi
# Se busca el FORMATO de la linea de reparacion ("  reparado <algo>"), no la palabra suelta: el
# resumen final dice "reparados: 0" y hacia que este test se marcara solo.
if printf '%s\n' "$SALIDA3" | grep -qE '^  reparado '; then
  echo "FAIL: reparo algo estando en modo --mirar"; fail=1
else
  echo "ok: en modo --mirar no toca nada"
fi

echo "== 4. en modo normal SI repara lo mecanico =="
SALIDA4="$(bash "$SCRIPT" 2>&1)"
if printf '%s' "$SALIDA4" | grep -q "reparado.*servidor de voz"; then
  echo "ok: levanto solo el servidor de voz que estaba caido"
elif printf '%s' "$SALIDA4" | grep -q "el servidor de voz responde"; then
  # Si ya estaba vivo (lo levanto otra cosa entre medio), tambien es un resultado aceptable.
  echo "ok: el servidor de voz esta arriba (lo levanto el diagnostico o ya estaba)"
elif bash "$DIR/mentis-tts.sh" "x" "$(mktemp -u).wav" 2>&1 | grep -qE 'DEADLINE_EXCEEDED|failed to establish link|UNAVAILABLE'; then
  # El servidor local no puede levantarse si el servicio de NVIDIA no responde: no hay voz que
  # cargar. Culpar al diagnostico por eso seria acusarlo de un problema del proveedor -- el mismo
  # criterio que en test-voz.sh. (Ademas esta suite y la de voz se pisan el mismo servidor cuando
  # corren una atras de otra, asi que este caso aparece de verdad.)
  echo "--   -- salteado: el servicio de voz de NVIDIA esta caido, no hay nada que levantar"
else
  echo "FAIL: no reparo ni reporto correctamente el servidor de voz"; fail=1
fi

echo "== 5. no repara lo que NO debe =="
# Reparar codigo es exactamente lo que NO tiene que hacer solo: se comprueba que no haya ninguna
# escritura de archivos de codigo en el script.
if grep -qE '(^|[^a-z])(sed -i|python3.*-w|> *"\$HERE"/[a-z-]*\.sh)' "$SCRIPT"; then
  echo "FAIL: el diagnostico escribe codigo -- eso no puede hacerlo solo"; fail=1
else
  echo "ok: no toca ningun archivo de codigo"
fi

echo "== 6. no le pregunta la opinion a ningun modelo =="
# Todo lo que reporte tiene que salir de senales duras (exit code, HTTP, proceso vivo). Si
# consultara un modelo, estariamos otra vez en "el que fallo se declara sano".
# Se busca que los EJECUTE, no que los nombre: el chequeo de archivos del motor lista
# ask-nvidia.sh y nv-agent.sh para ver si existen, y eso no es consultar a nadie.
if grep -qE '(bash|sh) +"?\$?\{?HERE\}?/?(engine/)?(ask-nvidia|nv-agent)\.sh' "$SCRIPT"; then
  echo "FAIL: el diagnostico consulta un modelo para decidir si esta sano"; fail=1
else
  echo "ok: no consulta modelos -- solo senales objetivas"
fi

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
