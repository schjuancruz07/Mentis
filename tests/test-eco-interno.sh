#!/usr/bin/env bash
# test-eco-interno.sh -- que el usuario nunca lea el texto que Mentis se escribe a si mismo.
#
# EL BUG (2026-08-15, reportado con captura). el usuario pidio un brazalete con modulos intercambiables.
# El turno hizo 15 'task create', no genero ningun documento, y lo que el usuario leyo en pantalla fue:
#
#   "No puedo generar un documento sin contenido. Si ya tenes el contenido, generalo AHORA con
#    "tool":"gen","action":"doc","format":"docx","content":"..." y recien despues cerra con 'done'."
#
# Eso es la OBSERVACION que la guarda de documento le inyecta AL MODELO. El modelo la devolvio como
# respuesta final, y la guarda de "segunda vez" la envolvio en "Esto es lo que tenia preparado para
# adentro:" y se la mostro.
#
# POR QUE ES UNA FAMILIA. En nv-agent.sh hay ~100 puntos que le inyectan texto al modelo y TRES
# guardas que arman la respuesta final concatenando lo que el modelo devolvio. Cualquier cruce de
# esas dos listas produce el mismo sintoma. Por eso la defensa es UNA sola pregunta del lado de la
# salida -- "¿esto que voy a mostrar es texto mio?" -- y no un parche por guarda.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$HERE/engine/nv-lib.sh"
A="$HERE/engine/nv-agent.sh"
CHAT="$HERE/mentis-chat.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# shellcheck source=/dev/null
source "$LIB"

echo "== reconoce el texto interno =="
_eco() { # _eco <nombre> <texto>
  if nv_eco_interno "$2"; then _ok "$1"; else _mal "$1" "no lo detecto como eco"; fi
}
_no_eco() {
  if nv_eco_interno "$2"; then _mal "$1" "lo censuro siendo una respuesta legitima"; else _ok "$1"; fi
}

# EL CASO REAL, palabra por palabra como lo vio el usuario.
_eco "el texto exacto de la captura del usuario" \
  'No puedo generar un documento sin contenido. Si ya tenés el contenido, generalo AHORA con "tool":"gen","action":"doc","format":"docx","content":"..." y recién después cerrá con '"'"'done'"'"'. Para meterle imágenes, poné dentro del content una línea '"'"'!img <qué buscar>'"'"' (foto libre de Wikimedia Commons, con atribución) o '"'"'!imgfile <ruta>|<epígrafe>'"'"'.'
_eco "un AVISO de guarda tal cual" "AVISO: ya escribiste 'plan.md' 4 veces en este turno con EXACTAMENTE el mismo contenido."
_eco "un ERROR de guarda tal cual" "ERROR: tu respuesta habla de un documento pero en este turno NO generaste ninguno."
_eco "una orden de cierre con acento" "Contesta AHORA con lo que ya leiste; si de verdad falta algo, respondé con done."
_eco "una orden de cierre sin acento" "Si ya esta todo, responde con done."
_eco "protocolo JSON crudo" 'Usá {"tool":"read","path":"archivo.txt"} para leerlo.'

echo "== y NO censura respuestas de verdad =="
_no_eco "una respuesta normal" "Listo: te armé el documento del brazalete y quedó en Documents/Mentis/brazalete.docx"
_no_eco "una respuesta que habla de un documento" "El documento tiene tres secciones y la foto va en el medio."
_no_eco "una respuesta tecnica del pedido real" "Para el brazalete vas a necesitar un ESP32, dos servos SG90 y una batería LiPo de 500 mAh. Los módulos se enganchan con un conector pogo de 4 pines."
_no_eco "una respuesta que dice que termino algo" "Terminé con el módulo del aturdidor: quedó andando y lo probé."
_no_eco "una respuesta que admite un limite" "No pude generar el documento porque no llegué a juntar el contenido."
_no_eco "texto vacio" ""

echo "== la guarda REAL del agente, ejecutada =="
BLOQUE="$(mktemp)"
awk '/# ¿ESTO QUE VA A LEER USUARIO ES MI PROPIO TEXTO\?/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 15 ]; then
  _mal "se puede extraer la guarda de eco" "no se encontro en $A"
else
  _ok "la guarda de eco se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"

  # PRIMERA VEZ: se rechaza y se le pide la respuesta con sus palabras.
  r="$( (
    set +e
    source "$LIB"
    STATUS="done"; ECO_RECHAZOS=0; HIST=""; it=3
    FINAL='Generalo AHORA con "tool":"gen","action":"doc" y después cerrá con done.'
    source "$BLOQUE"
    printf 'status=%s final_vacio=%s rechazos=%s' "$STATUS" "$([ -z "$FINAL" ] && echo si || echo no)" "$ECO_RECHAZOS"
  ) 2>/dev/null )"
  case "$r" in
    "status=budget final_vacio=si rechazos=1") _ok "la primera vez rechaza el done y le pide la respuesta de nuevo" ;;
    *) _mal "primer rechazo" "obtuvo: $r" ;;
  esac

  # SEGUNDA VEZ: no se insiste (quemaria el turno), pero el eco NO se muestra.
  r="$( (
    set +e
    source "$LIB"
    STATUS="done"; ECO_RECHAZOS=1; HIST=""; it=8
    FINAL='Generalo AHORA con "tool":"gen","action":"doc" y después cerrá con done.'
    source "$BLOQUE"
    printf '%s' "$FINAL"
  ) 2>/dev/null )"
  case "$r" in
    *'"tool"'*|*"cerrá con done"*) _mal "segunda vez" "el eco llego igual a la respuesta: $r" ;;
    "") _mal "segunda vez" "dejo la respuesta vacia en vez de decir algo honesto" ;;
    *) _ok "la segunda vez cierra con un mensaje propio y el eco NO se muestra" ;;
  esac

  # Y una respuesta legitima tiene que pasar sin que nadie la toque.
  r="$( (
    set +e
    source "$LIB"
    STATUS="done"; ECO_RECHAZOS=0; HIST=""; it=3
    FINAL="Te armé el documento del brazalete: quedó en Documents/Mentis/brazalete.docx"
    source "$BLOQUE"
    printf 'status=%s|%s' "$STATUS" "$FINAL"
  ) 2>/dev/null )"
  case "$r" in
    "status=done|Te armé el documento del brazalete: quedó en Documents/Mentis/brazalete.docx") _ok "una respuesta buena pasa intacta" ;;
    *) _mal "no toca lo que esta bien" "obtuvo: $r" ;;
  esac
fi
rm -f "$BLOQUE"

echo "== la capa por PROCEDENCIA (la que no envejece) =="
# Lo que esta capa hace y la de marcadores no: agarrar el eco de un texto que NADIE marco -- una
# guarda escrita manana, sin AVISO:, sin JSON y sin ordenes de cierre.
REG="$(mktemp)"
printf '%s

' "La carpeta de destino esta llena y no puedo seguir copiando los archivos del respaldo; probá liberando espacio antes de reintentar la operacion completa." >> "$REG"
export NVA_OBS_LOG="$REG"
NVDIR="$HERE/engine"

if nv_eco_procedencia "La carpeta de destino esta llena y no puedo seguir copiando los archivos del respaldo; proba liberando espacio antes de reintentar la operacion completa." 2>/dev/null; then
  _ok "detecta el eco de un texto que ningun marcador conoce"
else
  _mal "eco sin marcadores" "no lo vio: es justo lo que la capa nueva viene a cubrir"
fi
if nv_eco_interno "La carpeta de destino esta llena y no puedo seguir copiando los archivos del respaldo; proba liberando espacio antes de reintentar la operacion completa." 2>/dev/null; then
  _mal "control" "los marcadores lo detectaron: el caso no prueba lo que dice probar"
else
  _ok "y los marcadores solos NO lo veian (por eso hacia falta la capa)"
fi

# Una respuesta legitima del mismo turno no se toca, aunque hable del mismo tema.
if nv_eco_procedencia "Copié los archivos del respaldo a la carpeta nueva y quedaron los 42." 2>/dev/null; then
  _mal "respuesta legitima" "la censuro"
else
  _ok "una respuesta propia sobre el mismo tema pasa intacta"
fi

# Sin registro, la capa se calla: no puede ser el motivo de que un turno falle.
if NVA_OBS_LOG="" nv_eco_procedencia "cualquier cosa que diga aca" 2>/dev/null; then
  _mal "sin registro" "dijo que era eco sin tener con que compararlo"
else
  _ok "sin registro no opina (nunca rompe un turno por su cuenta)"
fi

if MENTIS_ECO_PROCEDENCIA_OFF=1 nv_eco_procedencia "La carpeta de destino esta llena y no puedo seguir copiando los archivos del respaldo; proba liberando espacio antes de reintentar la operacion completa." 2>/dev/null; then
  _mal "apagado" "MENTIS_ECO_PROCEDENCIA_OFF=1 no la apaga"
else
  _ok "MENTIS_ECO_PROCEDENCIA_OFF=1 la apaga"
fi
rm -f "$REG"; unset NVA_OBS_LOG

echo "== el orden importa =="
# La guarda de eco tiene que correr ANTES de las tres que arman la respuesta concatenando $FINAL.
# Si quedara despues, esas tres ya habrian mostrado el eco envuelto en una frase amable -- que es
# exactamente lo que paso.
L_ECO="$(grep -n '¿ESTO QUE VA A LEER USUARIO ES MI PROPIO TEXTO?' "$A" | cut -d: -f1 | head -1)"
L_DOC="$(grep -n 'No llegué a generar el documento en este turno' "$A" | cut -d: -f1 | head -1)"
L_GATE="$(grep -n 'nv_gate_texto_corregido' "$A" | cut -d: -f1 | head -1)"
L_ARCH="$(grep -n 'estos archivos NO existen' "$A" | cut -d: -f1 | head -1)"
for par in "documento:$L_DOC" "gate:$L_GATE" "archivos:$L_ARCH"; do
  nom="${par%%:*}"; num="${par##*:}"
  if [ -n "$num" ] && [ -n "$L_ECO" ] && [ "$L_ECO" -lt "$num" ]; then
    _ok "la guarda de eco corre antes que la de $nom"
  else
    _mal "orden contra la de $nom" "eco en $L_ECO, $nom en $num"
  fi
done

# La de documento ademas se defiende sola: es la que mostro el texto en la captura.
if grep -q 'if nv_eco_interno "$FINAL"; then' "$A"; then
  _ok "la guarda de documento no adjunta el eco ni aunque cambie el orden"
else
  _mal "defensa en la guarda de documento" "volvio a concatenar \$FINAL sin preguntar"
fi

echo "== la ultima linea, en el chat =="
# Existe porque la respuesta que ve el usuario no siempre viene del agente: el verificador de dos modelos
# puede reemplazarla despues, y ese camino no pasa por ninguna guarda del motor.
if grep -q 'nv_eco_interno "$ANSWER"' "$CHAT"; then
  _ok "mentis-chat.sh tambien lo revisa antes de imprimir"
else
  _mal "ultima linea de defensa" "el chat imprime sin revisar el eco"
fi
if awk '/nv_eco_interno "\$ANSWER"/,/^  fi$/' "$CHAT" | grep -q 'ANSWER='; then
  _ok "y lo reemplaza por un mensaje para el usuario"
else
  _mal "el chat reemplaza el eco" "lo detecta y lo imprime igual"
fi

echo
printf 'test-eco-interno: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
