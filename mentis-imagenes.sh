#!/usr/bin/env bash
# mentis-imagenes.sh -- buscar imagenes por lo que SE VE en ellas, no por el nombre del archivo.
#
# Uso:
#   mentis-imagenes.sh indexar [carpeta...]   # describe las imagenes nuevas y las deja buscables
#   mentis-imagenes.sh buscar "<lo que busco>"
#   mentis-imagenes.sh estado
#
# DE DONDE SALE ESTA IDEA: del documento de especificaciones que el usuario armo con Gemini (2026-08-22).
# De las diez cosas que ese documento proponia, nueve ya existian o ya se habian medido y
# descartado. Esta era la unica que Mentis no tenia, y por eso es la unica que se construyo.
#
# POR QUE NO SE USA CLIP, QUE ES LO QUE EL DOCUMENTO PEDIA: CLIP necesita torch y un modelo local
# de mas de un giga. Esta maquina tiene 8 GB de RAM en total y ~1 GB libre (medido el 2026-08-22).
# No entra, y forzarlo dejaria a Mentis compitiendo por memoria con lo que ya corre.
#
# QUE SE HACE EN SU LUGAR: se le pide al rol multimodal -- que Mentis YA tiene y ya esta medido --
# una descripcion de cada imagen, y esa descripcion se indexa con el MISMO buscador por significado
# que usa Kai Vault (nemotron-3-embed-1b, 14/15 de acierto en su medicion). Resultado practico
# equivalente: se busca "la captura donde salia el error de la camara" y aparece. Diferencia
# honesta: si la descripcion no menciono un detalle, ese detalle no se puede buscar. CLIP no tiene
# esa limitacion; a cambio, no entra en esta computadora.
#
# CUESTA UNA LLAMADA POR IMAGEN, Y UNA SOLA VEZ: lo ya descrito no se vuelve a describir. La marca
# es ruta + fecha de modificacion + tamanio, asi que una imagen editada si se vuelve a mirar.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/memoria/imagenes"
CORPUS="$BASE/corpus"
REGISTRO="$BASE/descripciones.jsonl"
TOPE="${MENTIS_IMG_TOPE:-40}"   # imagenes nuevas por corrida; evita gastar una tarde sin querer

mkdir -p "$CORPUS"
touch "$REGISTRO"

_carpetas_por_defecto() {
  printf '%s\n' "$HERE/workspace" "$HERE/empresa" "$HERE/avatar"
}

_ya_esta() {  # _ya_esta <ruta> <marca>
  grep -qF "\"marca\":\"$2\"" "$REGISTRO" 2>/dev/null
}

_marca_de() {
  local f="$1" mt tam
  mt="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  tam="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  printf '%s|%s|%s' "$f" "$mt" "$tam"
}

case "${1:-}" in
  indexar)
    shift
    CARPETAS=("$@")
    [ "${#CARPETAS[@]}" -eq 0 ] && mapfile -t CARPETAS < <(_carpetas_por_defecto)
    NUEVAS=0; SALTEADAS=0; FALLADAS=0
    for dir in "${CARPETAS[@]}"; do
      [ -d "$dir" ] || continue
      while IFS= read -r img; do
        [ -f "$img" ] || continue
        [ "$NUEVAS" -ge "$TOPE" ] && break 2
        marca="$(_marca_de "$img")"
        if _ya_esta "$img" "$marca"; then SALTEADAS=$((SALTEADAS + 1)); continue; fi
        desc="$(timeout 180 bash "$HERE/engine/ask-nvidia.sh" -I "$img" multimodal \
                "Describi esta imagen para poder encontrarla despues buscandola con palabras. Deci que se ve, que texto aparece si hay texto, y de que parece tratarse. Tres o cuatro frases, sin preambulo." 2>/dev/null \
                | grep -v '^AVISO:' | tr '\n' ' ' | sed 's/  */ /g')"
        if [ -z "${desc// }" ]; then
          FALLADAS=$((FALLADAS + 1))
          echo "  no se pudo describir: $(basename "$img")" >&2
          continue
        fi
        # Un.md por imagen: es lo que el indexador sabe leer, y deja la descripcion a la vista
        # para poder corregirla a mano si dice cualquier cosa.
        clave="$(printf '%s' "$img" | md5sum | cut -d' ' -f1)"
        {
          echo "# $(basename "$img")"
          echo
          echo "Archivo: $img"
          echo
          echo "$desc"
        } > "$CORPUS/$clave.md"
        # El registro va en JSON compacto para que el grep -F de _ya_esta funcione literal.
        python3 -c '
import json, sys
print(json.dumps({"ruta": sys.argv[1], "marca": sys.argv[2], "clave": sys.argv[3],
                  "descripcion": sys.argv[4]}, ensure_ascii=False, separators=(",", ":")))
' "$img" "$marca" "$clave" "$desc" >> "$REGISTRO"
        NUEVAS=$((NUEVAS + 1))
        echo "  descrita: $(basename "$img")"
      done < <(find "$dir" -maxdepth 3 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null)
    done
    echo
    echo "nuevas: $NUEVAS   ya estaban: $SALTEADAS   fallaron: $FALLADAS"
    if [ "$NUEVAS" -gt 0 ]; then
      echo "Indexando para poder buscarlas..."
      bash "$HERE/engine/nv-index.sh" -x "md" "$CORPUS" 2>&1 | tail -2
    fi ;;

  buscar)
    CONSULTA="${2:-}"
    [ -n "$CONSULTA" ] || { echo "Uso: mentis-imagenes.sh buscar \"<lo que busco>\"" >&2; exit 2; }
    SAL="$(bash "$HERE/engine/nv-search.sh" -k "${3:-5}" -d "$CORPUS" -- "$CONSULTA" 2>&1)"; RC=$?
    case "$RC" in
      3) echo "Todavia no hay nada indexado. Corre primero: mentis-imagenes.sh indexar" ; exit 3 ;;
      4) echo "La busqueda no pudo hablar con el servicio de embeddings (sin red o saturado)." ; exit 4 ;;
      5) echo "El indice se armo con otro modelo de embeddings. Volve a correr: mentis-imagenes.sh indexar" ; exit 5 ;;
    esac
    # De cada fragmento se rescatan el nombre y la ruta real de la imagen.
    # OJO CON LA INDENTACION: nv-search.sh imprime el contenido del fragmento con cuatro espacios
    # adelante. Un patron anclado en '^Archivo:' no encuentra NADA, y el sintoma es una busqueda
    # que funciona pero no muestra un solo resultado -- parece que no encontro, cuando en realidad
    # encontro y no supo leerlo. (Paso al construir esto, 2026-08-22.)
    printf '%s\n' "$SAL" | sed -n \
      -e 's/^[[:space:]]*# \(.*\)$/\
IMAGEN: \1/p' \
      -e 's/^[[:space:]]*Archivo: \(.*\)$/  ruta: \1/p'
    echo
    echo "(descripciones completas en memoria/imagenes/corpus/)" ;;

  estado)
    N="$(grep -c. "$REGISTRO" 2>/dev/null)"; N="${N:-0}"
    M="$(ls "$CORPUS"/*.md 2>/dev/null | grep -c.)"; M="${M:-0}"
    echo "imagenes descritas: $N"
    echo "fichas en el corpus: $M" ;;

  *)
    echo "Uso: mentis-imagenes.sh indexar [carpeta...] | buscar \"<texto>\" [cuantas] | estado" >&2
    exit 2 ;;
esac
