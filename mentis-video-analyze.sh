#!/usr/bin/env bash
# mentis-video-analyze.sh <video> <dir_de_salida_para_frames> -- extrae 5 frames representativos
# (cada 20% de la duracion) con ffmpeg y transcribe el audio con Whisper (mentis-transcribe.sh).
# Imprime:
#   FRAMES:
#   <ruta_frame_1>
#...
#   TRANSCRIPT:
#   <texto o "(sin audio o sin voz reconocible)">
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IN="${1:-}"; OUTDIR="${2:-}"
if [ -z "$IN" ] || [ ! -f "$IN" ] || [ -z "$OUTDIR" ]; then
  echo "ERROR: uso: mentis-video-analyze.sh <video> <dir_salida>" >&2
  exit 1
fi
mkdir -p "$OUTDIR"

DUR="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$IN" 2>/dev/null)"
DUR="${DUR%.*}"
[ -z "$DUR" ] || [ "$DUR" -le 0 ] 2>/dev/null && DUR=10

echo "FRAMES:"
for pct in 10 30 50 70 90; do
  ts=$((DUR * pct / 100))
  fout="$OUTDIR/frame-${pct}.jpg"
  if ffmpeg -y -ss "$ts" -i "$IN" -frames:v 1 -q:v 3 "$fout" >/dev/null 2>&1 && [ -s "$fout" ]; then
    echo "$fout"
  fi
done

AWAV="$OUTDIR/audio-track.wav"
TRANSCRIPT="(sin audio o sin voz reconocible)"
if ffmpeg -y -i "$IN" -vn -ac 1 -ar 16000 "$AWAV" >/dev/null 2>&1 && [ -s "$AWAV" ]; then
  TR="$(bash "$HERE/mentis-transcribe.sh" "$AWAV" 2>/dev/null)"
  [ -n "${TR// }" ] && TRANSCRIPT="$TR"
  rm -f "$AWAV"
fi
echo "TRANSCRIPT:"
echo "$TRANSCRIPT"
