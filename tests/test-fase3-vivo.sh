#!/usr/bin/env bash
# test-fase3-vivo.sh -- las tres cosas que NUNCA se verificaron en vivo (revisión total, 2026-08-02).
#
# POR QUE EXISTE:
#   El traspaso del 2026-08-01 dejó anotadas tres verificaciones que nunca se hicieron: dictado
#   largo, una skill autónoma real y el contexto automático real. Las tres estaban "construidas y
#   con tests", que es exactamente el estado en el que al usuario ya le fallaron tres features cerradas
#   (ver la memoria mentis-verify-discipline). Un test unitario prueba que la función existe; esto
#   prueba que el camino entero pasa por ella cuando el usuario escribe una frase de verdad.
#
# COMO SE VERIFICA:
#   Corriendo un turno REAL de mentis-chat.sh y mirando los marcadores que el propio agente emite
#   por stderr. No se le pregunta al modelo si usó la herramienta -- eso lo puede inventar. Se mira
#   la traza del proceso, que no miente.
#
# LIMITE HONESTO:
#   V1 usa voz sintética, no la del usuario. Valida la cadena audio largo -> tramos -> texto; no valida
#   su micrófono, su acento ni el ruido de su pieza.
set -uo pipefail

TF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "$TF_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8
TF_TMP="$(mktemp -d)"
trap 'rm -rf "$TF_TMP"' EXIT

TF_OK=0; TF_MAL=0
_ok()  { TF_OK=$((TF_OK+1));  echo "  OK   $1"; }
_mal() { TF_MAL=$((TF_MAL+1)); echo "  MAL  $1"; }
_nota(){ echo "  --   $1"; }

# ================================================================================================
echo "== V1: dictado largo =="
# Un texto largo de verdad: el dictado se parte EN LOS SILENCIOS, así que hace falta que haya
# varias frases. Con una sola oración el partido nunca se ejercita y el test no probaría nada.
TF_TEXTO="Hoy quiero contarte varias cosas seguidas para probar el dictado largo. Primero, necesito que revises el estado de los modelos y me digas cuáles están saturados. Segundo, quiero saber cuántos carbohidratos tiene el almuerzo que te describí antes. Tercero, acordate de que la cámara tiene que seguir apagada salvo que yo la prenda. Y por último, si algo de esto no lo podés hacer, decímelo sin inventar."
TF_WAV="$TF_TMP/largo.wav"
T0=$(date +%s%N)
bash "$TF_ROOT/mentis-tts.sh" "$TF_TEXTO" "$TF_WAV" >/dev/null 2>&1
T1=$(date +%s%N)
if [ -s "$TF_WAV" ]; then
  TF_SEG="$(python3 -c "
import wave, sys
with wave.open(sys.argv[1]) as w: print(round(w.getnframes()/float(w.getframerate()),1))
" "$(cygpath -w "$TF_WAV" 2>/dev/null || echo "$TF_WAV")" 2>/dev/null | tr -d '\r')"
  _ok "audio largo generado: ${TF_SEG:-?} s ($(( (T1-T0)/1000000 )) ms)"
else
  _mal "no se pudo generar el audio largo"
fi

if [ -s "$TF_WAV" ]; then
  T0=$(date +%s%N)
  TF_TR="$(bash "$TF_ROOT/mentis-transcribe.sh" "$TF_WAV" 2>/dev/null | tr -d '\r')"
  T1=$(date +%s%N)
  TF_MS=$(( (T1-T0)/1000000 ))
  # Se cuentan cuatro anclas repartidas a lo largo del texto: si el dictado se cortara a los 45 s
  # (el tope viejo) o se perdiera un tramo, las últimas desaparecerían. Es lo que hace que esto
  # pruebe algo en vez de comprobar que hubo audio.
  #
  # DOS COSAS QUE ESTE CHEQUEO APRENDIÓ A LOS GOLPES (2026-08-02, dio un fallo FALSO por las dos):
  # 1. Hay que NORMALIZAR TILDES antes de comparar. Buscar "camara" contra un texto que dice
  #    "cámara" no matchea, y el dictado quedaba reprobado estando perfecto. Es ERR-100 otra vez:
  #    el reemplazo va letra por letra y nunca con clases tipo [áà], porque sed trabaja por bytes
  #    y una vocal acentuada en UTF-8 ocupa dos.
  # 2. El ancla no puede ser una palabra que el STT escriba distinto. Whisper transcribe
  #    "carbohidratos" como "carboidratos" -- el sentido llega intacto y el ancla igual fallaba.
  #    Se usan raíces cortas que sobreviven a un error de una letra.
  TF_NORM='s/á/a/g; s/é/e/g; s/í/i/g; s/ó/o/g; s/ú/u/g; s/ü/u/g; s/ñ/n/g'
  TF_TRN="$(printf '%s' "$TF_TR" | tr '[:upper:]' '[:lower:]' | sed "$TF_NORM")"
  TF_ANC=0
  for a in "modelos" "hidratos" "camara" "inventar"; do
    printf '%s' "$TF_TRN" | grep -qF "$a" && TF_ANC=$((TF_ANC+1))
  done
  if [ "$TF_ANC" -ge 4 ]; then
    _ok "transcripción completa: 4/4 anclas presentes (${TF_MS} ms)"
  elif [ "$TF_ANC" -ge 2 ]; then
    _mal "transcripción INCOMPLETA: sólo $TF_ANC/4 anclas -- se perdió el final (${TF_MS} ms)"
  else
    _mal "transcripción fallida ($TF_ANC/4 anclas, ${TF_MS} ms)"
  fi
  _nota "texto: $(printf '%s' "$TF_TR" | head -c 300)"
fi
_nota "esto usó voz sintética; el dictado con la voz REAL del usuario sigue sin probarse"

# ================================================================================================
echo "== V2: contexto automático (que traiga solo lo ya hablado) =="
# La frase lleva "acordate de lo que hablamos", que es una de las pistas de _mc_buscar_en_el_pasado.
# Lo que se comprueba NO es que la respuesta suene informada, sino que el proceso haya corrido la
# búsqueda: el marcador 'iter 0: recordar' lo emite mentis-chat.sh antes de llamar a ningún modelo.
T0=$(date +%s%N)
printf '%s\n' "Acordate de lo que hablamos sobre la camara: ¿que habiamos decidido?" \
  | timeout 300 bash "$TF_ROOT/mentis-chat.sh" -R -H "$TF_TMP/h1.jsonl" > "$TF_TMP/o1.txt" 2> "$TF_TMP/e1.txt"
T1=$(date +%s%N)
if grep -q "iter 0: recordar" "$TF_TMP/e1.txt"; then
  _ok "el contexto automático se disparó solo ($(( (T1-T0)/1000000 )) ms)"
else
  _mal "NO se disparó la búsqueda en el pasado con una frase que la debería disparar"
fi
_nota "respuesta: $(tr -d '\r' < "$TF_TMP/o1.txt" | tail -3 | head -c 300)"

# Y el control negativo: una frase sin ninguna pista NO tiene que disparar la búsqueda. Sin esto,
# un disparador que se activa siempre pasaría el test de arriba pareciendo que funciona.
printf '%s\n' "Cuanto es 12 mas 30?" \
  | timeout 240 bash "$TF_ROOT/mentis-chat.sh" -R -H "$TF_TMP/h2.jsonl" > "$TF_TMP/o2.txt" 2> "$TF_TMP/e2.txt"
if grep -q "iter 0: recordar" "$TF_TMP/e2.txt"; then
  _mal "se disparó la búsqueda en el pasado con una frase que no la pedía (falso positivo)"
else
  _ok "no se disparó donde no correspondía (control negativo)"
fi

# ================================================================================================
echo "== V3: skill autónoma (que la use sola, sin que el usuario escriba el comando) =="
# Se le da un pedido que calza con /where, que está en 'libre' en skills-autonomas.json. NO se
# escribe "/where": si Mentis la usa, la usó sola. Modo NO remoto, porque -R apaga -K a propósito.
T0=$(date +%s%N)
printf '%s\n' "Necesito ubicar en que carpeta del ecosistema vive graphify. Usa tus habilidades si te sirven." \
  | timeout 400 bash "$TF_ROOT/mentis-chat.sh" -H "$TF_TMP/h3.jsonl" > "$TF_TMP/o3.txt" 2> "$TF_TMP/e3.txt"
T1=$(date +%s%N)
if grep -qE "iter [0-9]+: skill [a-z-]+" "$TF_TMP/e3.txt"; then
  _ok "usó una skill por su cuenta: $(grep -oE 'iter [0-9]+: skill [a-z-]+' "$TF_TMP/e3.txt" | head -1) ($(( (T1-T0)/1000000 )) ms)"
elif grep -q "skill RECHAZADO" "$TF_TMP/e3.txt"; then
  _mal "intentó usar una skill y fue RECHAZADA: $(grep -m1 'skill RECHAZADO' "$TF_TMP/e3.txt")"
elif ! grep -qE "iter [0-9]+:" "$TF_TMP/e3.txt"; then
  # SIN TURNO NO HAY PRUEBA. Si el modelo no llegó a razonar ni una iteración -- porque el free
  # tier estaba agotado, que es lo que pasó el 2026-08-02 -- entonces "no usó ninguna skill" no
  # dice nada sobre las skills: dice que no hubo turno. Declararlo fallo sería culpar al
  # mecanismo por una caída de cuota; declararlo OK sería peor. Es SIN VERIFICAR.
  _mal "SIN VERIFICAR: el turno no llegó a correr (ninguna iteración del agente). No es un veredicto sobre las skills."
else
  # Que el modelo elija no usarla habiendo corrido el turno SÍ es un resultado: el mecanismo
  # estaba disponible y no lo tomó. Se distingue del rechazo y de la caída a propósito: son tres
  # problemas distintos con tres arreglos distintos.
  _mal "corrió el turno pero no usó ninguna skill (el mecanismo estaba disponible y no lo tomó)"
fi
_nota "respuesta: $(tr -d '\r' < "$TF_TMP/o3.txt" | tail -4 | head -c 400)"

echo
echo "== RESULTADO: $TF_OK bien, $TF_MAL mal =="
[ "$TF_MAL" -eq 0 ]
