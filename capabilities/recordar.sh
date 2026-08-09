# CAPABILITY: /recordar | guarda una nota persistente y tipada que Mentis recuerda en futuras conversaciones
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMSCRIPT="$HERE/mentis-memory.sh"
TEXT="$1"

if [ -z "${TEXT// }" ]; then
  echo "Uso: /recordar <texto a recordar>. Para ver lo guardado: /recordar listar. Para borrar: /recordar olvidar <nombre>."
  exit 0
fi
if [ "$TEXT" = "listar" ]; then
  bash "$MEMSCRIPT" list
  exit 0
fi
if [[ "$TEXT" == olvidar\ * ]]; then
  bash "$MEMSCRIPT" forget "${TEXT#olvidar }"
  exit 0
fi

SLUG="$(printf '%s' "$TEXT" | tr -cs 'a-zA-Z0-9' '-' | cut -c1-30 | sed 's/^-*//;s/-*$//')-$(date +%s)"
DESC="$(printf '%s' "$TEXT" | cut -c1-80)"
bash "$MEMSCRIPT" save user "$SLUG" "$DESC" "$TEXT"
