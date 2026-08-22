# CAPABILITY: /mirar | te mira hacer una tarea y la convierte en una habilidad nueva
# Envoltorio de mentis-aprender-mirando.sh para que aparezca en el Directorio -> Habilidades y
# Mentis pueda ofrecerla. La logica vive en el script de la raiz; aca solo se traduce el pedido.
#
# POR QUE UNA SKILL Y NO UN BOTON NUEVO EN LA APP: el Directorio se llena solo leyendo la primera
# linea de cada archivo de capabilities/. Agregando el archivo, la habilidad aparece en la lista,
# se puede buscar, y respeta el filtro por modo -- todo sin tocar una linea del renderer. Un boton
# aparte habria hecho lo mismo con codigo propio que despues hay que mantener sincronizado.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGS="${1:-}"
CMD="$HERE/mentis-aprender-mirando.sh"

case "${ARGS%% *}" in
  ""|ayuda)
    echo "Uso:"
    echo "  /mirar empezar            -- empieza a mirar lo que hacés"
    echo "  /mirar listo              -- deja de mirar y te muestra los pasos"
    echo "  /mirar pasos              -- ver la ultima grabacion"
    echo "  /mirar habilidad <nombre> -- convertir esa grabacion en una habilidad"
    echo
    echo "NO guarda lo que escribís: solo la secuencia (que ventana, que clic, que tecla)."
    ;;
  empezar|grabar|arrancar) bash "$CMD" grabar ;;
  listo|frenar|parar|terminar) bash "$CMD" frenar ;;
  pasos|ver) bash "$CMD" ver ;;
  habilidad|skill)
    NOMBRE="${ARGS#* }"
    if [ -z "${NOMBRE// }" ] || [ "$NOMBRE" = "$ARGS" ]; then
      echo "Falta el nombre. Ejemplo: /mirar habilidad renombrar-facturas" >&2
      exit 2
    fi
    bash "$CMD" skill "$NOMBRE" ;;
  estado) bash "$CMD" estado ;;
  *)
    echo "No entiendo '/mirar $ARGS'. Probá: /mirar ayuda" >&2
    exit 2 ;;
esac
