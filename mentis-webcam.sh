#!/usr/bin/env bash
# mentis-webcam.sh — los ojos de Mentis: saca UNA foto con la webcam y la deja en un archivo.
#
# Uso:
#   mentis-webcam.sh -o <salida.jpg>          # una foto
#   mentis-webcam.sh --listar                 # qué cámaras ve el sistema
#
# CÓMO SE TRATA LA CÁMARA ACÁ (esto no es un detalle técnico, es la regla):
#   - Se prende, saca una foto y se apaga. No queda un proceso mirando: cada foto es una
#     invocación que termina. La luz de la webcam se enciende durante la captura, que es la
#     única señal honesta de que la cámara está trabajando -- y por eso no se busca esquivarla.
#   - No graba video ni guarda nada por su cuenta: la imagen va al archivo que le pidan y nada más.
#   - El conector 'local:webcam' tiene que estar activado en la app. Apagado, esto no corre.
#
# Por qué ffmpeg y no una librería: ya está instalado y en uso para analizar video, no agrega
# ninguna dependencia nueva, y hace exactamente esto en una línea.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_OUT=""
MW_CAM="${MENTIS_WEBCAM_DISPOSITIVO:-}"
MW_LISTAR=0

while [ $# -gt 0 ]; do
  case "$1" in
    -o) MW_OUT="${2:-}"; shift 2 ;;
    --dispositivo) MW_CAM="${2:-}"; shift 2 ;;
    --listar) MW_LISTAR=1; shift ;;
    *) echo "ERROR: opcion invalida '$1'" >&2; exit 2 ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: no está ffmpeg (hace falta para usar la cámara)" >&2; exit 1; }

# Las cámaras que ve dshow, con el nombre EXACTO que hay que pasarle a ffmpeg.
_camaras() {
  ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 \
    | grep -oE '"[^"]+" \(video\)' | sed 's/ (video)//; s/"//g'
}

if [ "$MW_LISTAR" = "1" ]; then
  CAMS="$(_camaras)"
  if [ -z "$CAMS" ]; then echo "(el sistema no reporta ninguna cámara)"; exit 1; fi
  printf '%s\n' "$CAMS"
  exit 0
fi

[ -n "$MW_OUT" ] || { echo "ERROR: falta -o <salida.jpg>" >&2; exit 2; }

if [ -z "$MW_CAM" ]; then
  MW_CAM="$(_camaras | head -1)"
  [ -n "$MW_CAM" ] || { echo "ERROR: no encontré ninguna cámara conectada" >&2; exit 1; }
fi

mkdir -p "$(dirname "$MW_OUT")" 2>/dev/null || true
rm -f "$MW_OUT"

# -frames:v 6 y nos quedamos con el último: las webcams entregan los primeros cuadros oscuros o
# desenfocados mientras ajustan exposición y foco. Pedir UN solo frame da, casi siempre, una foto
# negra -- y una foto negra que "salió bien" es peor que un error, porque después alguien le pide
# al modelo que la describa y el modelo inventa.
FF_ERR="$(mktemp)"
if ! ffmpeg -hide_banner -loglevel error -f dshow -i video="$MW_CAM" \
     -frames:v 6 -update 1 -q:v 3 -y "$MW_OUT" 2>"$FF_ERR"; then
  echo "ERROR: no pude usar la cámara '$MW_CAM': $(head -c 300 "$FF_ERR")" >&2
  rm -f "$FF_ERR"; exit 1
fi
rm -f "$FF_ERR"

[ -s "$MW_OUT" ] || { echo "ERROR: la cámara no devolvió ninguna imagen" >&2; exit 1; }

# Que el archivo exista y pese no alcanza: una webcam tapada o sin luz devuelve un JPEG
# perfectamente válido y completamente negro. Se mide el brillo y se avisa -- no se falla, porque
# a lo mejor es de noche a propósito, pero que quede dicho antes de que un modelo lo interprete.
BRILLO="$(MW_IMG="$(cygpath -w "$MW_OUT" 2>/dev/null || echo "$MW_OUT")" python3 -c '
import os, struct, sys
try:
    from PIL import Image, ImageStat
    im = Image.open(os.environ["MW_IMG"]).convert("L")
    print(int(ImageStat.Stat(im).mean[0]))
except ImportError:
    print(-1)   # sin Pillow no se puede medir; no es un error
except Exception:
    print(-2)
' 2>/dev/null || echo -1)"
if [ "$BRILLO" -ge 0 ] 2>/dev/null && [ "$BRILLO" -lt 12 ] 2>/dev/null; then
  echo "AVISO: la foto salió casi negra (brillo $BRILLO/255). ¿La cámara está tapada o el cuarto a oscuras?" >&2
fi

printf '%s\n' "$MW_OUT"
