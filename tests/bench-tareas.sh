#!/usr/bin/env bash
# bench-tareas.sh -- las cuatro tareas REALES del usuario, de punta a punta (revisión total, 2026-08-02).
#
# POR QUE EXISTE Y POR QUE ESTA SEPARADO DE bench-roles.sh:
#   bench-roles mide la calidad del modelo desnudo, y ahí Mentis pierde por construcción: corre
#   sobre modelos gratis contra modelos de frontera. Esto mide otra cosa -- si la TAREA queda
#   terminada -- y es donde Mentis puede ganar de verdad, porque vive en la máquina del usuario,
#   recuerda sus conversaciones, le cuenta los carbohidratos y anda desde el celular.
#
#   Los dos números NO se promedian. Un puntaje único escondería justo lo que hay que saber.
#
# LAS CUATRO (elegidas por el usuario el 2026-08-02):
#   T1  hablarle por voz y que ejecute
#   T2  contar carbohidratos
#   T3  que recuerde lo hablado
#   T4  usarlo desde el celular
#
# LO QUE ESTE SCRIPT NO PUEDE HACER, Y HAY QUE DECIRLO:
#   T1 se prueba con voz SINTETICA (el propio TTS de Mentis generando el audio que despues
#   transcribe). Eso valida la cadena audio->texto->acción de punta a punta, pero NO valida el
#   dictado largo con la voz real del usuario, su micrófono y el ruido de su pieza. Eso sólo lo puede
#   hacer él. Un OK acá no es un OK a eso.
#
# Uso: bench-tareas.sh -o salida.jsonl
set -uo pipefail

BT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BT_ROOT="$(cd "$BT_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

BT_OUT=""
while getopts ":o:" opt; do
  case "$opt" in o) BT_OUT="$OPTARG" ;; *) echo "Uso: bench-tareas.sh -o salida.jsonl" >&2; exit 2 ;; esac
done
[ -n "$BT_OUT" ] || { echo "Falta -o" >&2; exit 2; }
: > "$BT_OUT"

BT_TMP="$(mktemp -d)"
trap 'rm -rf "$BT_TMP"' EXIT

# anotar <tarea> <paso> <ok|mal|nota> <ms> <detalle>
anotar() {
  BT_T="$1" BT_P="$2" BT_E="$3" BT_MS="$4" BT_D="$5" python3 -c '
import json, os
print(json.dumps({"tarea": os.environ["BT_T"], "paso": os.environ["BT_P"],
                  "estado": os.environ["BT_E"], "ms": int(os.environ["BT_MS"]),
                  "detalle": os.environ["BT_D"][:600]}, ensure_ascii=False))
' | tr -d '\r' >> "$BT_OUT"
  printf '  [%s] %-34s %s  (%s ms) %s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | head -c 140)"
}

_ms() { date +%s%N; }
_dif() { echo $(( ($2 - $1) / 1000000 )); }

# ================================================================================================
echo "== T1: hablarle por voz y que ejecute =="
# Paso 1: el TTS genera el audio de una frase que ES un disparador real de disparadores.json.
T0="$(_ms)"
BT_WAV="$BT_TMP/frase.wav"
bash "$BT_ROOT/mentis-tts.sh" "prende la camara" "$BT_WAV" >/dev/null 2>&1
T1="$(_ms)"
if [ -s "$BT_WAV" ]; then
  anotar T1 "TTS genera el audio" ok "$(_dif "$T0" "$T1")" "$(stat -c %s "$BT_WAV" 2>/dev/null) bytes"
else
  anotar T1 "TTS genera el audio" mal "$(_dif "$T0" "$T1")" "no se generó el wav"
fi

# Paso 2: el STT local lo vuelve a texto. Es el camino real del dictado, sin pasar por internet.
if [ -s "$BT_WAV" ]; then
  T0="$(_ms)"
  BT_TXT="$(bash "$BT_ROOT/mentis-transcribe.sh" "$BT_WAV" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  T1="$(_ms)"
  if printf '%s' "$BT_TXT" | grep -qiE 'camara|cámara'; then
    anotar T1 "STT devuelve el texto" ok "$(_dif "$T0" "$T1")" "transcripción: $BT_TXT"
  else
    anotar T1 "STT devuelve el texto" mal "$(_dif "$T0" "$T1")" "transcripción: ${BT_TXT:-vacía}"
  fi
else
  BT_TXT=""
fi

# Paso 3: el disparador reconoce la frase SIN pasar por ningún modelo. Esto es lo que hace que
# "prendé la cámara" tarde milisegundos en vez de un turno entero.
T0="$(_ms)"
BT_DISP="$(bash "$BT_ROOT/mentis-disparadores.sh" probar "prende la camara" 2>&1 | tr -d '\r')"
T1="$(_ms)"
if printf '%s' "$BT_DISP" | grep -qi "camara"; then
  anotar T1 "el disparador reconoce la frase" ok "$(_dif "$T0" "$T1")" "$BT_DISP"
else
  anotar T1 "el disparador reconoce la frase" mal "$(_dif "$T0" "$T1")" "$BT_DISP"
fi

# Paso 4: y con lo que devolvió el STT de verdad, no con el texto ideal. Es donde se rompe la
# cadena en la práctica: el STT escribe "cámara" con tilde y el disparador compara normalizado.
if [ -n "${BT_TXT:-}" ]; then
  T0="$(_ms)"
  BT_D2="$(bash "$BT_ROOT/mentis-disparadores.sh" probar "$BT_TXT" 2>&1 | tr -d '\r')"
  T1="$(_ms)"
  if printf '%s' "$BT_D2" | grep -qi "camara"; then
    anotar T1 "cadena completa voz->accion" ok "$(_dif "$T0" "$T1")" "$BT_D2"
  else
    anotar T1 "cadena completa voz->accion" mal "$(_dif "$T0" "$T1")" "el STT dijo '$BT_TXT' y el disparador no lo reconoció: $BT_D2"
  fi
fi
anotar T1 "voz REAL del usuario" nota 0 "no se puede probar sin él: esto usó voz sintética"

# ================================================================================================
echo "== T2: contar carbohidratos =="
# Una comida real descrita como la describiría el usuario, no un ítem de tabla nutricional.
T0="$(_ms)"
BT_C="$(bash "$BT_ROOT/engine/ask-nvidia.sh" -q 'Almorce un plato de fideos con salsa de tomate, calculo unos 150 gramos de fideos ya cocidos, y una manzana de postre. Cuantos gramos de carbohidratos comi en total? Responde con el numero total.' 2>/dev/null | tr -d '\r')"
T1="$(_ms)"
#
#     Carbohidratos estimados: 58 g
#     - Fideos cocidos (150 g): ~33 g
#     - Manzana (postre, mediana): ~25 g
#     Supuestos: se asume 22 g por 100 g de pasta y una manzana de 180 g...
#
# Con esa forma, "el primer numero" y "el ultimo numero" fallan los dos: el primero acierta de
# casualidad y el ultimo agarra 180 (el peso de la manzana). Las dos reglas se probaron y las dos
# dieron veredictos falsos sobre respuestas correctas. Cuando la salida tiene un campo, se lee el
# campo -- adivinar por posicion es lo que estuvo mal desde el principio.
BT_N="$(printf '%s' "$BT_C" | grep -oiE 'carbohidratos estimados:[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
# Respaldo por si algun dia cambia el formato: el ultimo numero de la PRIMERA linea.
[ -n "$BT_N" ] || BT_N="$(printf '%s' "$BT_C" | head -1 | grep -oE '[0-9]+' | tail -1)"
# 150 g de fideos cocidos ~= 45 g de HC, una manzana mediana ~= 20 g. Total razonable: 50-90.
#
# "SIN RESPUESTA" NO ES "ESTIMÓ MAL", y la diferencia es la que hay entre un modelo flojo y un rol
# que se quedó sin ningún cerebro detrás. El 2026-08-02 pasó lo segundo: el principal en 429 y los
# dos fallbacks tampoco contestaron. Mezclarlos escondería el problema real, que es de reparto de
# tenía sólo 4 casos válidos parecía que el modelo era malo. Con los 15 corridos dio 93,3%.
if [ -z "${BT_C// }" ]; then
  anotar T2 "estimación de una comida real" nota "$(_dif "$T0" "$T1")" "SIN VERIFICAR: no contestó ningún modelo de la cadena de (principal ni fallbacks). No es un error de estimación."
elif [ -n "$BT_N" ] && [ "$BT_N" -ge 45 ] 2>/dev/null && [ "$BT_N" -le 95 ] 2>/dev/null; then
  anotar T2 "estimación de una comida real" ok "$(_dif "$T0" "$T1")" "dio $BT_N g -- $BT_C"
else
  anotar T2 "estimación de una comida real" mal "$(_dif "$T0" "$T1")" "dio '${BT_N:-nada}' (esperado 45-95) -- $BT_C"
fi

# ================================================================================================
echo "== T3: que recuerde lo hablado =="
# Dos preguntas: una que SI tiene respuesta en las conversaciones viejas y otra que no. La segunda
# es la importante: el riesgo real no es que no encuentre, es que invente que sí hablaron.
T0="$(_ms)"
BT_R1="$(bash "$BT_ROOT/mentis-recordar.sh" "camara webcam" 2>&1 | tr -d '\r' | head -c 500)"
T1="$(_ms)"
if [ -n "$BT_R1" ] && ! printf '%s' "$BT_R1" | grep -qi "no encontr\|sin resultados"; then
  anotar T3 "encuentra algo que sí se habló" ok "$(_dif "$T0" "$T1")" "$BT_R1"
else
  anotar T3 "encuentra algo que sí se habló" mal "$(_dif "$T0" "$T1")" "$BT_R1"
fi

T0="$(_ms)"
BT_R2="$(bash "$BT_ROOT/mentis-recordar.sh" "el viaje a Noruega y el alquiler del velero" 2>&1 | tr -d '\r' | head -c 500)"
T1="$(_ms)"
anotar T3 "consulta por algo que NUNCA se habló" nota "$(_dif "$T0" "$T1")" "$BT_R2"

# ================================================================================================
echo "== T4: usarlo desde el celular =="
# El servidor real, por HTTP, con el token real. No se simula el transporte: si el token o el
# arranque están rotos, esto lo muestra.
T0="$(_ms)"
bash "$BT_ROOT/mentis-web.sh" prender >/dev/null 2>&1
sleep 3
BT_TOK="$(cat "$BT_ROOT/engine/.web-token" 2>/dev/null | tr -d '\r\n')"
BT_COD="$(curl -s -o "$BT_TMP/pag.html" -w '%{http_code}' --max-time 20 "http://127.0.0.1:8765/?t=$BT_TOK" 2>/dev/null)"
T1="$(_ms)"
if [ "$BT_COD" = "200" ]; then
  anotar T4 "la página responde con token" ok "$(_dif "$T0" "$T1")" "HTTP $BT_COD, $(stat -c %s "$BT_TMP/pag.html" 2>/dev/null) bytes"
else
  anotar T4 "la página responde con token" mal "$(_dif "$T0" "$T1")" "HTTP $BT_COD"
fi

T0="$(_ms)"
BT_COD2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:8765/?t=token-invalido-de-prueba" 2>/dev/null)"
T1="$(_ms)"
if [ "$BT_COD2" != "200" ]; then
  anotar T4 "rechaza un token inválido" ok "$(_dif "$T0" "$T1")" "HTTP $BT_COD2"
else
  anotar T4 "rechaza un token inválido" mal "$(_dif "$T0" "$T1")" "aceptó un token falso"
fi

echo
echo "Resultados en: $BT_OUT"
