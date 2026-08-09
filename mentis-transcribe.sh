#!/usr/bin/env bash
# mentis-transcribe.sh <archivo_audio> -- pasa un audio a texto, local y offline.
#
# Reescrito 2026-07-26. Antes hacia whisper.load_model("small") en CADA llamada: medido, 59
# SEGUNDOS para 5 segundos de audio (27 s de eso era cargar el modelo, otra vez, cada vez).
# Con eso, hablarle a Mentis era mas lento que escribirle.
#
# Ahora se apoya en nv_stt_server.py, que carga el modelo UNA vez y queda encendido, y usa
# faster-whisper en lugar de openai-whisper. Medicion sobre el mismo audio de 5 s:
#     openai-whisper small....... 26,0 s
#     faster-whisper  small.......  4,2 s
#     faster-whisper  base........  1,4 s   <- el que se usa
# 'base' y no 'tiny' por una razon concreta: tiny transcribe "Mentes" en vez de "Mentis".
#
# La interfaz no cambio: recibe un archivo, imprime el texto por stdout. Todo lo que ya lo
# llamaba (main.js, la app) sigue funcionando igual.
#
# Uso:
#   mentis-transcribe.sh <audio>      -> imprime el texto
#   mentis-transcribe.sh --encender   -> deja el servidor listo (para el arranque de la app)
#   mentis-transcribe.sh --salud      -> estado del servidor
#   mentis-transcribe.sh --apagar     -> lo apaga
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESTADO="${MENTIS_STT_ESTADO:-$HERE/stt-server-state.json}"
MODELO_STT="${MENTIS_STT_MODELO:-base}"

case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

# El puerto se saca con grep, NO con python. Medido: cada arranque del interprete cuesta ~1,5 s
# en Windows, y esta funcion se llama tres veces por transcripcion (al encender, al esperar el
# modelo y al armar el pedido). Eso solo explicaba ~4 s de los ~6,7 s que tardaba el script,
# mientras el servidor respondia en 550 ms. El JSON de estado lo escribe este mismo sistema y
# tiene una forma fija, asi que un grep alcanza y sobra.
_puerto() {
  [ -f "$ESTADO" ] || return 1
  grep -oE '"puerto"[: ]+[0-9]+' "$ESTADO" 2>/dev/null | grep -oE '[0-9]+$'
}

_vivo() {
  local p; p="$(_puerto)" || return 1
  [ -n "$p" ] || return 1
  curl -s -m 3 "http://127.0.0.1:$p/salud" >/dev/null 2>&1
}

_encender() {
  if _vivo; then return 0; fi
  rm -f "$ESTADO" 2>/dev/null
  # Sale del arbol de este script a proposito: tiene que sobrevivir a la llamada que lo prendio.
  # El 'cd' NO es cosmetico (ERR-106): sin el, el servidor hereda como cwd la carpeta desde la
  # que lo llamaron -- que cuando lo prende la app es la carpeta de la app -- y Windows no deja
  # borrar/reemplazar un directorio que algun proceso tiene abierto como cwd. Resultado: empaquetar
  # fallaba con EBUSY y no habia forma de saber por que. El servidor no usa rutas relativas para
  # nada (solo abre lo que recibe por argumento, todo absoluto), asi que mudarlo no le afecta.
  ( cd "${HOME:-/}" 2>/dev/null || cd /
    nohup python3 "$HERE/engine/nv_stt_server.py" --puerto 0 --estado "$ESTADO" --modelo "$MODELO_STT" \
      >/dev/null 2>>"$HERE/stt-server.log" & ) 2>/dev/null
  # Esperar a que anote el puerto (arranca rapido; el modelo carga despues, en paralelo).
  for _ in $(seq 1 40); do
    _vivo && return 0
    sleep 0.25
  done
  return 1
}

_esperar_modelo() {
  local p; p="$(_puerto)" || return 1
  # El modelo tarda ~11 s en cargar la primera vez. Si alguien transcribe justo en ese momento,
  # se espera en vez de devolver un error que no ayuda a nadie.
  for _ in $(seq 1 120); do
    if curl -s -m 3 "http://127.0.0.1:$p/salud" 2>/dev/null | grep -q '"ok": *true'; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

case "${1:-}" in
  --encender)
    _encender && { _esperar_modelo; echo "servidor de voz listo (modelo $MODELO_STT)"; exit 0; }
    echo "ERROR: no se pudo encender el servidor de voz" >&2; exit 1 ;;
  --salud)
    if _vivo; then curl -s -m 3 "http://127.0.0.1:$(_puerto)/salud"; echo; exit 0; fi
    echo '{"ok": false, "error": "el servidor de voz no esta encendido"}'; exit 1 ;;
  --apagar)
    if _vivo; then curl -s -m 3 -X POST "http://127.0.0.1:$(_puerto)/apagar" >/dev/null 2>&1; fi
    rm -f "$ESTADO" 2>/dev/null; echo "servidor de voz apagado"; exit 0 ;;
esac

ENTRADA="${1:-}"
if [ -z "$ENTRADA" ] || [ ! -f "$ENTRADA" ]; then
  echo "ERROR: falta el archivo de audio o no existe: $ENTRADA" >&2
  exit 1
fi

# python es un binario nativo de Windows: la ruta va traducida (ERR-004/ERR-006).
RUTA_WIN="$(cygpath -w "$ENTRADA" 2>/dev/null)" || RUTA_WIN="$ENTRADA"

if ! _encender; then
  echo "ERROR: no se pudo encender el servidor de transcripcion (ver $HERE/stt-server.log)" >&2
  exit 1
fi
_esperar_modelo || { echo "ERROR: el modelo de voz no termino de cargar a tiempo" >&2; exit 1; }

PUERTO="$(_puerto)"

# Se usa la ruta de TEXTO PLANO y curl codifica la ruta del archivo (--data-urlencode + -G).
# Antes esto armaba y parseaba JSON con dos `python3 -c`: medido, ~1,6 s de los ~4,1 s totales
# se iban solo en arrancar el interprete dos veces. En un pipeline de voz eso es carisimo.
RESP="$(curl -s -m 120 -G "http://127.0.0.1:$PUERTO/texto" \
        --data-urlencode "ruta=$RUTA_WIN" 2>/dev/null)"

if [ -z "$RESP" ]; then
  echo "ERROR: el servidor de voz no devolvio nada" >&2
  exit 1
fi
case "$RESP" in
  ERROR:*) printf '%s\n' "$RESP" >&2; exit 1 ;;
esac
printf '%s' "$RESP"
