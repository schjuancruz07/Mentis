#!/usr/bin/env bash
# test-voz.sh -- pruebas del motor de voz de Mentis (2026-07-26).
#
# Cubre las dos mitades del modo voz:
#   - ENTRADA: mentis-transcribe.sh + el servidor de faster-whisper siempre encendido.
#   - SALIDA:  mentis-tts.sh con magpie-tts (voz la voz elegida).
#
# Por que existen estas pruebas: antes de hoy, transcribir 5 segundos de audio tardaba 59
# SEGUNDOS porque el modelo se recargaba en cada llamada, y nadie lo habia medido nunca. La
# prueba de latencia de abajo esta justamente para que eso no vuelva a pasar sin que salte.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
_ok()  { echo "  ok   -- $1"; PASS=$((PASS+1)); }
_bad() { echo "  FALLO-- $1"; FAIL=$((FAIL+1)); }

_saltado() { echo "  --   -- $1"; }

# El servicio de voz de NVIDIA se cae y se satura como cualquier free tier (medido el 2026-07-28:
# "DEADLINE_EXCEEDED: failed to establish link to worker" en TODOS los caminos, incluso saltando
# el servidor local -- y 40 minutos antes el mismo código generaba audio perfecto). Cuando eso
# pasa, estas pruebas no pueden decir nada sobre el código: no hay con qué probarlo. Marcarlas
# como FALLO sería acusar a Mentis de un problema que es del proveedor, y peor: sería enseñarle a
# uno mismo a ignorar los rojos de esta suite.
_proveedor_caido() {
  printf '%s' "$1" | grep -qE 'DEADLINE_EXCEEDED|failed to establish link|UNAVAILABLE|StatusCode\.(INTERNAL|RESOURCE_EXHAUSTED)'
}

VOZ_TMP="$(mktemp -d)"
trap 'rm -rf "$VOZ_TMP"' EXIT
AUDIO="$VOZ_TMP/dicho.wav"
VOZ_REMOTA_OK=1

echo "== 1. salida de voz (TTS) =="
SALIDA_TTS="$(bash "$HERE/mentis-tts.sh" "Probando la voz de Mentis, uno dos tres." "$AUDIO" 2>&1)"; RC=$?
if _proveedor_caido "$SALIDA_TTS"; then
  VOZ_REMOTA_OK=0
  echo "  AVISO: el servicio de voz de NVIDIA no está respondiendo (no es el código de Mentis)."
  echo "         Las pruebas que necesitan sintetizar audio quedan salteadas."
fi
if [ "$VOZ_REMOTA_OK" = "0" ]; then
  _saltado "TTS salteado: el servicio de NVIDIA está caído"
else
  [ "$RC" -eq 0 ] && _ok "mentis-tts.sh termina con exit 0" || _bad "tts devolvio $RC: $SALIDA_TTS"
  [ -s "$AUDIO" ] && _ok "genero un.wav con contenido ($(wc -c < "$AUDIO") bytes)" || _bad "no genero audio"
fi
# Un.wav de verdad empieza con RIFF. Sin este chequeo, un archivo de basura del tamaño correcto
# pasaria como bueno (el mismo tipo de falso exito que ya mordio en 'gen' y en Kai Vault).
if [ "$VOZ_REMOTA_OK" = "0" ]; then
  _saltado "cabecera WAV salteada (no hay audio que revisar)"
else
  head -c 4 "$AUDIO" 2>/dev/null | grep -q "RIFF" && _ok "el archivo es un WAV valido (cabecera RIFF)" \
                                                  || _bad "el archivo no tiene cabecera de WAV"
fi

echo "== 2. entrada de voz (transcripcion) =="
bash "$HERE/mentis-transcribe.sh" --encender >/dev/null 2>&1
SALUD="$(bash "$HERE/mentis-transcribe.sh" --salud 2>&1)"
printf '%s' "$SALUD" | grep -q '"ok": *true' && _ok "el servidor de voz responde y tiene el modelo cargado" \
                                             || _bad "el servidor no esta listo: $SALUD"

TEXTO="$(bash "$HERE/mentis-transcribe.sh" "$AUDIO" 2>/dev/null)"
if [ "$VOZ_REMOTA_OK" = "0" ]; then
  _saltado "transcripcion salteada: no hay audio de entrada porque el TTS remoto está caído"
else
  [ -n "${TEXTO// }" ] && _ok "transcribe el audio y devuelve texto" || _bad "no devolvio texto"
fi
# Se comprueba el CONTENIDO, no solo que haya algo: transcribir cualquier cosa tambien "devuelve
# texto". Se buscan palabras del audio original.
if [ "$VOZ_REMOTA_OK" = "0" ]; then
  _saltado "contenido de la transcripcion salteado (sin audio de origen)"
else
  printf '%s' "$TEXTO" | grep -qiE "probando|mentis" \
    && _ok "lo transcripto se parece a lo que se dijo (\"${TEXTO:0:40}\")" \
    || _bad "transcribio algo que no tiene que ver: \"$TEXTO\""
fi

echo "== 3. latencia (la razon de ser de todo esto) =="
T0="$(date +%s%3N)"
bash "$HERE/mentis-transcribe.sh" "$AUDIO" >/dev/null 2>&1
MS=$(( $(date +%s%3N) - T0 ))
# Tope generoso a proposito: lo que se quiere detectar es una vuelta a los ~59 s de recargar el
# modelo en cada llamada, no una diferencia de medio segundo entre corridas.
if [ "$MS" -lt 15000 ]; then
  _ok "transcribir tarda ${MS} ms (antes de tener servidor: 58973 ms)"
else
  _bad "transcribir tardo ${MS} ms -- se rompio el servidor persistente y se recarga el modelo"
fi

echo "== 4. errores reportados como errores =="
bash "$HERE/mentis-transcribe.sh" "$VOZ_TMP/no-existe.wav" >/dev/null 2>&1
[ "$?" -ne 0 ] && _ok "un audio inexistente devuelve exit != 0" || _bad "acepto un archivo que no existe"

SALIDA_VACIA="$(bash "$HERE/mentis-tts.sh" "   " 2>&1)"; RC_VACIO=$?
[ "$RC_VACIO" -ne 0 ] && _ok "pedirle a la voz que diga nada devuelve error" \
                      || _bad "genero audio de un texto vacio: $SALIDA_VACIA"

echo "== 5. el servidor de voz escribe DONDE se le pide (ERR de rutas MSYS) =="
# Bug real (2026-07-28): mentis-tts.sh le mandaba al servidor la ruta en formato MSYS
# ("/c/Users/...") y python, que es nativo de Windows, la tomaba literal y creaba el archivo en
# "C:\c\Users\...". El script no lo encontraba, daba el servidor por fallado y se caía al camino
# directo -- 1,2 s más lento POR FRASE, en silencio, en todo lo que no fuera la app (tareas
# programadas, disparadores, consola).
DESTINO="$VOZ_TMP/donde-pedi.wav"
rm -f "$DESTINO"
SALIDA_TTS2="$(bash "$HERE/mentis-tts.sh" "Prueba de ruta." "$DESTINO" 2>&1)"
if _proveedor_caido "$SALIDA_TTS2"; then
  _saltado "ruta de salida salteada: el servicio de voz de NVIDIA sigue caído"
else
  if [ -s "$DESTINO" ]; then
    _ok "el.wav aparece en la ruta pedida, no en una carpeta fantasma"
  else
    _bad "el.wav NO esta en $DESTINO (revisar si quedo en C:\\c\\...): $SALIDA_TTS2"
  fi
  case "$SALIDA_TTS2" in
    *"camino directo"*) _bad "cayo al camino directo: el servidor de voz no se esta usando" ;;
    *) _ok "uso el servidor de voz (no el camino lento)" ;;
  esac
fi

echo "== 6. no se acumulan servidores (ni de salida ni de entrada) =="
# Cada arranque levantaba uno nuevo sin matar el anterior: se midieron 3 vivos a la vez, cada uno
# con su modelo en memoria y su conexion gRPC abierta.
#
# ESTE CHEQUEO MIRABA SOLO EL SERVIDOR DE SALIDA (nv_tts_server), Y ESO DEJO PASAR ERR-111.
# El 2026-08-03 se encontraron DOS nv_stt_server vivos, con 1.617 MB + 1.619 MB de commit, en una
# maquina que tenia 1.891 MB de margen. La guarda contra pilas de servidores ya existia desde que
# paso lo mismo con el TTS -- y nunca se extendio al STT, que es el que carga el modelo caro.
# La leccion: cuando se escribe una guarda contra un modo de falla, hay que preguntarse QUE OTROS
# COMPONENTES tienen la misma forma, no solo tapar el que se rompio.
_contar_servidores() {
  powershell.exe -NoProfile -NonInteractive -Command "
    Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" |
      Where-Object { \$_.CommandLine -like '*$1*' } |
      Measure-Object | Select-Object -ExpandProperty Count" 2>/dev/null | tr -d '\r[:space:]'
}

for PAR in "nv_tts_server:de salida (TTS)" "nv_stt_server:de entrada (transcripcion)"; do
  MODULO="${PAR%%:*}"; ETIQUETA="${PAR#*:}"
  VIVOS="$(_contar_servidores "$MODULO")"
  # El tope es 1: dos ya es la pila que se quiere evitar. Cuando hay un reemplazo en curso puede
  # verse un instante de solapamiento, pero el candado del SO lo cierra en menos de un segundo.
  if [ -n "$VIVOS" ] && [ "$VIVOS" -le 1 ] 2>/dev/null; then
    _ok "hay $VIVOS servidor $ETIQUETA vivo, no una pila"
  else
    _bad "hay $VIVOS servidores $ETIQUETA corriendo a la vez"
  fi
done

echo
echo "RESULTADO: $PASS ok, $FAIL fallos."
[ "$FAIL" -eq 0 ]
