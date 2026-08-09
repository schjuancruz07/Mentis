#!/usr/bin/env bash
# mentis-disparadores.sh — frases que Mentis convierte en acción, sin pasar por ningún modelo.
#
# Uso:
#   mentis-disparadores.sh probar "<mensaje>"    -> dice si alguna frase matchea (no ejecuta nada)
#   mentis-disparadores.sh correr "<mensaje>"    -> si matchea, ejecuta la acción e imprime la respuesta
#   mentis-disparadores.sh listar                -> muestra los disparadores configurados
#
# Los disparadores viven en disparadores.json, para que el usuario pueda agregar los suyos sin tocar
# código. Formato de cada uno:
#   { "nombre": "...", "frases": ["...", "..."], "accion": "url|comando",
#     "valor": "...", "respuesta": "lo que Mentis contesta" }
#
# POR QUÉ NO LO DECIDE EL MODELO: "revisate" tiene que correr el diagnóstico SIEMPRE, no el 90%
# de las veces. Un clasificador probabilístico convierte un interruptor en una apuesta, y encima
# cuesta una llamada. Acá el match es exacto sobre el mensaje COMPLETO normalizado, la misma
# decisión que ya se había tomado para el "cerebro rápido" -- y por la misma razón: un prefijo
# tipo "^revisate" atraparía "revisate el codigo que te pase y decime que opinas".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${MENTIS_DISPARADORES:-$HERE/disparadores.json}"
CMD="${1:-}"
MSG="${2:-}"

[ -f "$CONFIG" ] || { [ "$CMD" = "listar" ] && echo "(no hay disparadores configurados)"; exit 1; }

# Devuelve el disparador que matchea, como líneas "campo=valor" (o nada si no matchea).
_buscar() {
  MD_MSG="$MSG" MD_CONFIG="$CONFIG" python3 -c '
import json, os, re, sys, unicodedata

def norm(s):
    s = s.lower()
    s = "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))
    return " ".join(re.findall(r"\w+", s))

msg = norm(os.environ["MD_MSG"])
if not msg:
    sys.exit(1)
try:
    with open(os.environ["MD_CONFIG"], encoding="utf-8") as f:
        disparadores = json.load(f)
except Exception as e:
    print("ERROR=no pude leer los disparadores: %s" % e)
    sys.exit(2)

for d in disparadores:
    for frase in d.get("frases", []):
        if msg == norm(frase):
            print("NOMBRE=%s" % d.get("nombre", "?"))
            print("ACCION=%s" % d.get("accion", ""))
            print("VALOR=%s" % d.get("valor", ""))
            print("RESPUESTA=%s" % d.get("respuesta", "Listo."))
            print("MOSTRAR=%s" % d.get("mostrar_salida", False))
            sys.exit(0)
sys.exit(1)
'
}

case "$CMD" in
  listar)
    MD_CONFIG="$CONFIG" python3 -c '
import json, os
with open(os.environ["MD_CONFIG"], encoding="utf-8") as f:
    for d in json.load(f):
        print("- %s (%s): %s" % (d.get("nombre","?"), d.get("accion","?"), ", ".join(d.get("frases",[]))))
'
    ;;

  probar|correr)
    [ -n "$MSG" ] || { echo "Uso: mentis-disparadores.sh $CMD \"<mensaje>\"" >&2; exit 2; }
    RES="$(_buscar)" || exit 1
    eval "$(printf '%s\n' "$RES" | sed 's/^\([A-Z]*\)=\(.*\)$/\1="\2"/')"
    if [ "$CMD" = "probar" ]; then
      printf 'matchea: %s -> %s (%s)\n' "${NOMBRE:-?}" "${ACCION:-?}" "${VALOR:-}"
      exit 0
    fi

    case "${ACCION:-}" in
      url)
        powershell.exe -NoProfile -NonInteractive -Command "Start-Process '${VALOR}'" >/dev/null 2>&1 || {
          echo "ERROR: no pude abrir la dirección" >&2; exit 3; }
        ;;
      comando)
        # Sale de un archivo que escribe el usuario a mano, no de un modelo ni de un mensaje: es él
        # dándose permiso a sí mismo. Aun así se registra en el log, para que quede rastro.
        echo "[disparadores] ejecutando: ${VALOR}" >&2
        if [ "${MOSTRAR:-}" = "True" ] || [ "${MOSTRAR:-}" = "true" ]; then
          # Para comandos cuya GRACIA es lo que imprimen (el diagnóstico, por ejemplo): la salida
          # va como respuesta, en vez de tragársela y contestar un "listo" que no dice nada.
          SALIDA_CMD="$(bash -c "${VALOR}" 2>&1)"
          printf '%s\n\n%s\n' "${RESPUESTA:-Listo.}" "$SALIDA_CMD"
          exit 0
        fi
        bash -c "${VALOR}" >/dev/null 2>&1 || { echo "ERROR: el comando falló" >&2; exit 3; }
        ;;
      *)
        echo "ERROR: acción desconocida '${ACCION:-}'" >&2; exit 4 ;;
    esac
    printf '%s\n' "${RESPUESTA:-Listo.}"
    ;;

  *)
    echo "Uso: mentis-disparadores.sh probar|correr \"<mensaje>\" | listar" >&2
    exit 2 ;;
esac
