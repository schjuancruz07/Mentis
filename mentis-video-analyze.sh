#!/usr/bin/env bash
# mentis-video-analyze.sh <video> <dir_salida> [-n max_frames] -- analiza un video COMO SECUENCIA.
#
# QUE CAMBIO Y POR QUE (2026-08-22, idea 3 del plan del usuario).
#   La version anterior sacaba 5 fotogramas fijos, uno cada 20% de la duracion, y transcribia el
#   audio entero en un bloque. Con eso no se puede describir lo que PASA en un video: cinco fotos
#   sueltas no cuentan una historia, y lo que ocurre entre foto y foto simplemente no existe.
#   Medido: en un video de 20 s donde algo aparece entre el segundo 15 y el 16, los cinco
#   fotogramas (2, 6, 10, 14, 18 s) se lo pierden entero.
#
#   Ahora se sacan los fotogramas DONDE LA IMAGEN CAMBIA (deteccion de escena de ffmpeg), cada uno
#   con su marca de tiempo, y el audio se transcribe POR TRAMOS alineados con esas marcas. La
#   salida es una linea de tiempo, no una bolsa de imagenes.
#
#   Si el video no tiene cambios de escena -- una charla frente a la camara, una pantalla quieta --
#   la deteccion no encuentra nada y se cae a un muestreo regular, pero mas denso y CON las marcas
#   de tiempo. Nunca se devuelve menos que antes.
#
# SALIDA (formato estable, lo lee el rol multimodal):
#   DURACION: <segundos>
#   FRAMES:
#   <segundo>|<ruta>
#...
#   TRANSCRIPT:
#   [mm:ss-mm:ss] texto del tramo
#...
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IN="${1:-}"; OUTDIR="${2:-}"
shift 2 2>/dev/null || true
MAX_FRAMES=12
while [ $# -gt 0 ]; do
  case "$1" in
    -n) MAX_FRAMES="${2:-12}"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$IN" ] || [ ! -f "$IN" ] || [ -z "$OUTDIR" ]; then
  echo "ERROR: uso: mentis-video-analyze.sh <video> <dir_salida> [-n max_frames]" >&2
  exit 1
fi
mkdir -p "$OUTDIR"
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: falta ffmpeg" >&2; exit 1; }

DUR="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$IN" 2>/dev/null)"
DUR="${DUR%.*}"
case "$DUR" in ''|*[!0-9]*) DUR=10 ;; esac
[ "$DUR" -le 0 ] && DUR=10
echo "DURACION: $DUR"

# --- 1. donde CAMBIA la imagen: se detecta primero, se extrae despues ---------------------------
# DOS PASADAS Y NO UNA, por una razon de entorno (2026-08-22, ERR-218). La version de una pasada
# usaba `metadata=print:file=<ruta>` para que ffmpeg escribiera las marcas de tiempo. Ese ffmpeg es
# un binario NATIVO de Windows: no entiende una ruta de MSYS como /tmp/loquesea, el filtro no
# arranca, y cuando un filtro no arranca se cae la cadena ENTERA -- o sea que no salia ni un solo
# fotograma de escena. Y no se notaba: el script seguia adelante con el muestreo regular y devolvia
# algo razonable. Un fallo silencioso que deja el sistema andando a la mitad de su capacidad.
#
# Asi que la deteccion no escribe archivos: corre contra la salida nula y las marcas se leen de lo
# que ffmpeg imprime. Los fotogramas se sacan despues, de a uno, con el mismo extractor preciso que
# usa el muestreo regular. Mas lento, pero no depende de como ffmpeg interprete una ruta.
TIEMPOS=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  TIEMPOS+=("$t")
done < <(ffmpeg -i "$IN" -vf "select='gt(scene,0.25)',metadata=print" -f null - 2>&1          | grep -oE 'pts_time:[0-9.]+' | cut -d: -f2 | head -40)

# --- SACAR UN FOTOGRAMA EN UN SEGUNDO EXACTO ---------------------------------------------------
# EL BUG QUE ESTO ARREGLA (2026-08-22, ERR-217): la version anterior hacia `ffmpeg -ss T -i video`.
# Con -ss ANTES de -i, ffmpeg salta al fotograma clave anterior, que puede estar varios segundos
# atras -- asi que los "5 fotogramas cada 20%" NUNCA estuvieron en esos tiempos. Medido con un
# video de 20 s que se pone rojo entre el 15 y el 16: pedir el segundo 15 devolvia el fotograma
# azul del segundo 10. El analisis describia un video que no era el que le dieron, y no habia
# forma de notarlo mirando la salida.
# Con -ss DESPUES de -i el corte es exacto. Para que siga siendo rapido en videos largos se
# combinan los dos: salto grosero hasta 3 segundos antes, y de ahi preciso.
# El tiempo puede venir con decimales: un cambio de escena no ocurre en un segundo redondo, y
# redondearlo a entero devuelve el ultimo cuadro de la escena VIEJA justo cuando lo que se quiere
# es el primero de la nueva.
_frame_en() {
  local seg="$1" dest="$2" pre fino
  pre="$(awk -v s="$seg" 'BEGIN { v = s - 3; if (v < 0) v = 0; printf "%.2f", v }')"
  fino="$(awk -v s="$seg" 'BEGIN { v = (s > 3) ? 3 : s; printf "%.2f", v }')"
  ffmpeg -y -ss "$pre" -i "$IN" -ss "$fino" -frames:v 1 -q:v 3 "$dest" >/dev/null 2>&1
  [ -s "$dest" ]
}

# --- LAS DOS FUENTES SE SUMAN, NO SE ELIGEN ----------------------------------------------------
# La primera version usaba deteccion de escena O muestreo regular segun cuantas escenas hubiera.
# Con el video de prueba salieron 2 escenas -- justo las dos que importaban -- y como el umbral
# pedia 3, las tiro y se quedo con el muestreo. Elegir una fuente descarta informacion que ya se
# habia calculado. Ahora se juntan las dos, se ordenan por tiempo y se sacan las repetidas.
LISTA="$OUTDIR/_lista.txt"
: > "$LISTA"
i=0
for t in "${TIEMPOS[@]:-}"; do
  [ -n "$t" ] || continue
  # Medio segundo DESPUES del cambio, no justo encima. En el borde exacto el fotograma que sale
  # todavia puede ser el de la escena vieja -- pasa con el video de prueba, donde pedir el segundo
  # 15 clavado devuelve el ultimo cuadro azul en vez del primero rojo.
  seg="$(printf '%s' "$t" | awk '{printf "%.2f", $1 + 0.4}')"
  fout="$OUTDIR/escena-$(printf '%03d' "$i").jpg"
  if _frame_en "$seg" "$fout"; then
    printf '%s	%s	%s	%s
' "$(awk -v v="$seg" 'BEGIN{printf "%d", v}')" "escena" "$seg" "$fout" >> "$LISTA"
  fi
  i=$((i + 1))
done
# Muestreo regular de refuerzo: cubre lo que no cambia de escena pero igual hay que mirar.
N=6
for k in $(seq 1 "$N"); do
  ts=$(( DUR * (2 * k - 1) / (2 * N) ))
  fout="$OUTDIR/reg-$(printf '%03d' "$k").jpg"
  _frame_en "$ts" "$fout" && printf '%s	%s	%s	%s
' "$ts" "regular" "$ts" "$fout" >> "$LISTA"
done

echo "FRAMES:"
# Orden por tiempo; si dos caen en el mismo segundo gana el de escena (viene antes en el orden
# alfabetico de la segunda columna: 'escena' < 'regular').
ULTIMO=-99
CUENTA=0
while IFS=$'	' read -r entero tipo seg ruta; do
  [ -n "$ruta" ] || continue
  [ "$CUENTA" -ge "$MAX_FRAMES" ] && break
  # Dos fotogramas del mismo segundo no aportan nada y gastan una llamada al modelo de vision.
  # Cuando compiten, gana el de escena: 'escena' ordena antes que 'regular' y el de escena es el
  # que fue elegido PORQUE ahi cambia algo.
  [ "$entero" = "$ULTIMO" ] && continue
  echo "$entero|$ruta"
  ULTIMO="$entero"
  CUENTA=$((CUENTA + 1))
done < <(sort -n -k1,1 -k2,2 "$LISTA")
rm -f "$LISTA"

# --- 2. el audio, por tramos y con marcas de tiempo --------------------------------------------
# Antes era un bloque de texto sin ubicacion: servia para saber DE QUE se habla, no CUANDO. Al
# partirlo, cada cosa dicha queda al lado del fotograma que le corresponde.
AWAV="$OUTDIR/_audio.wav"
echo "TRANSCRIPT:"
if ffmpeg -y -i "$IN" -vn -ac 1 -ar 16000 "$AWAV" >/dev/null 2>&1 && [ -s "$AWAV" ]; then
  TRAMO=30
  # Tope de 8 tramos: cada uno es una llamada al reconocedor de voz, y un video largo se comeria
  # el rato entero. Con videos de mas de 4 minutos los tramos se agrandan en vez de multiplicarse.
  NTRAMOS=$(( (DUR + TRAMO - 1) / TRAMO ))
  [ "$NTRAMOS" -lt 1 ] && NTRAMOS=1
  if [ "$NTRAMOS" -gt 8 ]; then
    NTRAMOS=8
    TRAMO=$(( (DUR + 7) / 8 ))
  fi
  HUBO=0
  for k in $(seq 0 $((NTRAMOS - 1))); do
    ini=$((k * TRAMO))
    [ "$ini" -ge "$DUR" ] && break
    fin=$((ini + TRAMO)); [ "$fin" -gt "$DUR" ] && fin="$DUR"
    parte="$OUTDIR/_tramo-$k.wav"
    ffmpeg -y -ss "$ini" -t "$TRAMO" -i "$AWAV" -ac 1 -ar 16000 "$parte" >/dev/null 2>&1 || continue
    [ -s "$parte" ] || continue
    txt="$(bash "$HERE/mentis-transcribe.sh" "$parte" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    rm -f "$parte"
    if [ -n "${txt// }" ]; then
      printf '[%02d:%02d-%02d:%02d] %s\n' $((ini/60)) $((ini%60)) $((fin/60)) $((fin%60)) "$txt"
      HUBO=1
    fi
  done
  rm -f "$AWAV"
  [ "$HUBO" = "0" ] && echo "(sin audio o sin voz reconocible)"
else
  echo "(sin audio o sin voz reconocible)"
fi
rm -f "$OUTDIR"/_*.txt 2>/dev/null
