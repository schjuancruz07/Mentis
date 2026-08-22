# CAPABILITY: /imagenes | busca entre tus imagenes por lo que se ve en ellas, no por el nombre
# Envoltorio de mentis-imagenes.sh para que aparezca en el Directorio -> Habilidades.
#
# QUE HACE POR DEBAJO: le pide al rol multimodal una descripcion de cada imagen y la indexa con el
# mismo buscador por significado que usa Kai Vault. Por eso se puede pedir "la captura donde
# estaba el error de la camara" sin que el archivo se llame asi.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGS="${1:-}"
CMD="$HERE/mentis-imagenes.sh"

case "${ARGS%% *}" in
  ""|ayuda)
    echo "Uso:"
    echo "  /imagenes indexar [carpeta]  -- mira las imagenes nuevas (cuesta una llamada por imagen)"
    echo "  /imagenes <lo que busco>     -- busca por lo que se ve"
    echo "  /imagenes estado             -- cuantas hay indexadas"
    echo
    echo "Ejemplo: /imagenes la captura donde salia el error de la camara"
    ;;
  indexar)
    CARPETA="${ARGS#indexar}"
    CARPETA="${CARPETA# }"
    if [ -n "${CARPETA// }" ]; then bash "$CMD" indexar "$CARPETA"; else bash "$CMD" indexar; fi ;;
  estado) bash "$CMD" estado ;;
  *)
    # Todo lo demas se toma como la consulta. Es lo natural: quien escribe "/imagenes el grafico
    # de barras" quiere buscar eso, no aprender una sintaxis.
    bash "$CMD" buscar "$ARGS" ;;
esac
