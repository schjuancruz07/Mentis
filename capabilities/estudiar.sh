# CAPABILITY: /estudiar | administra tu material de estudio (el corpus cerrado del modo Mentis Study). "/estudiar sumar <archivo> [materia]" mete un PDF/Word/apunte al corpus; "/estudiar materias" lista lo que tenés; "/estudiar salud" dice si el índice está vivo; "/estudiar olvidar <materia>" la saca de circulación.
#
# POR QUE EXISTE (2026-08-12): el modo Study estaba declarado en modos.json desde el 2026-08-10
# -- tenia persona, banderas y paneles -- pero no tenia CORPUS. Prometia "responde solo desde lo
# que le diste" sin que existiera ningun lugar donde el usuario pudiera darle algo. Este script es esa
# pieza: la puerta de entrada del material y el unico que toca el indice del corpus.
#
# QUE NO HACE: no inventa un indexador ni un extractor de PDFs. El indice semantico es el mismo
# nv-index.sh/nv-search.sh que ya usa Kai Vault (embeddings de NVIDIA, probados en esta maquina),
# y el texto de los binarios lo saca engine/doc_extract.py, que ya leia.pdf/.docx/.pptx/.xlsx
# para la tool 'read'. Lo unico nuevo aca es la carpeta, el rotulo y el ciclo de vida.
#
# LA RUTA DEL CORPUS SALE DE modos.json, NO DE UNA CONSTANTE ACA. Si estuviera escrita en los dos
# lados, el dia que alguien la cambie en uno solo el buscador y el indexador quedan mirando
# carpetas distintas y Study contesta "no esta en lo que me diste" sobre material que el usuario si le
# dio -- una falla que se lee como si el modo funcionara.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLSDIR="$HERE/engine"
# shellcheck source=/dev/null
source "$TOOLSDIR/nv-modos-lib.sh"

CORPUS="$(nv_modo_corpus study 2>/dev/null)"
if [ -z "${CORPUS// }" ]; then
  echo "ERROR: el modo 'study' no declara 'corpus' en modos.json. Sin eso no hay donde guardar el material."
  exit 2
fi
# Fuera del corpus a proposito: lo que se olvida no se borra (es material del usuario, no mio), pero
# tampoco puede quedar adentro de la carpeta que se indexa.
PAPELERA="$HERE/knowledge/.estudio-olvidado"

_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'; }

_ayuda() {
  cat <<'AYUDA'
/estudiar -- tu material de estudio para el modo Mentis Study.

  /estudiar sumar <archivo> [materia]   suma un PDF, Word, PowerPoint, Excel,.md o.txt al corpus.
                                        Si no decis materia, va a "general".
  /estudiar materias                    que materias tenes y cuantas fuentes cada una.
  /estudiar salud                       si el indice esta vivo y de cuando es.
  /estudiar reindexar                   reconstruye el indice (corrilo si sumaste algo a mano).
  /estudiar olvidar <materia>           la saca del corpus (se mueve, no se borra) y reindexa.

En el modo Study, Mentis responde SOLO con esto y cita el archivo de donde lo saco. Si algo no
esta aca, va a decirte que no esta -- aunque lo sepa por otro lado. Esa es la idea del modo.
AYUDA
}

# Donde vive el indice de ESTE corpus. El hash se calcula igual que en nv-index.sh y nv-search.sh
# (ruta|modelo|), y el modelo sale de nv-lib.sh: escribir un default distinto aca es como se
# termina mirando un archivo que no es el que se usa.
_ruta_indice() {
  # shellcheck source=/dev/null
  source "$TOOLSDIR/nv-lib.sh" 2>/dev/null
  local modelo clave
  modelo="${NV_EMB_MODEL:-nvidia/nemotron-3-embed-1b}"
  clave="$(printf '%s|' "$CORPUS" "$modelo" | md5sum | cut -d' ' -f1)"
  printf '%s/%s.jsonl' "${NV_INDEXDIR:-$TOOLSDIR/index}" "$clave"
}

# Reindexa el corpus entero. Se llama despues de cada cambio: un corpus cuyo indice quedo viejo
# es la version silenciosa del mismo problema que tuvo Kai Vault 8 dias (2026-07-26) -- contesta
# sin error sobre material que ya no es el que hay.
_reindexar() {
  if [ -z "$(find "$CORPUS" -type f \( -name '*.txt' -o -name '*.md' \) -print -quit 2>/dev/null)" ]; then
    # OJO, ESTE CASO YA FALLO (2026-08-12, medido): con el corpus vacio, nv-index.sh no tiene
    # nada que indexar y corta con error, asi que el indice VIEJO se quedaba en disco intacto.
    # Resultado: /estudiar olvidar decia "Mentis ya no va a responder con ese material" y Mentis
    # lo seguia encontrando. El indice hay que BORRARLO, no dejar de escribirlo. Con al menos un
    # archivo esto no pasa: nv_index.py rearma la lista entera y los borrados desaparecen solos.
    local idx; idx="$(_ruta_indice)"
    rm -f "$idx" "${idx%.jsonl}.vecs.npy" 2>/dev/null
    echo "El corpus quedo vacio: se borro el indice (Mentis ya no encuentra nada de estudio)."
    return 0
  fi
  local salida rc
  salida="$(bash "$TOOLSDIR/nv-index.sh" -x "md txt" "$CORPUS" 2>&1)"; rc=$?
  printf '%s\n' "$salida" | tail -3
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: el indice del corpus NO se reconstruyo. Study no va a poder responder con este material."
    return 1
  fi
  return 0
}

MODE="${1:-}"
case "$MODE" in
  ""|ayuda|help|-h) _ayuda; exit 0 ;;

  sumar|agregar|add)
    ARCHIVO="${2:-}"
    MATERIA="$(_norm "${3:-general}")"
    [ -n "$MATERIA" ] || MATERIA="general"
    if [ -z "${ARCHIVO// }" ]; then
      echo "Uso: /estudiar sumar <archivo> [materia]"; exit 2
    fi
    if [ ! -f "$ARCHIVO" ]; then
      echo "No existe el archivo: $ARCHIVO"; exit 1
    fi

    DESTDIR="$CORPUS/$MATERIA"
    mkdir -p "$DESTDIR" || { echo "No pude crear $DESTDIR"; exit 1; }
    BASE="$(basename "$ARCHIVO")"
    EXT="$(printf '%s' "${BASE##*.}" | tr 'A-Z' 'a-z')"

    case "$EXT" in
      txt|md)
        # Ya es texto: se copia tal cual y se conserva el nombre, que es lo que Mentis va a citar.
        cp -- "$ARCHIVO" "$DESTDIR/$BASE" || { echo "No pude copiar el archivo."; exit 1; }
        DEST="$DESTDIR/$BASE"
        ;;
      pdf|docx|pptx|xlsx)
        # --max-img 0: las imagenes de un apunte no entran al indice de texto, y extraerlas
        # costaria una llamada al modelo multimodal por cada una sin que nadie las busque.
        DEST="$DESTDIR/$BASE.txt"
        TEXTO="$(python3 "$TOOLSDIR/doc_extract.py" "$ARCHIVO" --max-img 0 2>&1)"; RC=$?
        if [ "$RC" -ne 0 ] || [ -z "${TEXTO// }" ]; then
          echo "No pude sacar el texto de $BASE:"
          printf '%s\n' "$TEXTO" | head -3
          exit 1
        fi
        printf '%s\n' "$TEXTO" > "$DEST" || { echo "No pude escribir $DEST"; exit 1; }
        ;;
      *)
        echo "No se que hacer con un.$EXT. El corpus acepta: pdf, docx, pptx, xlsx, md, txt."
        exit 2
        ;;
    esac

    PALABRAS="$(wc -w < "$DEST" | tr -d ' ')"
    if [ "${PALABRAS:-0}" -lt 20 ]; then
      # Un PDF escaneado (imagenes de texto, sin capa de texto) pasa por doc_extract sin error y
      # deja un archivo casi vacio. Si eso entra al corpus, Study contesta "no esta en lo que me
      # diste" y el usuario no tiene forma de saber que el problema fue el archivo y no el modo.
      echo "AVISO: de $BASE salieron solo $PALABRAS palabras."
      echo "Si es un PDF escaneado (fotos de las hojas) no tiene texto adentro y asi no sirve para estudiar."
      echo "Lo dejo igual en $MATERIA, pero revisalo."
    fi

    echo "Sumado a '$MATERIA': $BASE ($PALABRAS palabras)."
    _reindexar || exit 1
    echo "Listo. En el modo Mentis Study ya puede responder sobre esto."
    ;;

  materias|lista|ls)
    if [ ! -d "$CORPUS" ] || [ -z "$(ls -A "$CORPUS" 2>/dev/null)" ]; then
      echo "Todavia no tenes material cargado. Empeza con: /estudiar sumar <archivo> <materia>"
      exit 0
    fi
    echo "Tu material de estudio ($CORPUS):"
    for d in "$CORPUS"/*/; do
      [ -d "$d" ] || continue
      n="$(find "$d" -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' ')"
      w="$(cat "$d"/*.txt "$d"/*.md 2>/dev/null | wc -w | tr -d ' ')"
      printf '  %-24s %s fuentes, %s palabras\n' "$(basename "$d")" "$n" "${w:-0}"
    done
    ;;

  salud|estado)
    echo "== Corpus de estudio =="
    echo "  Carpeta: $CORPUS"
    TOTAL="$(find "$CORPUS" -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Fuentes: ${TOTAL:-0}"
    echo
    echo "== Indice semantico =="
    IDX="$(_ruta_indice)"
    MODELO="${NV_EMB_MODEL:-nvidia/nemotron-3-embed-1b}"
    if [ -s "$IDX" ] && [ -s "${IDX%.jsonl}.vecs.npy" ]; then
      echo "  Estado: OK"
      echo "  Fragmentos: $(wc -l < "$IDX" | tr -d ' ')"
      echo "  Ultima actualizacion: $(date -r "$IDX" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
      echo "  Modelo: $MODELO"
    else
      echo "  Estado: SIN INDICE -- en modo Study no va a encontrar nada."
      echo "  Solucion: /estudiar reindexar"
    fi
    ;;

  reindexar)
    echo "Reconstruyendo el indice del corpus de estudio..."
    _reindexar || exit 1
    echo "Listo."
    ;;

  olvidar)
    MATERIA="$(_norm "${2:-}")"
    if [ -z "$MATERIA" ]; then echo "Uso: /estudiar olvidar <materia>"; exit 2; fi
    ORIGEN="$CORPUS/$MATERIA"
    if [ ! -d "$ORIGEN" ]; then
      echo "No tenes ninguna materia que se llame '$MATERIA'. Mirá /estudiar materias."
      exit 1
    fi
    # Se MUEVE, no se borra: es material del usuario y el costo de equivocarse es perderlo. El sello
    # de fecha evita pisar un olvido anterior de la misma materia.
    mkdir -p "$PAPELERA"
    DESTINO="$PAPELERA/$MATERIA-$(date '+%Y%m%d-%H%M%S')"
    mv "$ORIGEN" "$DESTINO" || { echo "No pude mover $ORIGEN"; exit 1; }
    echo "'$MATERIA' salio del corpus. No se borro: quedo en $DESTINO."
    _reindexar || exit 1
    echo "Indice actualizado: Mentis ya no va a responder con ese material."
    ;;

  *)
    echo "No conozco '$MODE'."
    echo
    _ayuda
    exit 2
    ;;
esac
