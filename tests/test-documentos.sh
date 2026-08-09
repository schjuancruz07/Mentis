#!/usr/bin/env bash
# test-documentos.sh -- leer documentos con imagenes adentro (B1, 2026-08-03).
#
# QUE CAMBIO: la tool 'read' rechazaba de plano cualquier archivo binario. Un.docx ES binario,
# asi que Mentis no podia leer un Word en absoluto -- ni su texto. Y cuando el usuario le pasaba un
# informe con graficos, las imagenes no existian para ella: contestaba sobre el texto como si el
# documento no tuviera nada mas.
#
# QUE SE PRUEBA:
#   - Que los cuatro formatos den texto (deterministico, corre siempre).
#   - Que las imagenes salgan EN SU LUGAR dentro del texto, no en una lista aparte. Si se
#     listaran al final se pierde donde estaba cada una, y "el grafico de abajo" deja de tener
#     sentido -- que es justo lo que el usuario quiere poder preguntar.
#   - Que las rutas que emite las pueda abrir BASH. Python en Windows devuelve
#     "C:/Users/...\img-1.png" con separadores mezclados, y quien consume esas rutas es bash.
#   - Con -v: que un modelo real describa de verdad lo que hay en la imagen.
set -uo pipefail
TD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD_ROOT="$(cd "$TD_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TD_VIVO=0; [ "${1:-}" = "-v" ] && TD_VIVO=1
TD_OK=0; TD_MAL=0
_ok()  { TD_OK=$((TD_OK+1));  echo "  OK   $1"; }
_mal() { TD_MAL=$((TD_MAL+1)); echo "  MAL  $1  ($2)"; }

EXTRACT="$TD_ROOT/engine/doc_extract.py"
AGENTE="$TD_ROOT/engine/nv-agent.sh"
[ -f "$EXTRACT" ] || { echo "ABORTA: no existe $EXTRACT" >&2; exit 1; }

TD_TMP="$(mktemp -d)"
case "$TD_TMP" in "$TD_ROOT"|"$TD_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TD_TMP"' EXIT

# Las rutas van a python como ARGUMENTO y convertidas con cygpath (ERR-006 + ERR-069): python en
# esta maquina no abre rutas /c/..., y una ruta interpolada dentro de un script -c se rompe con
# el primer espacio o backslash.
_py() { python3 "$@"; }
_win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

echo "== documentos con imagenes =="
echo "-- A. se arman los documentos de prueba"

_py - "$(_win "$TD_TMP")" <<'PY'
import os, random, sys
D = sys.argv[1]
from PIL import Image, ImageDraw
img = Image.new("RGB", (640, 420), "white")
d = ImageDraw.Draw(img)
random.seed(7)
colores = ["#c0392b", "#2980b9", "#27ae60", "#8e44ad", "#f39c12", "#16a085"]
for i, (m, h) in enumerate(zip(["Ene","Feb","Mar","Abr","May","Jun"], [120,200,160,280,240,330])):
    x = 60 + i*95
    d.rectangle([x, 380-h, x+70, 380], fill=colores[i], outline="black", width=2)
    d.text((x+18, 388), m, fill="black")
d.text((200, 12), "VENTAS MENSUALES 2026", fill="black")
px = img.load()
for _ in range(9000):
    x = random.randrange(640); y = random.randrange(420)
    r, g, b = px[x, y]; px[x, y] = (max(0,r-6), max(0,g-6), max(0,b-6))
p = os.path.join(D, "grafico.png"); img.save(p)

from docx import Document
doc = Document()
doc.add_paragraph("ANTES DEL GRAFICO")
doc.add_picture(p)
doc.add_paragraph("DESPUES DEL GRAFICO")
t = doc.add_table(rows=2, cols=2)
t.cell(0,0).text = "Mes"; t.cell(0,1).text = "Ventas"
t.cell(1,0).text = "Junio"; t.cell(1,1).text = "1650"
doc.save(os.path.join(D, "doc.docx"))

from pptx import Presentation
from pptx.util import Inches
pres = Presentation(); s = pres.slides.add_slide(pres.slide_layouts[5])
s.shapes.title.text = "TITULO DE LA DIAPO"
s.shapes.add_picture(p, Inches(1), Inches(2), width=Inches(5))
pres.save(os.path.join(D, "pres.pptx"))

import openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Ventas"
ws.append(["Mes", "Ventas"]); ws.append(["Julio", 1500])
wb.save(os.path.join(D, "hoja.xlsx"))

import fitz
pdf = fitz.open(); pg = pdf.new_page()
pg.insert_text((72, 72), "TEXTO DEL PDF")
pg.insert_image(fitz.Rect(72, 100, 472, 362), filename=p)
pdf.save(os.path.join(D, "doc.pdf")); pdf.close()
print("listo")
PY
[ -f "$TD_TMP/doc.docx" ] && _ok "A1 se generaron los 4 documentos de prueba con una imagen real" \
                          || { _mal "A1 documentos de prueba" "no se generaron"; echo; echo "== $TD_OK OK, $TD_MAL MAL =="; exit 1; }

echo "-- B. extraccion de los cuatro formatos"

_extraer() { _py "$EXTRACT" "$(_win "$TD_TMP/$1")" --imgdir "$(_win "$TD_TMP/medios")" --json 2>/dev/null; }
_campo() { printf '%s' "$1" | _py -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]) if sys.argv[1]!="imagenes" else "\n".join(d.get("imagenes",[])))' "$2" 2>/dev/null; }

for par in "doc.docx:ANTES DEL GRAFICO" "pres.pptx:TITULO DE LA DIAPO" "hoja.xlsx:Julio" "doc.pdf:TEXTO DEL PDF"; do
  ARCH="${par%%:*}"; ESPERADO="${par#*:}"
  J="$(_extraer "$ARCH")"
  T="$(_campo "$J" texto)"
  if printf '%s' "$T" | grep -q "$ESPERADO"; then
    _ok "B: $ARCH -> saca el texto ('$ESPERADO')"
  else
    _mal "B: $ARCH texto" "no aparece '$ESPERADO'"
  fi
done

# La tabla del docx tambien: es contenido que se perdia entero.
J_DOCX="$(_extraer doc.docx)"
printf '%s' "$(_campo "$J_DOCX" texto)" | grep -q "Junio | 1650" \
  && _ok "B5 las tablas del docx salen como texto legible" \
  || _mal "B5 tablas del docx" "no aparece la fila de la tabla"

echo "-- C. las imagenes, donde importa"

# C1: la marca de la imagen tiene que estar ENTRE los dos parrafos, no al final.
T_DOCX="$(_campo "$J_DOCX" texto)"
if printf '%s' "$T_DOCX" | grep -A 2 "ANTES DEL GRAFICO" | grep -q "IMAGEN 1"; then
  _ok "C1 la imagen queda EN SU LUGAR (entre los parrafos, no en una lista al final)"
else
  _mal "C1 imagen en su lugar" "$(printf '%s' "$T_DOCX" | head -3 | tr '\n' ' ')"
fi

# C2: el archivo existe de verdad.
IMG="$(_campo "$J_DOCX" imagenes | head -1)"
IMG_MSYS="$(cygpath -u "$IMG" 2>/dev/null || printf '%s' "$IMG")"
[ -n "$IMG" ] && [ -f "$IMG_MSYS" ] \
  && _ok "C2 la imagen se guardo de verdad ($(wc -c < "$IMG_MSYS" | tr -d ' ') bytes)" \
  || _mal "C2 imagen guardada" "ruta='$IMG'"

# C3: LA TRAMPA. Python en Windows devuelve "C:/Users/...\img-1.png" con separadores mezclados, y
# quien tiene que abrir esa ruta despues es BASH, para pasarsela a ask-nvidia.sh -I.
case "$IMG" in
  *"\\"*) _mal "C3 ruta usable desde bash" "trae backslashes: '$IMG'" ;;
  *)      _ok  "C3 la ruta sale con barras uniformes (bash puede abrirla)" ;;
esac

# C4: las imagenes chiquitas se descartan. Describir una imagen cuesta una llamada al modelo
# multimodal, y gastarla en una vineta de 200 bytes es tirarla.
grep -q "MIN_BYTES = " "$EXTRACT" \
  && _ok "C4 hay un umbral que descarta vinetas y logos diminutos" \
  || _mal "C4 umbral de tamaño" "describiria cada separador como si fuera un grafico"

# C5: tope de imagenes por documento. Sin tope, un PDF de 80 paginas dispara 80 llamadas.
grep -q -- "--max-img" "$AGENTE" \
  && _ok "C5 el agente pide un tope de imagenes por documento" \
  || _mal "C5 tope de imagenes" "un PDF largo dispararia una llamada por imagen"

echo "-- D. cableado en el agente"

grep -q '_ES_DOC=1' "$AGENTE" \
  && _ok "D1 'read' reconoce docx/pptx/xlsx/pdf en vez de rechazarlos por binarios" \
  || _mal "D1 read reconoce documentos" "seguiria rechazandolos"

# D2: si no se pudo describir una imagen, la marca NO se borra. Borrarla haria creer que el
# documento no tenia nada ahi, que es peor que decir "hay algo y no lo pude ver".
grep -q "no se pudo describir" "$AGENTE" \
  && _ok "D2 si una imagen no se puede describir, igual avisa que existe" \
  || _mal "D2 imagen no descrita" "la marca desapareceria y el documento pareceria no tenerla"

# D3: cygpath en los dos sentidos (ERR-006: python en esta maquina no abre rutas /c/...).
grep -q '_win_path "\$ABS"' "$AGENTE" && grep -q 'cygpath -u "\$_IMG"' "$AGENTE" \
  && _ok "D3 convierte las rutas en los dos sentidos (ERR-006)" \
  || _mal "D3 conversion de rutas" "python no podria abrir el documento, o bash la imagen"

# --- D4. Detectar que el pedido ESPERA un documento (adherencia B2, 2026-08-04) ---------------
# El mecanismo de B2 andaba; lo que fallaba era la adherencia: el modelo investigaba, generaba una
# imagen, resumia, y cerraba el turno sin haber llamado nunca a 'gen doc'. Las guardas viejas eran
# correctivas -- evitaban que MINTIERA sobre el documento, pero el usuario igual se quedaba sin archivo.
# Ahora, si el pedido es un documento y a la iteracion 3 todavia no hay ninguno, nv-agent.sh le
# recuerda la sintaxis exacta antes de que cierre.
#
# Lo que se prueba aca es la deteccion, que es la parte que puede fallar en silencio: si diera
# falsos positivos, el recordatorio ensuciaria turnos que no piden ningun documento.
echo "-- D4. reconocer un pedido de documento"
source "$TD_ROOT/engine/nv-lib.sh" 2>/dev/null
if type -t nv_pide_documento >/dev/null 2>&1; then
  TD_D4=0
  # Piden generar un documento.
  for f in "hacme un documento word con una foto de un puente" \
           "armame un informe en pdf de las ventas" \
           "generá una presentación sobre el proyecto" \
           "preparame una planilla con los gastos" \
           "pasalo a pdf"; do
    nv_pide_documento "$f" || { _mal "D4 no reconocio un pedido de documento" "$f"; TD_D4=1; }
  done
  # Hablan de documentos pero NO piden generar ninguno. Este es el lado que importa: un falso
  # positivo le mete una nota al pedo a cada turno que apenas menciona un pdf.
  for f in "leeme este pdf y decime que dice" \
           "que dice el informe que te pase?" \
           "hacme un resumen de la reunion" \
           "abri el documento y contame"; do
    nv_pide_documento "$f" && { _mal "D4 falso positivo" "$f"; TD_D4=1; }
  done
  [ "$TD_D4" = "0" ] && _ok "D4 distingue 'hacme un informe' de 'leeme este pdf' (9 frases)"
else
  _mal "D4 nv_pide_documento no existe" "la deteccion volvio a quedar inline y no se puede probar"
fi

grep -q 'nv_pide_documento "\$TASK"' "$AGENTE" \
  && _ok "D4 nv-agent.sh usa la deteccion sobre la tarea" \
  || _mal "D4 nv-agent.sh no consulta nv_pide_documento" "el recordatorio nunca se dispara"

if [ "$TD_VIVO" = "1" ]; then
  echo "-- E. un modelo real mirando la imagen"
  DESC="$(timeout 300 bash "$TD_ROOT/engine/ask-nvidia.sh" -r -I "$IMG_MSYS" multimodal \
          "Describi en español que muestra esta imagen. Se concreto." 2>/dev/null)"
  if printf '%s' "$DESC" | grep -qiE "barra|grafic|ventas"; then
    _ok "E1 el rol multimodal describe el grafico ($(printf '%s' "$DESC" | head -c 50)...)"
  else
    _mal "E1 descripcion real" "$(printf '%s' "$DESC" | head -c 90)"
  fi
else
  echo "-- E. (descripcion real salteada; corre con -v)"
fi

echo
echo "== $TD_OK OK, $TD_MAL MAL =="
[ "$TD_MAL" -eq 0 ]
