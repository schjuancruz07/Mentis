#!/usr/bin/env bash
# mentis-deshacer.sh -- volver atrás lo que Mentis tocó (2026-07-27).
#
# POR QUE EXISTE:
#   Mentis escribe y ejecuta de VERDAD en la máquina del usuario. Hasta ahora, si sobreescribía un
#   archivo con algo peor, no había forma de volver: el respaldo diario es de las 03:00 y puede
#   estar a 20 horas de distancia. La idea es de Hermes (sus checkpoints): sacar una foto ANTES
#   de cada operación que pisa algo, para poder deshacerla en el momento.
#
#   LO IMPORTANTE, y es la razón por la que se usa un repo SOMBRA: el.git del proyecto del usuario
#   NO se toca nunca. Ni se crea, ni se lee, ni se le agregan commits. Si el usuario tiene su propio
#   git en esa carpeta, sigue exactamente como estaba -- su historial es suyo. Las fotos viven
#   aparte, en su propio directorio, y se manejan con --git-dir/--work-tree.
#   (No es un detalle teórico: el 2026-07-26 se creó un repo de git que el usuario no había pedido y
#   hubo que borrarlo. Esto se diseñó para que eso no pueda volver a pasar.)
#
# Uso:
#   mentis-deshacer.sh foto <dir> "<motivo>"   -> saca una foto del estado actual
#   mentis-deshacer.sh listar <dir>            -> muestra las fotos disponibles
#   mentis-deshacer.sh ver <dir> <id>          -> qué cambió respecto de esa foto
#   mentis-deshacer.sh volver <dir> <id>       -> restaura el estado de esa foto
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

SOMBRAS="${MENTIS_SOMBRAS_DIR:-$HERE/engine/sombras}"

command -v git >/dev/null 2>&1 || { echo "ERROR: no hay git disponible" >&2; exit 2; }

# Cada carpeta vigilada tiene su propio repo sombra, identificado por un hash de su ruta.
_sombra_de() {
  local dir hash
  dir="$(cd "$1" 2>/dev/null && pwd)" || return 1
  hash="$(printf '%s' "$dir" | sha1sum | cut -c1-16)"
  printf '%s/%s' "$SOMBRAS" "$hash"
}

_git_sombra() {
  local sombra="$1" dir="$2"; shift 2
  # --git-dir + --work-tree: el historial vive en la sombra y el contenido en la carpeta real.
  # Así se versiona un directorio sin dejarle un.git adentro.
  git --git-dir="$sombra" --work-tree="$dir" "$@"
}

_asegurar_repo() {
  local sombra="$1" dir="$2"
  [ -d "$sombra" ] && return 0
  mkdir -p "$sombra" || return 1
  git --git-dir="$sombra" init --quiet 2>/dev/null || return 1
  git --git-dir="$sombra" config user.email "mentis@local" 2>/dev/null
  git --git-dir="$sombra" config user.name "Mentis" 2>/dev/null
  # El.git propio del usuario NO se versiona: es suyo y además sería enorme.
  printf '.git/\nnode_modules/\n.mentis-obs/\n' > "$sombra/info/exclude" 2>/dev/null || true
}

DIR="${2:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "Uso: mentis-deshacer.sh {foto|listar|ver|volver} <dir> [...]" >&2; exit 2; }
SOMBRA="$(_sombra_de "$DIR")" || { echo "ERROR: no se pudo resolver $DIR" >&2; exit 2; }

case "${1:-}" in

  foto)
    MOTIVO="${3:-cambio}"
    _asegurar_repo "$SOMBRA" "$DIR" || { echo "ERROR: no se pudo preparar el repo sombra" >&2; exit 1; }
    _git_sombra "$SOMBRA" "$DIR" add -A. >/dev/null 2>&1 || true
    # --allow-empty: si no cambió nada desde la última foto, igual queda el punto de referencia
    # (con su motivo y su hora), que es lo que hace legible la lista después.
    if _git_sombra "$SOMBRA" "$DIR" commit --allow-empty -q -m "$MOTIVO" >/dev/null 2>&1; then
      printf '%s\n' "$(_git_sombra "$SOMBRA" "$DIR" rev-parse --short HEAD 2>/dev/null)"
    else
      echo "ERROR: no se pudo sacar la foto" >&2; exit 1
    fi
    ;;

  listar)
    [ -d "$SOMBRA" ] || { echo "(todavía no hay fotos de $DIR)"; exit 0; }
    _git_sombra "$SOMBRA" "$DIR" log --pretty=format:'%h  %ad  %s' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null | head -30
    echo
    ;;

  ver)
    ID="${3:-}"; [ -n "$ID" ] || { echo "Uso:... ver <dir> <id>" >&2; exit 2; }
    [ -d "$SOMBRA" ] || { echo "(no hay fotos de $DIR)"; exit 1; }
    _git_sombra "$SOMBRA" "$DIR" diff --stat "$ID" 2>/dev/null || {
      echo "ERROR: no existe la foto '$ID'" >&2; exit 1; }
    ;;

  volver)
    ID="${3:-}"; [ -n "$ID" ] || { echo "Uso:... volver <dir> <id>" >&2; exit 2; }
    [ -d "$SOMBRA" ] || { echo "ERROR: no hay fotos de $DIR" >&2; exit 1; }
    # ANTES de restaurar se saca una foto del estado actual: deshacer no puede ser una operación
    # sin vuelta atrás, o el remedio sería igual de peligroso que la enfermedad.
    _git_sombra "$SOMBRA" "$DIR" add -A. >/dev/null 2>&1 || true
    _git_sombra "$SOMBRA" "$DIR" commit --allow-empty -q -m "antes de volver a $ID" >/dev/null 2>&1 || true
    if _git_sombra "$SOMBRA" "$DIR" checkout "$ID" --. 2>/dev/null; then
      echo "Listo: los archivos que existían en la foto $ID volvieron a su contenido de entonces."
      # Se dice explícitamente qué NO hace. Los archivos creados DESPUÉS de la foto se dejan a
      # propósito: borrarlos sería más peligroso que útil -- en esa carpeta también trabaja el usuario,
      # y un "deshacer" que borra algo que él creó a mano es peor que el problema que resuelve.
      # Se listan para que decida él.
      # Se comparan contra la FOTO, no con ls-files --others: como antes de restaurar se hace un
      # `add -A`, los archivos que creó Mentis ya quedaron trackeados y no figuran como nuevos.
      # Lo que interesa es qué existe ahora que no existía en ese momento.
      NUEVOS="$(_git_sombra "$SOMBRA" "$DIR" diff --name-only --diff-filter=A "$ID" --. 2>/dev/null | head -10)"
      if [ -n "${NUEVOS// }" ]; then
        echo
        echo "OJO: los archivos creados DESPUÉS de esa foto NO se borraron (podrías haberlos hecho vos):"
        printf '  %s\n' $NUEVOS
        echo "Si alguno sobra, borralo a mano."
      fi
      echo
      echo "El estado que tenía hace un momento quedó guardado como otra foto, así que esto también se puede deshacer."
    else
      echo "ERROR: no se pudo volver a '$ID'" >&2; exit 1
    fi
    ;;

  *)
    echo "Uso: mentis-deshacer.sh {foto|listar|ver|volver} <dir> [motivo|id]" >&2
    exit 2
    ;;
esac
