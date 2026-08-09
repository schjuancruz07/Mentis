#!/usr/bin/env bash
# mentis-doc-gen.sh -- genera un documento real con formato (docx/pdf/pptx/xlsx) a partir de
# contenido en markdown liviano (ver docgen.py para las convenciones). Usa python-docx,
# reportlab, python-pptx y openpyxl (locales, sin llamar a ningun modelo).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT=""; KIND=""
while getopts ":o:k:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    k) KIND="$OPTARG" ;;
    *) echo "ERROR: opcion invalida"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
CONTENT="$*"

if [ -z "$OUT" ]; then
  echo "ERROR: falta -o <ruta_de_salida>"
  exit 1
fi
if [ -z "$KIND" ]; then
  case "$OUT" in
    *.docx) KIND="docx" ;;
    *.pdf)  KIND="pdf" ;;
    *.pptx) KIND="pptx" ;;
    *.xlsx) KIND="xlsx" ;;
    *) echo "ERROR: falta -k <docx|pdf|pptx|xlsx> (no se pudo inferir de la extension)"; exit 1 ;;
  esac
fi
if [ -z "${CONTENT// }" ]; then
  echo "ERROR: falta el contenido (markdown liviano: # titulo, ## subtitulo, - vinieta)"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
if ! printf '%s' "$CONTENT" | python3 "$HERE/docgen.py" "$KIND" "$OUT" 2>/tmp/mentis-docgen-err.$$; then
  echo "ERROR: fallo la generacion del documento: $(cat /tmp/mentis-docgen-err.$$ 2>/dev/null)"
  rm -f /tmp/mentis-docgen-err.$$
  exit 1
fi
rm -f /tmp/mentis-docgen-err.$$
printf '%s\n' "$OUT"
exit 0
