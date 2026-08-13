# CAPABILITY: /material | convierte TU material de estudio en otro formato: "/material audio fotosintesis", "/material tarjetas", "/material cuestionario", "/material mapa", "/material presentacion", "/material informe", "/material infografia", "/material tabla", "/material video". Sale del corpus de Mentis Study, nunca de conocimiento suelto.
#
# POR QUE EXISTE (2026-08-12): el usuario pidio los nueve formatos de NotebookLM. Los nueve se arman con
# piezas que Mentis YA tenia -- docgen.py (docx/pdf/pptx/xlsx), mentis-tts.sh (voz) y ffmpeg -- y
# lo unico que faltaba era el pegamento: sacar el contenido del corpus y llevarlo a cada formato.
#
# POR QUE ES UNA CAPACIDAD Y NO LA HERRAMIENTA 'gen': la regla de anillos dice que generar
# imagenes/3D/documentos es de Mentis Designe y de nadie mas (bandera -g). Darle -g a Study para
# esto hubiera roto esa regla y le hubiera dado, de paso, permiso para generar cualquier cosa.
# Aca en cambio Study no gana "generar lo que quiera": gana "convertir SU corpus a nueve formatos",
# que es otra cosa y no toca el reparto.
#
# DE DONDE SALE EL CONTENIDO, QUE ES LO QUE HACE UTIL AL MODO: de los fragmentos del corpus, via
# el mismo buscador semantico de Kai Vault. Si el corpus no tiene nada del tema, esto NO inventa
# una clase: avisa y corta. Un resumen lindo de algo que el usuario no cargo es exactamente lo que el
# modo Study promete no hacer.
set -uo pipefail
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLSDIR="$HERE/engine"
SALIDA_DIR="${MENTIS_CREATIONS_DIR:-$HOME/Documents/Mentis}"
# shellcheck source=/dev/null
source "$TOOLSDIR/nv-modos-lib.sh"
CORPUS="$(nv_modo_corpus study 2>/dev/null)"

TIPO="${1:-}"
shift 2>/dev/null || true
TEMA="${*:-}"

_ayuda() {
  cat <<'AYUDA'
/material -- tu material de estudio, en otro formato.

  /material audio <tema>          un resumen hablado (.mp3) con la voz de Mentis
  /material video <tema>          diapositivas + esa misma voz (.mp4)
  /material presentacion <tema>.pptx
  /material informe <tema>.docx
  /material tabla <tema>.xlsx con los datos que haya
  /material mapa <tema>           mapa mental (se abre en el visor)
  /material tarjetas <tema>       tarjetas didácticas para repasar
  /material cuestionario <tema>   preguntas con sus respuestas
  /material infografia <tema>     una lámina visual

Todo sale de lo que cargaste con /estudiar. Si del tema no hay nada, te lo digo.
AYUDA
}

if [ -z "${TIPO// }" ]; then _ayuda; exit 0; fi
if [ -z "${CORPUS// }" ] || [ ! -d "$CORPUS" ]; then
  echo "Todavía no cargaste material. Empezá con: /estudiar sumar <archivo> <materia>"
  exit 1
fi
mkdir -p "$SALIDA_DIR" 2>/dev/null

# --- 1. El corpus sobre el tema -------------------------------------------------------------
CONSULTA="${TEMA:-resumen general}"
FRAGMENTOS="$(bash "$TOOLSDIR/nv-search.sh" -k 8 -d "$CORPUS" -- "$CONSULTA" 2>/dev/null)"
if [ -z "${FRAGMENTOS// }" ]; then
  echo "No encontré nada sobre '$CONSULTA' en tu material de estudio."
  echo "Mirá qué tenés cargado con: /estudiar materias"
  exit 1
fi

SLUG="$(printf '%s' "${TEMA:-material}" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
[ -z "$SLUG" ] && SLUG="material"
SELLO="$(date '+%Y%m%d-%H%M%S')"

# Le pide al modelo el contenido, SIEMPRE atado a los fragmentos. La instruccion de no inventar
# se repite aca ademas de estar en la persona del modo: este script tambien se puede invocar
# desde otro modo, y la garantia no puede depender de en cual esté el usuario.
_pedir_al_modelo() {
  local instruccion="$1" rol="${2:-reason}"
  bash "$TOOLSDIR/ask-nvidia.sh" -r "$rol" "$instruccion

REGLA QUE NO SE NEGOCIA: usá SOLO lo que está en los fragmentos de abajo. No completes con lo que
sepas por otro lado. Si los fragmentos no alcanzan para algo, omitilo en vez de rellenarlo.

FRAGMENTOS DEL MATERIAL DE USUARIO:
$(printf '%s' "$FRAGMENTOS" | head -c 12000)" 2>/dev/null
}

# Envoltorio HTML comun a mapa, tarjetas, cuestionario e infografia. Autocontenido a proposito:
# el visor lo abre en un iframe con sandbox, sin red y sin acceso a la app.
_html_pagina() {
  local titulo="$1" cuerpo="$2"
  cat <<HTML
<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>$titulo</title><style>
:root{color-scheme:dark}
body{margin:0;padding:32px;background:#0e0e10;color:#e8e6e3;
     font-family:system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.6}
h1{font-size:24px;font-weight:600;color:#d8734a;margin:0 0 24px}
h2{font-size:17px;font-weight:600;margin:28px 0 10px}
.grilla{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px}
.tarjeta{background:#191a1d;border:1px solid #2a2b2f;border-radius:10px;padding:16px}
.tarjeta b{display:block;color:#d8734a;margin-bottom:8px;font-size:15px}
.rama{border-left:2px solid #d8734a;padding-left:16px;margin:10px 0 10px 8px}
.rama h3{margin:0 0 4px;font-size:15px;color:#e8e6e3}
.rama ul{margin:4px 0}
details{background:#191a1d;border:1px solid #2a2b2f;border-radius:10px;padding:12px 16px;margin-bottom:10px}
summary{cursor:pointer;font-weight:600}
details p{margin:10px 0 0;color:#b9b6b1}
.dato{background:#191a1d;border-radius:10px;padding:18px;text-align:center}
.dato b{display:block;font-size:26px;color:#d8734a}
.dato span{font-size:13px;color:#9d9a95}
footer{margin-top:36px;padding-top:14px;border-top:1px solid #2a2b2f;color:#7c7a76;font-size:12px}
</style></head><body>
$cuerpo
<footer>Hecho por Mentis Study con tu propio material. Si algo no está acá, es que no estaba en lo que cargaste.</footer>
</body></html>
HTML
}

_guardar_html() {
  local dest="$1" titulo="$2" cuerpo="$3"
  _html_pagina "$titulo" "$cuerpo" > "$dest"
}

_listo() {
  local dest="$1" que="$2"
  local win; win="$(cygpath -w "$dest" 2>/dev/null || printf '%s' "$dest")"
  echo "Listo: $que"
  echo "Se abre en el visor de Mentis."
  echo "[nv-agent] ARTIFACT: $win" >&2
}

case "$TIPO" in
  # ---------------------------------------------------------------- documentos (docgen.py)
  informe|reporte)
    DEST="$SALIDA_DIR/informe-$SLUG-$SELLO.docx"
    _pedir_al_modelo "Escribí un informe de estudio sobre '$CONSULTA'. Usá markdown liviano: '# ' para el título, '## ' para las secciones, '- ' para las listas. Sin preámbulo." \
      | python3 "$HERE/docgen.py" docx "$DEST" >/dev/null && _listo "$DEST" "informe sobre $CONSULTA (.docx)"
    ;;
  presentacion|presentación|slides)
    DEST="$SALIDA_DIR/presentacion-$SLUG-$SELLO.pptx"
    _pedir_al_modelo "Armá una presentación sobre '$CONSULTA'. Una diapositiva por idea: '# ' para el título de cada una y '- ' para sus viñetas (máximo 5 por diapositiva). Entre 6 y 10 diapositivas. Sin preámbulo." \
      | python3 "$HERE/docgen.py" pptx "$DEST" >/dev/null && _listo "$DEST" "presentación sobre $CONSULTA (.pptx)"
    ;;
  tabla|datos)
    DEST="$SALIDA_DIR/tabla-$SLUG-$SELLO.xlsx"
    _pedir_al_modelo "Extraé los datos de '$CONSULTA' en una tabla markdown (| col | col |). Sólo los datos que estén en los fragmentos, con sus unidades. Si no hay datos numéricos, hacé una tabla de conceptos y definiciones. Sin preámbulo." \
      | python3 "$HERE/docgen.py" xlsx "$DEST" >/dev/null && _listo "$DEST" "tabla de $CONSULTA (.xlsx)"
    ;;

  # ---------------------------------------------------------------- páginas (HTML al visor)
  mapa|mental|mapa-mental)
    DEST="$SALIDA_DIR/mapa-$SLUG-$SELLO.html"
    CUERPO="$(_pedir_al_modelo "Armá un mapa mental de '$CONSULTA' en HTML. Estructura EXACTA que tenés que devolver, sin nada más: un <h1> con el tema, y por cada rama principal un bloque <div class=\"rama\"><h3>rama</h3><ul><li>sub-idea</li></ul></div>. Entre 4 y 7 ramas. Devolvé sólo ese HTML, sin explicación y sin bloque de código.")"
    _guardar_html "$DEST" "Mapa mental: $CONSULTA" "$CUERPO" && _listo "$DEST" "mapa mental de $CONSULTA"
    ;;
  tarjetas|flashcards)
    DEST="$SALIDA_DIR/tarjetas-$SLUG-$SELLO.html"
    CUERPO="$(_pedir_al_modelo "Armá tarjetas didácticas de '$CONSULTA' en HTML. Estructura EXACTA: un <h1> con el tema y después <div class=\"grilla\"> con una <div class=\"tarjeta\"><b>concepto</b>explicación breve</div> por tarjeta. Entre 8 y 14 tarjetas. Devolvé sólo ese HTML, sin explicación y sin bloque de código.")"
    _guardar_html "$DEST" "Tarjetas: $CONSULTA" "$CUERPO" && _listo "$DEST" "tarjetas de $CONSULTA"
    ;;
  cuestionario|quiz|preguntas)
    DEST="$SALIDA_DIR/cuestionario-$SLUG-$SELLO.html"
    CUERPO="$(_pedir_al_modelo "Armá un cuestionario de repaso de '$CONSULTA' en HTML. Estructura EXACTA: un <h1> con el tema y por cada pregunta <details><summary>la pregunta</summary><p>la respuesta</p></details>. Entre 8 y 12 preguntas, de dificultad creciente. Devolvé sólo ese HTML, sin explicación y sin bloque de código.")"
    _guardar_html "$DEST" "Cuestionario: $CONSULTA" "$CUERPO" && _listo "$DEST" "cuestionario de $CONSULTA"
    ;;
  infografia|infografía)
    DEST="$SALIDA_DIR/infografia-$SLUG-$SELLO.html"
    CUERPO="$(_pedir_al_modelo "Armá una infografía de '$CONSULTA' en HTML. Estructura EXACTA: un <h1>, después <div class=\"grilla\"> con <div class=\"dato\"><b>el número o dato</b><span>qué significa</span></div> para las cifras clave (sólo las que estén en los fragmentos), y después <h2>secciones</h2> con párrafos cortos. Devolvé sólo ese HTML, sin explicación y sin bloque de código.")"
    _guardar_html "$DEST" "Infografía: $CONSULTA" "$CUERPO" && _listo "$DEST" "infografía de $CONSULTA"
    ;;

  # ---------------------------------------------------------------- voz y video
  audio|podcast)
    DEST="$SALIDA_DIR/audio-$SLUG-$SELLO.mp3"
    GUION="$(_pedir_al_modelo "Escribí un resumen HABLADO de '$CONSULTA', para escuchar. Entre 200 y 350 palabras, en segunda persona, sin títulos ni viñetas ni markdown: texto corrido, como si se lo contaras a alguien. Sin preámbulo.")"
    if [ -z "${GUION// }" ]; then echo "No pude armar el guion."; exit 1; fi
    WAV="${DEST%.mp3}.wav"
    bash "$HERE/mentis-tts.sh" "$GUION" "$WAV" >/dev/null 2>&1
    if [ ! -s "$WAV" ]; then echo "No pude generar la voz (revisá /voz o la clave de TTS)."; exit 1; fi
    # A mp3 porque un wav de 5 minutos son ~50 MB y el visor lo tiene que mover por IPC.
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -y -i "$WAV" -codec:a libmp3lame -q:a 4 "$DEST" >/dev/null 2>&1 && rm -f "$WAV" || DEST="$WAV"
    else
      DEST="$WAV"
    fi
    _listo "$DEST" "resumen en audio de $CONSULTA"
    ;;
  video)
    # NO es video generativo (el usuario lo descartó el 2026-07-29 y la decisión sigue firme): son las
    # diapositivas de texto unidas al audio del TTS. Todo local, todo gratis, sin modelo de video.
    DEST="$SALIDA_DIR/video-$SLUG-$SELLO.mp4"
    command -v ffmpeg >/dev/null 2>&1 || { echo "Falta ffmpeg, que es lo que arma el video."; exit 1; }
    GUION="$(_pedir_al_modelo "Escribí un resumen hablado de '$CONSULTA' de 150 a 250 palabras, texto corrido sin markdown. Después, en una línea aparte que arranque con 'TITULOS:', poné entre 4 y 6 títulos cortos separados por ' | ' que resuman las partes del resumen, en orden. Sin preámbulo.")"
    LOCUCION="$(printf '%s' "$GUION" | grep -vi '^ *titulos:' )"
    TITULOS="$(printf '%s' "$GUION" | grep -i '^ *titulos:' | sed 's/^ *[Tt][Ii][Tt][Uu][Ll][Oo][Ss]: *//')"
    # RESPALDO: si el modelo no devolvio la linea (paso en la primera corrida real), los titulos
    # se sacan del propio guion partiendolo en oraciones. Sin esto queda UNA sola diapositiva
    # durante todo el video, que es un audio con una imagen fija -- no lo que se pidio.
    if [ -z "${TITULOS// }" ] || [ "$(printf '%s' "$TITULOS" | awk -F' \\| ' '{print NF}')" -lt 2 ]; then
      TITULOS="$(printf '%s' "$LOCUCION" | tr '.' '\n' \
        | sed 's/^ *//; s/ *$//' | awk 'length($0)>25 && length($0)<110' \
        | head -5 | cut -c1-70 | paste -sd'|' - | sed 's/|/ | /g')"
    fi
    [ -z "${TITULOS// }" ] && TITULOS="$CONSULTA"
    TMPV="$(mktemp -d)"; trap 'rm -rf "$TMPV"' EXIT
    WAV="$TMPV/voz.wav"
    bash "$HERE/mentis-tts.sh" "$LOCUCION" "$WAV" >/dev/null 2>&1
    [ -s "$WAV" ] || { echo "No pude generar la voz para el video."; exit 1; }
    DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null | cut -d. -f1)"
    [ -z "${DUR//[!0-9]/}" ] && DUR=30
    # Las diapositivas se dibujan con Python (Pillow ya está: lo usa doc_extract) y se reparten
    # el tiempo del audio en partes iguales.
    N="$(printf '%s' "$TITULOS" | awk -F' \\| ' '{print NF}')"
    [ "${N:-0}" -lt 1 ] && N=1
    POR="$(( DUR / N + 1 ))"
    TITULOS="$TITULOS" TMPV="$TMPV" python3 - <<'PY'
import os
from PIL import Image, ImageDraw, ImageFont
titulos = [t.strip() for t in os.environ['TITULOS'].split('|') if t.strip()]
tmp = os.environ['TMPV']
try:
    fuente = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 64)
except OSError:
    fuente = ImageFont.load_default()
for i, t in enumerate(titulos):
    img = Image.new("RGB", (1280, 720), (14, 14, 16))
    d = ImageDraw.Draw(img)
    # Se parte el titulo en lineas de 22 caracteres para que no se salga del cuadro.
    lineas, actual = [], ""
    for pal in t.split():
        if len(actual) + len(pal) + 1 > 22:
            lineas.append(actual); actual = pal
        else:
            actual = (actual + " " + pal).strip()
    if actual: lineas.append(actual)
    alto = len(lineas) * 78
    y = (720 - alto) // 2
    for ln in lineas:
        caja = d.textbbox((0, 0), ln, font=fuente)
        d.text(((1280 - (caja[2] - caja[0])) // 2, y), ln, font=fuente, fill=(216, 115, 74))
        y += 78
    img.save(os.path.join(tmp, f"slide-{i:03d}.png"))
print(len(titulos))
PY
    # LAS RUTAS DE LA LISTA VAN EN FORMATO WINDOWS. Trampa de MSYS ya conocida y que aca mordio
    # (2026-08-12): MSYS traduce solo las rutas que viajan en VARIABLES DE ENTORNO hacia un
    # proceso nativo, asi que Python recibio TMPV ya convertido y guardo los PNG en
    # C:\...\Temp\..., mientras bash seguia viendo /tmp/... Si la lista se arma con la ruta de
    # bash, ffmpeg (que es un binario de Windows) busca un /tmp que no existe y falla sin decir
    # por que. Se convierte cada ruta con cygpath -m (barras normales, que es lo que ffmpeg
    # prefiere adentro de un archivo de concat).
    : > "$TMPV/lista.txt"
    for f in "$TMPV"/slide-*.png; do
      fw="$(cygpath -m "$f" 2>/dev/null || printf '%s' "$f")"
      printf "file '%s'\nduration %s\n" "$fw" "$POR" >> "$TMPV/lista.txt"
    done
    # ffmpeg ignora la duracion del ultimo item de un concat: hay que repetirlo.
    ULT="$(ls "$TMPV"/slide-*.png | tail -1)"
    ULT_W="$(cygpath -m "$ULT" 2>/dev/null || printf '%s' "$ULT")"
    printf "file '%s'\n" "$ULT_W" >> "$TMPV/lista.txt"
    LISTA_W="$(cygpath -m "$TMPV/lista.txt" 2>/dev/null || printf '%s' "$TMPV/lista.txt")"
    WAV_W="$(cygpath -m "$WAV" 2>/dev/null || printf '%s' "$WAV")"
    DEST_W="$(cygpath -m "$DEST" 2>/dev/null || printf '%s' "$DEST")"
    FF_ERR="$(ffmpeg -y -f concat -safe 0 -i "$LISTA_W" -i "$WAV_W" \
      -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$DEST_W" 2>&1)"
    # El error de ffmpeg se MUESTRA. Estaba silenciado con 2>/dev/null y lo unico que quedaba era
    # "ffmpeg no pudo armar el video", que no alcanza para arreglar nada.
    [ -s "$DEST" ] || { echo "ffmpeg no pudo armar el video:"; printf '%s\n' "$FF_ERR" | tail -3; exit 1; }
    _listo "$DEST" "video de $CONSULTA (diapositivas + tu voz de Mentis)"
    ;;

  *)
    echo "No conozco el formato '$TIPO'."
    echo
    _ayuda
    exit 2
    ;;
esac
