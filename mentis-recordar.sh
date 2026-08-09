#!/usr/bin/env bash
# mentis-recordar.sh -- memoria de lo CONVERSADO (2026-07-27).
#
# POR QUE EXISTE:
#   Kai Vault (nv-index/nv-search) indexa ARCHIVOS. Las conversaciones con el usuario no estaban en
#   ningun indice: si el le preguntaba "que habiamos decidido sobre X", Mentis no tenia forma de
#   saberlo -- se comprobo buscando referencias a conversations/ en nv-agent.sh y hay cero.
#   Todo lo hablado en semanas era, para Mentis, inaccesible.
#
#   La idea es de Hermes (su `session_search`), pero la implementacion NO se copia: se reusa la
#   maquinaria de embeddings que Mentis ya tiene medida y andando (nemotron-3-embed-1b, 14/15
#   aciertos, busqueda hibrida densa+lexica). Lo unico que se agrega es el puente.
#
# COMO FUNCIONA:
#   Las conversaciones son JSONL con {"role","text","ts"}. Indexar ese crudo meteria comillas y
#   nombres de campo en los embeddings -- puro ruido. Asi que primero se traduce cada una a un
#.txt legible ("[fecha] el usuario:..."), y ESO es lo que se indexa. Dos ventajas: el chunking cae
#   sobre texto natural, y las citas que devuelve ya salen con fecha y quien lo dijo.
#
#   El corpus se regenera solo si la conversacion cambio (compara mtime), y el indexado ya es
#   incremental por hash, asi que reindexar cuesta casi nada.
#
# Uso:
#   mentis-recordar.sh indexar            -> actualiza el corpus y el indice
#   mentis-recordar.sh "que dijimos de X" -> busca y devuelve pasajes con fecha
#   mentis-recordar.sh salud              -> estado del indice
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mismo blindaje que el resto: lanzado por Electron o el Programador de tareas, el PATH puede
# venir sin /usr/bin y no existirian ni `date` ni `find` (ERR-073).
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

CONVS="${MENTIS_CONVS:-$HERE/conversations}"
CORPUS="${MENTIS_RECALL_CORPUS:-$HERE/engine/recall-corpus}"
INDICE="${MENTIS_RECALL_INDEX:-$HERE/engine/recall-index.jsonl}"
CUANTOS="${MENTIS_RECALL_K:-6}"
MEMDIR="${MENTIS_MEMDIR:-$HERE/memoria}"
INDICE_MEM="${MENTIS_MEM_INDEX:-$HERE/engine/memorias-index.jsonl}"

# --memorias: busca entre las MEMORIAS ya guardadas en vez de entre las conversaciones.
# Lo usa la regla 4 del learning loop (mentis-aprender.sh): antes de guardar algo nuevo, hay que
# poder preguntar "¿esto ya lo sé?" por SIGNIFICADO. Preguntarlo por nombre de archivo no sirve:
# las tres memorias duplicadas del 2026-07-27 tenían slugs distintos y decían lo mismo.
if [ "${1:-}" = "--memorias" ]; then
  shift
  [ -d "$MEMDIR" ] || { echo "ERROR: no existe $MEMDIR" >&2; exit 2; }
  # El índice de memorias se rehace si alguna cambió después de la última vez: son pocas y
  # chicas, así que sale mucho más barato que llevar la cuenta de cuál se tocó.
  if [ ! -f "$INDICE_MEM" ] || [ -n "$(find "$MEMDIR" -name '*.md' -newer "$INDICE_MEM" -print -quit 2>/dev/null)" ]; then
    bash "$HERE/engine/nv-index.sh" -x "md" -o "$INDICE_MEM" "$MEMDIR" >/dev/null 2>&1 || exit 0
  fi
  # -k 1: sólo interesa la más parecida. Y se filtra el índice, que no es una memoria sino la
  # lista de todas -- se parece a cualquier consulta y arruinaría la comparación.
  bash "$HERE/engine/nv-search.sh" -k 3 -i "$INDICE_MEM" -- "$*" 2>/dev/null | grep -v '^indice\.md' | head -20
  exit 0
fi

_construir_corpus() {
  [ -d "$CONVS" ] || { echo "ERROR: no existe el directorio de conversaciones: $CONVS" >&2; return 2; }
  mkdir -p "$CORPUS" || return 2
  python3 "$HERE/engine/recall_corpus.py" --entrada "$CONVS" --salida "$CORPUS"
}

case "${1:-}" in
  indexar)
    _construir_corpus || exit $?
    # --completo no: el indice incremental por hash es justamente lo que hace barato esto.
    bash "$HERE/engine/nv-index.sh" -x "txt" -o "$INDICE" "$CORPUS" || exit $?
    echo "listo: $(wc -l < "$INDICE" 2>/dev/null || echo 0) fragmentos indexados"
    ;;
  salud)
    if [ -f "$INDICE" ]; then
      echo "indice: $INDICE"
      echo "fragmentos: $(wc -l < "$INDICE")"
      echo "conversaciones en corpus: $(find "$CORPUS" -name '*.txt' 2>/dev/null | wc -l)"
      echo "ultima actualizacion: $(date -r "$INDICE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    else
      echo "sin indice todavia -- corre: mentis-recordar.sh indexar"
      exit 1
    fi
    ;;
  "")
    echo "Uso: mentis-recordar.sh {indexar|salud|\"consulta\"}" >&2
    exit 2
    ;;
  *)
    # Buscar. Si nunca se indexo, se indexa solo en vez de fallar: la primera pregunta del usuario
    # no tiene por que perderse por un paso de instalacion que el nunca vio.
    if [ ! -f "$INDICE" ]; then
      echo "(primera vez: armando el indice de conversaciones, esto tarda un momento)" >&2
      _construir_corpus >/dev/null 2>&1
      bash "$HERE/engine/nv-index.sh" -x "txt" -o "$INDICE" "$CORPUS" >/dev/null 2>&1 || {
        echo "ERROR: no se pudo armar el indice de conversaciones" >&2; exit 2; }
    fi
    bash "$HERE/engine/nv-search.sh" -k "$CUANTOS" -i "$INDICE" -- "$*"
    ;;
esac
