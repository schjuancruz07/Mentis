#!/usr/bin/env bash
# test-ilustrar.sh -- imagenes dentro de los documentos que Mentis genera (B2, 2026-08-03).
#
# QUE SE CONSTRUYO: dos sintaxis nuevas en el markdown liviano de docgen.py:
#   !img <que buscar>                  -> baja una foto libre de Wikimedia Commons y la inserta
#   !imgfile <ruta>|<epigrafe>         -> inserta una imagen que ya esta en el disco
#
# TRES COSAS QUE SE APRENDIERON PROBANDO, Y QUE ESTE TEST FIJA:
#   1. Una foto que PIL abre sin chistar puede hacer estallar a python-docx con
#      UnrecognizedImageError Y MENSAJE VACIO. python-docx trae su propio lector de encabezados,
#      mas estricto. Por eso toda imagen bajada se re-escribe con PIL antes de usarse.
#   2. Faltaba '!imgfile'. Mentis generaba una imagen y escribia en el documento un renglon
#      '[IMAGEN: archivo.jpg]' -- que no inserta nada. No era terquedad: no habia ninguna forma
#      de insertar un archivo local, asi que el cartel era su unica opcion.
#   3. Un turno puede afirmar "te hice el informe" habiendo generado solo la imagen. La guarda
#      HAD_REAL_ACTION no lo agarra porque SI hubo una accion real -- otra.
set -uo pipefail
TI_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TI_ROOT="$(cd "$TI_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TI_VIVO=0; [ "${1:-}" = "-v" ] && TI_VIVO=1
TI_OK=0; TI_MAL=0
_ok()  { TI_OK=$((TI_OK+1));  echo "  OK   $1"; }
_mal() { TI_MAL=$((TI_MAL+1)); echo "  MAL  $1  ($2)"; }

DOCGEN="$TI_ROOT/docgen.py"
BUSCADOR="$TI_ROOT/engine/img_buscar.py"
AGENTE="$TI_ROOT/engine/nv-agent.sh"
EXTRACT="$TI_ROOT/engine/doc_extract.py"
for f in "$DOCGEN" "$BUSCADOR" "$AGENTE" "$EXTRACT"; do
  [ -f "$f" ] || { echo "ABORTA: falta $f" >&2; exit 1; }
done

TI_TMP="$(mktemp -d)"
case "$TI_TMP" in "$TI_ROOT"|"$TI_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TI_TMP"' EXIT
_win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

echo "== ilustrar documentos =="
echo "-- A. lo deterministico (no toca la red)"

python3 -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read())" "$(_win "$DOCGEN")" \
  && _ok "A1 docgen.py compila" || _mal "A1 docgen.py compila" "error de sintaxis"

# A2: !imgfile con una imagen local. Es el caso que faltaba y que obligaba al modelo a escribir
# un cartel de texto.
python3 - "$(_win "$TI_TMP")" <<'PY'
import os, random, sys
from PIL import Image, ImageDraw
D = sys.argv[1]
img = Image.new("RGB", (500, 320), "white")
d = ImageDraw.Draw(img)
random.seed(3)
for i in range(5):
    d.rectangle([40+i*90, 300-(i+1)*45, 100+i*90, 300], fill="#2980b9", outline="black")
d.text((150, 10), "IMAGEN LOCAL DE PRUEBA", fill="black")
px = img.load()
for _ in range(6000):
    x = random.randrange(500); y = random.randrange(320)
    r, g, b = px[x, y]; px[x, y] = (max(0,r-5), max(0,g-5), max(0,b-5))
img.save(os.path.join(D, "local.png"))
print("ok")
PY

printf '# Titulo\n\nTexto antes.\n\n!imgfile %s|Epigrafe de prueba\n\nTexto despues.\n' "$(_win "$TI_TMP/local.png")" \
  | python3 "$DOCGEN" docx "$(_win "$TI_TMP/con-local.docx")" >/dev/null 2>&1
if [ -s "$TI_TMP/con-local.docx" ]; then
  SAL="$(python3 "$EXTRACT" "$(_win "$TI_TMP/con-local.docx")" --imgdir "$(_win "$TI_TMP/v1")" 2>/dev/null)"
  printf '%s' "$SAL" | grep -q "\[\[IMAGEN 1:" \
    && _ok "A2 !imgfile inserta la imagen DE VERDAD (se lee de vuelta del docx)" \
    || _mal "A2 !imgfile inserta" "no hay imagen embebida"
  printf '%s' "$SAL" | grep -q "Epigrafe de prueba" \
    && _ok "A3 el epigrafe queda escrito debajo" \
    || _mal "A3 epigrafe" "no aparece"
  # Y en el orden correcto: la imagen entre los dos parrafos, no al final.
  printf '%s' "$SAL" | grep -A 2 "Texto antes" | grep -q "IMAGEN 1" \
    && _ok "A4 la imagen queda en su lugar dentro del texto" \
    || _mal "A4 orden" "la imagen no quedo entre los parrafos"
else
  _mal "A2 !imgfile inserta" "no se genero el docx"; _mal "A3 epigrafe" "idem"; _mal "A4 orden" "idem"
fi

# A5: un '!img' sin resolver NO puede desaparecer en silencio. Un hueco silencioso es peor que
# uno señalado: nadie revisa lo que no sabe que falta.
printf '# T\n\n!img algo\n' | python3 - <<'PY' > "$TI_TMP/sinresolver.txt" 2>/dev/null
import io, sys, os
sys.path.insert(0, os.environ.get("TI_ROOT", "."))
PY
printf '# T\n\nX\n' > /dev/null   # (el chequeo real es sobre parse_blocks, abajo)
python3 - "$(_win "$DOCGEN")" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dg", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bloques = m.parse_blocks("!img una cosa")
txt = str(bloques)
sys.exit(0 if "falta la imagen" in txt else 1)
PY
[ $? = 0 ] && _ok "A5 un '!img' sin resolver deja constancia, no desaparece" \
           || _mal "A5 hueco señalado" "la linea se borraria en silencio"

echo "-- B. la normalizacion de imagenes (la trampa de python-docx)"

grep -q "UnrecognizedImageError" "$BUSCADOR" \
  && _ok "B1 el buscador documenta por que normaliza (python-docx rechaza JPEGs validos)" \
  || _mal "B1 documenta la normalizacion" "sin el porque, alguien la va a sacar por 'innecesaria'"

grep -q 'im.convert("RGB")' "$BUSCADOR" && grep -q "thumbnail" "$BUSCADOR" \
  && _ok "B2 re-escribe en RGB y acota el tamaño antes de usar la imagen" \
  || _mal "B2 normaliza" "un JPEG progresivo o CMYK haria fallar la insercion"

echo "-- C. licencias y atribucion"

grep -q "commons.wikimedia.org" "$BUSCADOR" \
  && _ok "C1 busca en Wikimedia Commons (todo de licencia libre, con autor conocido)" \
  || _mal "C1 fuente libre" "otra fuente no garantiza que se pueda usar"

grep -q '"atribucion"' "$BUSCADOR" \
  && _ok "C2 devuelve la atribucion (titulo, autor y licencia)" \
  || _mal "C2 atribucion" "libre no es lo mismo que sin autor"

grep -qi "User-Agent" "$BUSCADOR" \
  && _ok "C3 manda User-Agent propio (Wikimedia contesta 403 sin el)" \
  || _mal "C3 User-Agent" "la API va a rechazar las consultas"

echo "-- D. las guardas del agente"

grep -q "cartel de imagen en vez de" "$AGENTE" \
  && _ok "D1 rechaza un content con '[IMAGEN:...]' y explica como hacerlo bien" \
  || _mal "D1 guarda del cartel" "el documento saldria sin la foto y nadie avisaria"

grep -q "HAD_DOC=1" "$AGENTE" \
  && _ok "D2 marca cuando se genero un documento DE VERDAD" \
  || _mal "D2 HAD_DOC" "no se puede distinguir 'hizo algo' de 'hizo lo que dice'"

grep -q "habla de un documento y no se genero ninguno" "$AGENTE" \
  && _ok "D3 rechaza afirmar un documento que no existe" \
  || _mal "D3 guarda por tipo de artefacto" "podria prometer un archivo inexistente"

# D4: y esa guarda NO puede rechazar en bucle. Medido: un turno se comio 10 minutos asi.
grep -q "DOC_RECHAZOS" "$AGENTE" \
  && _ok "D4 la guarda se corta al primer rechazo (no quema el turno en bucle)" \
  || _mal "D4 tope de rechazos" "un bucle de rechazos deja al usuario sin nada"

grep -q "imgfile" "$AGENTE" \
  && _ok "D5 la ficha de gen le enseña '!imgfile' (el caso que faltaba)" \
  || _mal "D5 ficha con imgfile" "el modelo no tiene forma de insertar lo que genero"

if [ "$TI_VIVO" = "1" ]; then
  echo "-- E. bajando una imagen de verdad"
  J="$(timeout 200 python3 "$BUSCADOR" "solar panel" --dest "$(_win "$TI_TMP/web")" --json 2>/dev/null)"
  if printf '%s' "$J" | grep -q '"ruta"'; then
    R="$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ruta"])')"
    RM="$(cygpath -u "$R" 2>/dev/null || printf '%s' "$R")"
    [ -f "$RM" ] && _ok "E1 baja una imagen real ($(wc -c < "$RM" | tr -d ' ') bytes)" \
                 || _mal "E1 baja imagen" "la ruta no existe: $R"
    printf '%s' "$J" | grep -qE '"licencia": "(CC|Public|GFDL)' \
      && _ok "E2 viene con licencia identificada" \
      || _mal "E2 licencia" "$(printf '%s' "$J" | head -c 80)"
    # E3: y esa imagen entra en un docx sin explotar (la normalizacion sirve de verdad).
    printf '# T\n\n!imgfile %s|prueba\n' "$R" | python3 "$DOCGEN" docx "$(_win "$TI_TMP/web.docx")" >/dev/null 2>&1
    python3 "$EXTRACT" "$(_win "$TI_TMP/web.docx")" --imgdir "$(_win "$TI_TMP/v2")" 2>/dev/null | grep -q "\[\[IMAGEN" \
      && _ok "E3 la imagen bajada de la web entra en el docx sin fallar" \
      || _mal "E3 imagen de la web en docx" "fallo la insercion pese a la normalizacion"
  else
    _mal "E1 baja imagen" "sin resultado: $(printf '%s' "$J" | head -c 80)"
  fi
else
  echo "-- E. (descarga real salteada; corre con -v)"
fi

echo
echo "== $TI_OK OK, $TI_MAL MAL =="
[ "$TI_MAL" -eq 0 ]
