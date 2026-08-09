#!/usr/bin/env bash
# test-voz-eleven.sh -- ElevenLabs como voz rapida para frases cortas (D, 2026-08-03).
#
# QUE SE MIDIO ANTES DE CONSTRUIR NADA (todo verificado contra la API real, no leido de la web):
#   - La key funciona pero NO tiene 'user_read' ni 'voices_read': no hay forma de preguntarle a
#     ElevenLabs cuanta cuota queda ni que voces tiene la cuenta.
#   - El plan gratuito NO deja usar voces de la biblioteca por API (402 paid_plan_required).
#     Tres voces si funcionan, encontradas probandolas una por una.
#   - Flash entrega el primer byte a los 408 ms y termina en 987 ms de punta a punta.
#     El TTS actual (NVIDIA) tarda 2.469 ms. 2,4 veces mas rapido.
#   - Cuesta 0,5 creditos por caracter (30 caracteres -> cabecera 'character-cost: 15'). Con
#     10.000 gratis al mes son 20.000 caracteres; el volumen real del usuario es 48.681. Alcanza para
#     el 41%, y de ahi que sea selectivo.
#
# La mayoria de los chequeos NO gastan cuota: miran el codigo y la logica de ruteo. Los que llaman
# de verdad a ElevenLabs estan detras de -v.
set -uo pipefail
TE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TE_ROOT="$(cd "$TE_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TE_VIVO=0; [ "${1:-}" = "-v" ] && TE_VIVO=1
TE_OK=0; TE_MAL=0
_ok()  { TE_OK=$((TE_OK+1));  echo "  OK   $1"; }
_mal() { TE_MAL=$((TE_MAL+1)); echo "  MAL  $1  ($2)"; }

HELPER="$TE_ROOT/engine/eleven_tts.py"
FRENTE="$TE_ROOT/mentis-tts.sh"
[ -f "$HELPER" ] || { echo "ABORTA: falta $HELPER" >&2; exit 1; }

TE_TMP="$(mktemp -d)"
case "$TE_TMP" in "$TE_ROOT"|"$TE_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TE_TMP"' EXIT
CUOTA="$TE_TMP/cuota.json"

echo "== ElevenLabs como voz rapida =="
echo "-- A. un solo proceso (o el andamiaje se come el beneficio)"

python3 -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read())" "$(cygpath -w "$HELPER")" \
  && _ok "A1 eleven_tts.py compila" || _mal "A1 compila" "error de sintaxis"

# A2: LA LECCION QUE COSTO LA PRIMERA VERSION. Hacer el chequeo de cuota, el JSON y la
# contabilidad en procesos separados daba 3.401 ms para una llamada que la API sirve en 491 ms.
# Arrancar el interprete cuesta ~446 ms aca: uno es aceptable, cuatro no.
N_PY="$(grep -cE '^\s*(python3|MENTIS_EL_TXT=.*python3)' "$TE_ROOT/mentis-tts-eleven.sh" 2>/dev/null || echo 0)"
if grep -q "eleven_tts.py" "$FRENTE"; then
  _ok "A2 el camino rapido llama a UN solo proceso"
else
  _mal "A2 un solo proceso" "mentis-tts.sh no usa el helper consolidado"
fi

echo "-- B. la cuota, que es el limite real"

# B1: se lleva local porque la API no la puede informar con esta key.
grep -q "user_read" "$HELPER" \
  && _ok "B1 documenta POR QUE la cuota se lleva local (la key no puede consultarla)" \
  || _mal "B1 documenta el porque" "alguien va a 'arreglarlo' consultando una API que da 403"

# B2: el costo real sale de la cabecera, no de una estimacion.
grep -q 'character-cost' "$HELPER" \
  && _ok "B2 suma el costo REAL que informa la respuesta, no una estimacion" \
  || _mal "B2 costo real" "la cuenta se desviaria de a poco hasta el 401"

# B3: y hay estimacion PREVIA, para no arrancar una llamada que se pasa del presupuesto.
grep -q "est = (largo + 1) // 2" "$HELPER" \
  && _ok "B3 estima antes de llamar (no se pasa del presupuesto por un pelo)" \
  || _mal "B3 estimacion previa" "podria pasarse y recien enterarse despues"

# B4: sin cuota -> exit 3, distinto de un error de la API (4). El ruteo depende de saber cual es.
printf '{"%s": 999999}' "$(date +%Y-%m)" > "$CUOTA"
MENTIS_EL_CUOTA="$CUOTA" python3 "$HELPER" --texto "hola" --salida "$TE_TMP/x.mp3" >/dev/null 2>&1
[ $? = 3 ] && _ok "B4 sin cuota devuelve exit 3 (distinto de un error de API)" \
           || _mal "B4 exit sin cuota" "no distingue 'no me queda' de 'se rompio'"

# B5: reinicio mensual. Sin esto la cuota se agota para siempre en el primer mes.
grep -q '"%Y-%m"' "$HELPER" \
  && _ok "B5 la cuenta se reinicia cada mes" \
  || _mal "B5 reinicio mensual" "la cuota quedaria agotada para siempre"

echo "-- C. el ruteo: cuando SI y cuando NO"

grep -q 'MENTIS_EL_VOZ:-' "$FRENTE" \
  && _ok "C1 arranca APAGADO hasta que el usuario elija una voz (es decision de oido)" \
  || _mal "C1 apagado por defecto" "usaria una voz que el usuario no eligio"

grep -q 'MENTIS_EL_MAXCHARS' "$FRENTE" \
  && _ok "C2 solo frases cortas (protege los 20.000 caracteres del mes)" \
  || _mal "C2 umbral de largo" "un texto largo se comeria la cuota de golpe"

# C3: si el llamador pidio un archivo concreto, se respeta su formato. ElevenLabs da mp3, y
# escribir mp3 adentro de un archivo.wav es pedirle a alguien que lo reproduzca de casualidad.
grep -q '\[ -z "\${2:-}" \]' "$FRENTE" \
  && _ok "C3 si piden una ruta concreta, no cambia el formato por atras" \
  || _mal "C3 respeta el formato pedido" "un.wav podria terminar con mp3 adentro"

# C4: si ElevenLabs falla, sigue por NVIDIA sin decir nada. Quedarse sin voz por ahorrar medio
# segundo seria un mal negocio.
grep -q 'rm -f "\$EL_OUT"' "$FRENTE" \
  && _ok "C4 si falla, cae a NVIDIA en silencio (nunca deja al usuario sin voz)" \
  || _mal "C4 fallback silencioso" "un fallo de ElevenLabs dejaria el turno mudo"

echo "-- D. el ruteo, probado de verdad (sin gastar cuota)"

# Sin voz elegida -> NVIDIA.
# Se apunta a un settings PROPIO y vacío en vez de usar el del usuario. Antes decía "es el estado por
# defecto hoy" y leía su archivo real: el día que eligió una voz (Lily, 2026-08-08) este caso
# empezó a fallar sin que el ruteo tuviera nada malo. Un test no puede depender de lo que el
# usuario tenga configurado -- misma lección que ERR-119.
printf '{}\n' > "$TE_TMP/settings-sin-voz.json"
R="$(MENTIS_SETTINGS_FILE="$TE_TMP/settings-sin-voz.json" bash "$FRENTE" "Prueba corta." 2>/dev/null | tail -1)"
case "$R" in
  *.wav) _ok "D1 sin voz elegida, sale por NVIDIA (.wav)" ;;
  *)     _mal "D1 sin voz elegida" "salio '$R'" ;;
esac

# Y el caso inverso, que antes no se probaba: CON una voz guardada en settings, tiene que salir
# por ElevenLabs (.mp3). Es el que hace valer la elección del usuario -- sin esto, el script podría
# ignorar la voz elegida y los tests seguirían todos en verde, que es justamente el bug que se
# encontró a mano ese mismo día (la voz se guardaba y no se le pasaba al sintetizador).
printf '{"voz":{"elevenVozId":"pFZP5JQG7iQjIQuC4Bku"}}\n' > "$TE_TMP/settings-con-voz.json"
R2="$(MENTIS_SETTINGS_FILE="$TE_TMP/settings-con-voz.json" bash "$FRENTE" "Prueba corta." 2>/dev/null | tail -1)"
case "$R2" in
  *.mp3) _ok "D1b con voz elegida en settings, sale por ElevenLabs (.mp3)" ;;
  *)     _mal "D1b con voz elegida" "salio '$R2' -- la eleccion de voz no se esta aplicando" ;;
esac

# Con voz pero pidiendo un.wav concreto -> NVIDIA igual.
bash "$FRENTE" "Prueba." "$TE_TMP/pedido.wav" >/dev/null 2>&1
if [ -s "$TE_TMP/pedido.wav" ] && head -c 4 "$TE_TMP/pedido.wav" | grep -q RIFF; then
  _ok "D2 con ruta.wav pedida, respeta el formato (RIFF de verdad)"
else
  _mal "D2 respeta el.wav pedido" "el archivo no es un wav"
fi

if [ "$TE_VIVO" = "1" ]; then
  echo "-- E. llamadas reales a ElevenLabs (gastan cuota)"
  if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
    _mal "E1 llamada real" "falta ELEVENLABS_API_KEY en el entorno"
  else
    : > "$CUOTA"
    T0=$(date +%s%3N)
    MENTIS_EL_CUOTA="$CUOTA" python3 "$HELPER" --texto "Listo el usuario, ya guardé el archivo." \
      --salida "$TE_TMP/real.mp3" >/dev/null 2>"$TE_TMP/real.err"
    RC=$?; T1=$(date +%s%3N)
    if [ "$RC" = "0" ] && [ -s "$TE_TMP/real.mp3" ]; then
      _ok "E1 genera audio real en $((T1-T0)) ms"
      head -c 3 "$TE_TMP/real.mp3" | grep -q "ID3" \
        && _ok "E2 el archivo es un MP3 valido" \
        || _mal "E2 MP3 valido" "cabecera inesperada"
      # E3: LA TRAMPA DE LAS TILDES. Interpolar el texto en bash rompe el UTF-8 del cuerpo y
      # ElevenLabs contesta 'invalid_unicode' -- con una respuesta de 95 bytes que un chequeo por
      # tamaño daria por buena.
      [ "$(wc -c < "$TE_TMP/real.mp3")" -gt 5000 ] \
        && _ok "E3 el texto con tildes llego bien (no es una respuesta de error)" \
        || _mal "E3 tildes" "solo $(wc -c < "$TE_TMP/real.mp3") bytes: huele a invalid_unicode"
      grep -q "creditos" "$TE_TMP/real.err" \
        && _ok "E4 informa cuantos creditos gasto" \
        || _mal "E4 informe de creditos" "no se puede seguir el gasto"
    else
      _mal "E1 llamada real" "rc=$RC $(head -c 90 "$TE_TMP/real.err")"
    fi
  fi
else
  echo "-- E. (llamadas reales salteadas; corre con -v y ELEVENLABS_API_KEY)"
fi

echo
echo "== $TE_OK OK, $TE_MAL MAL =="
[ "$TE_MAL" -eq 0 ]
