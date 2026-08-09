#!/usr/bin/env bash
# mentis-memory.sh -- memoria persistente tipada de Mentis (a la par del sistema de memoria de
# Claude Code: archivos individuales con frontmatter + un indice liviano que se inyecta entero
# en cada turno; el contenido completo de cada memoria NO se infla en el prompt, solo el indice).
#
# Uso:
#   mentis-memory.sh save <tipo> <slug> <descripcion> <contenido...>
#   mentis-memory.sh list
#   mentis-memory.sh forget <slug>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMDIR="$HERE/memoria"
INDEX="$MEMDIR/indice.md"
mkdir -p "$MEMDIR"
[ -f "$INDEX" ] || printf '# Indice de memoria de Mentis\n\n' > "$INDEX"

CMD="${1:-}"; shift || true

case "$CMD" in
  save)
    TIPO="${1:-}"; SLUG="${2:-}"; DESC="${3:-}"; shift 3 2>/dev/null || true
    CONTENT="$*"
    if [[ ! "$TIPO" =~ ^(user|feedback|project|reference)$ ]]; then
      echo "ERROR: tipo invalido '$TIPO'. Usa user|feedback|project|reference." >&2
      exit 1
    fi
    SLUG="$(printf '%s' "$SLUG" | tr -cs 'a-zA-Z0-9-' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40 | sed 's/^-*//;s/-*$//')"
    if [ -z "$SLUG" ] || [ -z "$DESC" ] || [ -z "$CONTENT" ]; then
      echo "ERROR: uso: mentis-memory.sh save <tipo> <slug> <descripcion> <contenido>" >&2
      exit 1
    fi
    MFILE="$MEMDIR/$SLUG.md"
    {
      printf -- '---\n'
      printf 'name: %s\n' "$SLUG"
      printf 'description: %s\n' "$DESC"
      printf 'type: %s\n' "$TIPO"
      printf -- '---\n\n'
      printf '%s\n' "$CONTENT"
    } > "$MFILE"
    # actualiza el indice: saca la linea vieja de este slug (si existia) y agrega la nueva
    TMPIDX="$(mktemp)"
    grep -v "^- \[$SLUG\]" "$INDEX" > "$TMPIDX" 2>/dev/null || true
    printf -- '- [%s] (%s): %s\n' "$SLUG" "$TIPO" "$DESC" >> "$TMPIDX"
    mv "$TMPIDX" "$INDEX"
    echo "Guardado: $SLUG ($TIPO)"
    ;;
  list)
    if [ -s "$INDEX" ]; then cat "$INDEX"; else echo "(sin memorias guardadas)"; fi
    ;;
  forget)
    SLUG="${1:-}"
    SLUG="$(printf '%s' "$SLUG" | tr -cs 'a-zA-Z0-9-' '-' | tr '[:upper:]' '[:lower:]')"
    if [ -f "$MEMDIR/$SLUG.md" ]; then
      rm -f "$MEMDIR/$SLUG.md"
      TMPIDX="$(mktemp)"
      grep -v "^- \[$SLUG\]" "$INDEX" > "$TMPIDX" 2>/dev/null || true
      mv "$TMPIDX" "$INDEX"
      echo "Olvidado: $SLUG"
    else
      echo "No existe una memoria con el nombre '$SLUG' (usa 'list' para ver los nombres)"
    fi
    ;;
  *)
    echo "Uso: mentis-memory.sh save|list|forget..." >&2
    exit 1
    ;;
esac
