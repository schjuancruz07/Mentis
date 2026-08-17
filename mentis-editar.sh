#!/usr/bin/env bash
# mentis-editar.sh -- el modo Editor por dentro: mira un video, lo entiende y lo edita.
#
# QUE HACE Y QUE NO. Todo lo pesado lo hace ffmpeg; lo que decide QUE hacer es el guion de edicion
# que escribe el modelo (engine/editor_guion.py lo valida y lo compila). Este archivo es el
# pegamento: consigue los datos que el guion necesita (duracion, silencios, transcripcion con
# tiempos), llama al compilador y ejecuta los comandos.
#
# POR QUE EL MODELO NO LLAMA A ffmpeg DIRECTO: un filter_complex mal armado no falla, escribe un
# archivo silenciosamente distinto del pedido. Con un guion declarativo se puede validar antes de
# tocar un cuadro y testear sin gastar un segundo de CPU.
#
# Uso:
#   mentis-editar.sh inspeccionar <video>              datos reales del archivo (ffprobe)
#   mentis-editar.sh transcribir  <video>              texto + tiempos de cada frase
#   mentis-editar.sh silencios    <video> [umbral_s]   el paso 'cortar' ya calculado
#   mentis-editar.sh render       <guion.json>         compila y ejecuta; imprime la ruta final
set -uo pipefail
ME_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME_ENGINE="$ME_HERE/engine"
ME_SALIDA="${MENTIS_CREATIONS_DIR:-$HOME/Documents/Mentis}"

_py() { python3 "$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")" "${@:2}"; }
_w()  { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
_m()  { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

_falta_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && return 1
  echo "ERROR: falta ffmpeg. Instalalo con: winget install Gyan.FFmpeg" >&2
  return 0
}

_dur() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------------------------
cmd_inspeccionar() {
  local v="${1:-}"
  [ -f "$v" ] || { echo "ERROR: no existe el archivo: $v" >&2; return 1; }
  _falta_ffmpeg && return 1
  # Una sola llamada a ffprobe y de ahi sale todo: dos llamadas para el mismo archivo es esperar
  # dos veces por lo mismo.
  local info
  info="$(ffprobe -v error -show_entries format=duration,size:stream=codec_type,width,height,r_frame_rate,codec_name \
          -of json "$v" 2>/dev/null)"
  [ -n "${info// }" ] || { echo "ERROR: ffprobe no pudo leer '$v' (¿es un video?)" >&2; return 1; }
  MEI_JSON="$info" MEI_RUTA="$v" python3 -c "
import json, os, sys
d = json.loads(os.environ['MEI_JSON'])
f = d.get('format', {})
vs = next((s for s in d.get('streams', []) if s.get('codec_type') == 'video'), {})
aud = any(s.get('codec_type') == 'audio' for s in d.get('streams', []))
fps = vs.get('r_frame_rate', '0/1')
try:
    n, den = fps.split('/'); fps = round(float(n) / float(den), 2) if float(den) else 0
except Exception:
    fps = 0
dur = float(f.get('duration') or 0)
print('archivo: %s' % os.path.basename(os.environ['MEI_RUTA']))
print('duracion_s: %.2f  (%d:%02d)' % (dur, int(dur // 60), int(dur % 60)))
print('resolucion: %sx%s' % (vs.get('width', '?'), vs.get('height', '?')))
print('fps: %s' % fps)
print('codec: %s' % vs.get('codec_name', '?'))
print('audio: %s' % ('si' if aud else 'NO -- sin pista de audio'))
print('tamano_mb: %.1f' % (float(f.get('size') or 0) / 1048576))
# El dato que decide si conviene esperar: a ~3,4x tiempo real medido en esta maquina.
print('export_estimado_s: %d  (si hay que recodificar; cortar sin filtros es casi instantaneo)' % int(dur * 3.4))
"
}

# ---------------------------------------------------------------------------------------------
cmd_transcribir() {
  local v="${1:-}"
  [ -f "$v" ] || { echo "ERROR: no existe el archivo: $v" >&2; return 1; }
  _falta_ffmpeg && return 1
  local tmp wav
  tmp="$(mktemp -d)"; wav="$tmp/audio.wav"
  # 16 kHz mono: lo que espera Whisper. Convertir una vez acá evita que lo haga el servidor.
  if ! ffmpeg -y -v error -i "$v" -vn -ac 1 -ar 16000 "$wav" 2>/dev/null || [ ! -s "$wav" ]; then
    rm -rf "$tmp"; echo "ERROR: el video no tiene audio, o ffmpeg no pudo extraerlo" >&2; return 1
  fi
  # Se pide al servidor de voz, que ya tiene el modelo cargado. El endpoint /transcribir devuelve
  # los SEGMENTOS con sus tiempos (agregado el 2026-08-16 para esto).
  local puerto
  puerto="$(grep -oE '"puerto"[: ]+[0-9]+' "$ME_HERE/stt-server-state.json" 2>/dev/null | grep -oE '[0-9]+$')"
  if [ -z "${puerto:-}" ]; then
    bash "$ME_HERE/mentis-transcribe.sh" --encender >/dev/null 2>&1
    puerto="$(grep -oE '"puerto"[: ]+[0-9]+' "$ME_HERE/stt-server-state.json" 2>/dev/null | grep -oE '[0-9]+$')"
  fi
  [ -n "${puerto:-}" ] || { rm -rf "$tmp"; echo "ERROR: no pude encender el servidor de voz" >&2; return 1; }
  local resp
  resp="$(curl -s -m 900 -X POST "http://127.0.0.1:$puerto/transcribir" \
            -H 'Content-Type: application/json' \
            -d "{\"ruta\": \"$(_m "$wav" | sed 's/\\/\\\\/g')\"}" 2>/dev/null)"
  rm -rf "$tmp"
  [ -n "${resp// }" ] || { echo "ERROR: el servidor de voz no respondio" >&2; return 1; }
  MET_RESP="$resp" python3 -c "
import json, os, sys
d = json.loads(os.environ['MET_RESP'])
if not d.get('ok'):
    sys.stderr.write('ERROR: %s\n' % d.get('error', 'la transcripcion fallo')); sys.exit(1)
segs = d.get('segmentos') or []
print('duracion_s: %s' % d.get('duracion_audio'))
print('segmentos: %d' % len(segs))
print('')
for s in segs:
    print('[%7.2f -> %7.2f] %s' % (s['desde'], s['hasta'], s['texto']))
"
}

# ---------------------------------------------------------------------------------------------
cmd_silencios() {
  local v="${1:-}" umbral="${2:-0.7}"
  [ -f "$v" ] || { echo "ERROR: no existe el archivo: $v" >&2; return 1; }
  _falta_ffmpeg && return 1
  local dur; dur="$(_dur "$v")"
  [ -n "${dur// }" ] || { echo "ERROR: no pude leer la duracion de '$v'" >&2; return 1; }
  local tmp; tmp="$(mktemp -d)"
  # silencedetect escribe por stderr, no por stdout.
  ffmpeg -v info -i "$v" -af "silencedetect=noise=-35dB:d=$umbral" -f null - 2>"$tmp/sil.txt" >/dev/null
  # Los segmentos de voz: sin ellos, un corte se come el principio de una palabra.
  local segjson="$tmp/segs.json"
  if cmd_transcribir "$v" 2>/dev/null | python3 -c "
import json, re, sys
segs = []
for l in sys.stdin.read().split('\n'):
    m = re.match(r'\s*\[\s*([\d.]+)\s*->\s*([\d.]+)\]\s*(.*)', l)
    if m:
        segs.append({'desde': float(m.group(1)), 'hasta': float(m.group(2)), 'texto': m.group(3)})
sys.stdout.write(json.dumps({'segmentos': segs}, ensure_ascii=False))
" > "$segjson" 2>/dev/null; then :; else printf '{"segmentos": []}' > "$segjson"; fi
  _py "$ME_ENGINE/editor_silencios.py" "$(_w "$tmp/sil.txt")" "$(_w "$segjson")" "$dur"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# ---------------------------------------------------------------------------------------------
cmd_render() {
  local g="${1:-}"
  [ -f "$g" ] || { echo "ERROR: no existe el guion: $g" >&2; return 1; }
  _falta_ffmpeg && return 1
  mkdir -p "$ME_SALIDA"
  # El `tr -d '\r'` no es paranoia: el compilador ya emite \n, pero esta salida se EJECUTA, y un \r
  # invisible al final de la linea se pega al nombre del archivo de salida. Cuesta nada y evita un
  # fallo que en la terminal se lee como otro error distinto (el \r sobrescribe el mensaje).
  local plan; plan="$(_py "$ME_ENGINE/editor_guion.py" compilar "$(_w "$g")" 2>&1 | tr -d '\r')"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" != "0" ]; then printf '%s\n' "$plan" >&2; return 1; fi

  local final; final="$(printf '%s\n' "$plan" | grep '^# salida final: ' | sed 's/^# salida final: //')"
  local total; total="$(printf '%s\n' "$plan" | grep -c '^# ')"
  local n=0
  # Se ejecuta paso por paso y se avisa cual va: un render de varios minutos sin una linea de
  # progreso se lee como un cuelgue.
  while IFS= read -r linea; do
    case "$linea" in
      '# salida final: '*) continue ;;
      '#'*) n=$((n+1)); echo "[editor] paso $n/$((total-1)): ${linea#\# }" >&2; continue ;;
      '') continue ;;
    esac
    # Con </dev/null: cualquier comando que lea la entrada estandar se comeria las lineas
    # que faltan ejecutar. Paso de verdad -- ffmpeg se llevo el paso 3 y el error que se veia
    # era el del paso 2 con el texto del 3.
    if ! eval "$linea" </dev/null >/dev/null 2>&1; then
      echo "ERROR: fallo el paso $n. El comando fue: $linea" >&2
      return 1
    fi
  done <<< "$plan"

  # Los intermedios se borran: son del proceso, no del resultado.
  rm -f "$(dirname "$final")"/.editor-paso-*.mp4 "$(dirname "$final")"/.editor-titulo-*.txt 2>/dev/null
  if [ ! -s "$final" ]; then
    echo "ERROR: el render termino pero no quedo ningun archivo en $final" >&2
    return 1
  fi
  # Se comprueba el RESULTADO, no que ffmpeg no se haya quejado: un mp4 de 0 bytes tampoco falla.
  local dfin; dfin="$(_dur "$final")"
  echo "LISTO: $final"
  echo "duracion_s: ${dfin:-?}"
  echo "tamano_mb: $(python3 -c "import os,sys; print('%.1f' % (os.path.getsize(sys.argv[1])/1048576))" "$(_w "$final")" 2>/dev/null || echo '?')"
}

case "${1:-}" in
  inspeccionar) shift; cmd_inspeccionar "$@" ;;
  transcribir)  shift; cmd_transcribir "$@" ;;
  silencios)    shift; cmd_silencios "$@" ;;
  render)       shift; cmd_render "$@" ;;
  *) sed -n '2,18p' "$0" >&2; exit 64 ;;
esac
