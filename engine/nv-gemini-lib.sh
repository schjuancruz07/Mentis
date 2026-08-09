#!/usr/bin/env bash
# nv-gemini-lib.sh -- contabilidad de cuota para el proveedor Gemini (2026-08-07).
#
# POR QUE ESTE ARCHIVO EXISTE, Y POR QUE ES TAN CHICO:
#   Gemini se cablea por el camino "openai-compatible" que ask-nvidia.sh YA tiene desde el
#   2026-07-13, porque Google expone sus modelos en /v1beta/openai/chat/completions con el mismo
#   formato de payload y el mismo SSE que NVIDIA. Se verifico el 2026-08-07 contra la API real:
#   respuesta no-stream OK, stream OK (delta.content chunk a chunk). O sea que NO hace falta
#   escribir payload ni parseo nuevos, que era lo que el comentario de ask-nvidia.sh:295 daba por
#   pendiente ("Anthropic/Gemini con su formato propio... es una pasada aparte"). Para Gemini no
#   lo es. Lo unico que el camino existente NO sabe hacer es lo de abajo: llevar la cuenta.
#
# LO QUE SI HACE FALTA:
#   El tier gratuito de Google corta por cantidad de pedidos POR DIA. Cuando se acaba, la API
#   devuelve 429 y el turno se muere. Un asistente que deja de contestar a media tarde porque se
#   quedo sin cuota es peor que uno que nunca uso Gemini. Asi que se cuenta ANTES de llamar, y
#   cuando no queda mas, el rol se va a NVIDIA sin que el usuario se entere.
#
# EL CONTADOR VIVE EN UN ARCHIVO, NO EN MEMORIA: cada turno de Mentis es un proceso nuevo.
# Formato: una linea "AAAA-MM-DD <usados>". Al cambiar el dia se reinicia solo.
#
# LIMITES DEL TIER GRATUITO (Google los publica por modelo y los cambia sin avisar; estos son los
# del 2026-08-07 y estan como DEFAULT, no como verdad eterna -- se pisan con GEMINI_TOPE_DIA):
#     Flash        10/min    250/dia
#     Flash-Lite   15/min  1.000/dia
# Con 3-5 llamadas por turno, 250/dia son unos 50-80 turnos de conversacion.

# Donde se guarda la cuenta. Junto al resto del estado del motor.
NVG_HOME="${NV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NVG_CUOTA_FILE="${GEMINI_CUOTA_FILE:-$NVG_HOME/.gemini-cuota}"
NVG_TOPE_DIA="${GEMINI_TOPE_DIA:-250}"

# --- nv_gemini_usados -> imprime cuantos pedidos se gastaron HOY ---------------------------------
# Si el archivo es de otro dia, cuenta cero: la cuota de Google se reinicia por dia calendario.
nv_gemini_usados() {
  local hoy linea dia n
  hoy="$(date +%Y-%m-%d)"
  [ -f "$NVG_CUOTA_FILE" ] || { echo 0; return 0; }
  linea="$(head -1 "$NVG_CUOTA_FILE" 2>/dev/null | tr -d '\r')"
  dia="${linea%% *}"; n="${linea##* }"
  [ "$dia" = "$hoy" ] || { echo 0; return 0; }
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# --- nv_gemini_quedan -> cuantos pedidos quedan hoy ----------------------------------------------
nv_gemini_quedan() {
  local usados; usados="$(nv_gemini_usados)"
  local quedan=$(( NVG_TOPE_DIA - usados ))
  [ "$quedan" -lt 0 ] && quedan=0
  echo "$quedan"
}

# --- nv_gemini_hay_cuota -> 0 (si) / 1 (no) ------------------------------------------------------
# Este es el unico que mira ask-nvidia.sh antes de decidir si usa Gemini o se va a NVIDIA.
nv_gemini_hay_cuota() {
  [ "$(nv_gemini_quedan)" -gt 0 ]
}

# --- nv_gemini_sumar -> anota un pedido gastado --------------------------------------------------
# Se llama DESPUES de disparar la llamada, no antes: si se anotara antes y el proceso muriera, se
# perderian pedidos que nunca se hicieron. Escribe por archivo temporal + mv para que dos turnos
# simultaneos no dejen el contador a medio escribir.
nv_gemini_sumar() {
  local hoy usados tmp
  hoy="$(date +%Y-%m-%d)"
  usados="$(nv_gemini_usados)"
  tmp="${NVG_CUOTA_FILE}.$$"
  printf '%s %s\n' "$hoy" "$(( usados + 1 ))" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$NVG_CUOTA_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# --- nv_gemini_estado -> una linea legible para el usuario ---------------------------------------
nv_gemini_estado() {
  local usados quedan
  usados="$(nv_gemini_usados)"; quedan="$(nv_gemini_quedan)"
  if [ "$quedan" -eq 0 ]; then
    printf 'Gemini: sin cuota por hoy (%s de %s usados). Los roles vuelven solos a NVIDIA.\n' \
      "$usados" "$NVG_TOPE_DIA"
  else
    printf 'Gemini: %s de %s pedidos usados hoy, quedan %s.\n' "$usados" "$NVG_TOPE_DIA" "$quedan"
  fi
}

# --- nv_gemini_aviso_privacidad -> el texto que hay que mostrar ANTES de encenderlo --------------
# Se pone en una funcion y no suelto en el instalador para que diga EXACTAMENTE lo mismo en todos
# lados: instalador, panel de la app y linea de comandos.
nv_gemini_aviso_privacidad() {
  cat <<'AVISO'
ANTES DE ENCENDER GEMINI, LEE ESTO:

  El tier GRATUITO de Google usa lo que le mandas para entrenar sus modelos.
  Y hay revisores humanos que pueden llegar a leer lo que escribas en la conversacion.
  El tier PAGO no entrena con tus datos.

  Mentis NO manda nada a Google mientras Gemini este apagado, que es como viene de fabrica.
  NVIDIA sigue siendo el proveedor principal.

  Si vas a hablar de cosas privadas -- salud, plata, laburo, otras personas -- dejalo apagado.
AVISO
}
