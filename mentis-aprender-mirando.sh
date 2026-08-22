#!/usr/bin/env bash
# mentis-aprender-mirando.sh -- tocas un boton, hacés la tarea, y sale una skill. (Idea 1 del usuario)
#
# Uso:
#   mentis-aprender-mirando.sh grabar            # empieza a mirar lo que hacés
#   mentis-aprender-mirando.sh frenar            # deja de mirar
#   mentis-aprender-mirando.sh ver               # la ultima grabacion, en castellano
#   mentis-aprender-mirando.sh skill <nombre>    # convierte la ultima grabacion en una skill
#   mentis-aprender-mirando.sh estado
#
# POR QUE ACCIONES Y NO VIDEO (correccion al plan original, 2026-08-20). La idea decia "que
# aprenda mirando un video". El analizador de video saca fotogramas: aun mejorado, entre fotograma
# y fotograma hay que ADIVINAR que paso, y una tarea de interfaz es justamente lo que pasa entre
# medio. Grabar las ACCIONES -- que ventana, que clic, que tecla -- reconstruye la tarea sin
# adivinar nada, ocupa kilobytes en vez de megabytes, y se puede leer.
#
# LO QUE NO GRABA, A PROPOSITO: el contenido de lo que se escribe. Ver el comentario de
# mentis-grabar-acciones.ps1. En algun momento habria pasado una contrasenia por ahi.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/memoria/grabaciones"
CENTINELA="$BASE/.grabando"
ULTIMA="$BASE/ultima.jsonl"
mkdir -p "$BASE"

_win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

_legible() {
  [ -s "$ULTIMA" ] || { echo "(no hay ninguna grabacion)"; return 1; }
  python3 "$HERE/engine/grabacion_legible.py" "$(_win "$ULTIMA")"
}

case "${1:-}" in
  grabar)
    if [ -f "$CENTINELA" ]; then
      echo "Ya estaba grabando. Para frenar: mentis-aprender-mirando.sh frenar"
      exit 0
    fi
    : > "$ULTIMA"
    date +%s > "$CENTINELA"
    # Start-Process para que no quede atado a esta terminal (misma razon que el servidor web).
    powershell.exe -NoProfile -NonInteractive -Command \
      "Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$(_win "$HERE/mentis-grabar-acciones.ps1")','-Salida','$(_win "$ULTIMA")','-Centinela','$(_win "$CENTINELA")'" \
      >/dev/null 2>&1
    sleep 3
    if [ -s "$ULTIMA" ]; then
      echo "GRABANDO. Hace la tarea normalmente."
      echo "Cuando termines:  mentis-aprender-mirando.sh frenar"
    else
      echo "AVISO: el grabador todavia no escribio nada. Si sigue vacio en unos segundos, fallo." >&2
    fi ;;

  frenar)
    if [ ! -f "$CENTINELA" ]; then
      echo "no estaba grabando"
      exit 0
    fi
    rm -f "$CENTINELA"
    sleep 2
    N="$(grep -c. "$ULTIMA" 2>/dev/null)"; N="${N:-0}"
    echo "listo: $N acciones anotadas"
    echo
    _legible | head -25
    echo
    echo "Para convertirlo en una skill:  mentis-aprender-mirando.sh skill <nombre>" ;;

  ver)
    _legible ;;

  estado)
    if [ -f "$CENTINELA" ]; then
      DESDE="$(cat "$CENTINELA" 2>/dev/null || date +%s)"
      echo "grabando desde hace $(( $(date +%s) - DESDE )) s"
    else
      echo "no esta grabando"
    fi
    N="$(grep -c. "$ULTIMA" 2>/dev/null)"; N="${N:-0}"
    echo "ultima grabacion: $N acciones" ;;

  skill)
    NOMBRE="${2:-}"
    [ -n "$NOMBRE" ] || { echo "Uso: mentis-aprender-mirando.sh skill <nombre>" >&2; exit 2; }
    SLUG="$(printf '%s' "$NOMBRE" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/^-*//' | sed 's/-*$//' | cut -c1-30)"
    [ -n "$SLUG" ] || { echo "ese nombre no deja ningun caracter usable" >&2; exit 2; }
    PASOS="$(_legible)" || exit 1
    DEST="$HERE/capabilities/$SLUG.sh"
    if [ -e "$DEST" ]; then
      echo "Ya existe capabilities/$SLUG.sh. Elegi otro nombre para no pisarla." >&2
      exit 1
    fi
    echo "Escribiendo la skill a partir de $(printf '%s' "$PASOS" | grep -c.) pasos..."
    AM_PROMPT="Estos son los pasos que hizo una persona en su computadora, grabados por un observador:

$PASOS

Escribi un script de bash para Mentis que automatice o asista esta tarea. Reglas:
- La primera linea tiene que ser un comentario asi: # CAPABILITY: /$SLUG | descripcion corta
- Despues: set -uo pipefail
- Si algo de la tarea NO se puede automatizar desde bash (apretar un boton de un programa, por ejemplo), NO lo inventes: que el script IMPRIMA ese paso para que lo haga la persona.
- Nada de comandos destructivos.
- Devolve SOLO el codigo, sin explicacion y sin bloques de markdown."
    CUERPO="$(timeout 300 bash "$HERE/engine/ask-nvidia.sh" code "$AM_PROMPT" 2>/dev/null | grep -v '^AVISO:')"
    if [ -z "${CUERPO// }" ]; then
      echo "El modelo no devolvio nada (sin red o saturado)." >&2
      exit 1
    fi
    # Se limpian las vallas de markdown por si el modelo las puso igual.
    printf '%s\n' "$CUERPO" | sed '/^```/d' > "$DEST"
    # UNA SKILL NUEVA NO ENTRA SIN PASAR bash -n. Un archivo con error de sintaxis en capabilities/
    # rompe el listado de skills entero, no solo a si mismo.
    if ! bash -n "$DEST" 2>/dev/null; then
      mv "$DEST" "$DEST.rechazada"
      echo "La skill generada NO compila. Quedo en capabilities/$SLUG.sh.rechazada para que la mires." >&2
      exit 1
    fi
    if ! head -1 "$DEST" | grep -q "^# CAPABILITY:"; then
      sed -i "1i # CAPABILITY: /$SLUG | generada mirando una tarea real ($(date +%Y-%m-%d))" "$DEST"
    fi
    chmod +x "$DEST" 2>/dev/null || true
    echo "Lista: capabilities/$SLUG.sh"
    echo
    head -3 "$DEST"
    echo
    echo "OJO: la escribio un modelo mirando tus pasos. Leela antes de usarla en serio."
    echo "Queda como skill manual (/$SLUG). Para que Mentis la use solo, agregala a skills-autonomas.json." ;;

  *)
    echo "Uso: mentis-aprender-mirando.sh grabar|frenar|ver|skill <nombre>|estado" >&2
    exit 2 ;;
esac
