#!/usr/bin/env bash
# test-editor-humo.sh -- los comandos que arma el compilador, EJECUTADOS de verdad contra ffmpeg.
#
# POR QUE HACE FALTA ADEMAS DE test-editor-guion.py: ese prueba que los comandos se ARMEN bien
# (24 casos, sin ffmpeg, en un segundo). Este prueba que ffmpeg los ACEPTE. Son dos cosas
# distintas y la segunda es donde vive la clase de error mas cara de este proyecto: un filtro mal
# armado no falla, escribe un archivo silenciosamente distinto del pedido.
#
# Trabaja sobre un video SINTETICO de 12 segundos generado al vuelo (testsrc2 + un tono): no
# necesita material del usuario, corre igual en cualquier maquina y tarda pocos segundos.
#
# LO QUE SE COMPRUEBA NO ES "no exploto": se le pregunta a ffprobe la duracion, la resolucion y si
# quedo pista de audio. Un mp4 de 0 bytes tambien "no explota".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUION="$HERE/engine/editor_guion.py"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

command -v ffmpeg >/dev/null 2>&1 || { echo "sin ffmpeg: no se puede correr este test"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
TW="$(cygpath -m "$T" 2>/dev/null || printf '%s' "$T")"   # -m: C:/... con barras normales, que es JSON valido

echo "== material de prueba =="
if ffmpeg -y -f lavfi -i testsrc2=size=640x360:rate=25:duration=12 \
          -f lavfi -i sine=frequency=440:duration=12 \
          -c:v libx264 -preset ultrafast -c:a aac -shortest "$T/fuente.mp4" >/dev/null 2>&1; then
  _ok "video sintetico de 12 s generado"
else
  _mal "generar el video" "ffmpeg no pudo crear el material de prueba"; exit 1
fi

_dur()  { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | cut -d. -f1; }
_res()  { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null; }
_tiene_audio() { ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | grep -q.; }

# Corre un guion de punta a punta: compila, ejecuta cada comando y devuelve la ruta final.
_correr() { # $1 = json del guion, $2 = nombre para el log
  local gj="$T/$2.json" log="$T/$2.log" final
  printf '%s' "$1" > "$gj"
  final="$(python3 "$(cygpath -w "$GUION" 2>/dev/null || printf '%s' "$GUION")" compilar "$(cygpath -w "$gj" 2>/dev/null || printf '%s' "$gj")" 2>"$log" \
           | grep '^# salida final: ' | sed 's/^# salida final: //')"
  [ -n "$final" ] || { echo ""; return 1; }
  # Se ejecutan los comandos tal cual los imprime el compilador.
  python3 "$(cygpath -w "$GUION" 2>/dev/null || printf '%s' "$GUION")" compilar "$(cygpath -w "$gj" 2>/dev/null || printf '%s' "$gj")" 2>/dev/null \
    | grep -v '^#' > "$T/$2.sh"
  bash "$T/$2.sh" >>"$log" 2>&1
  printf '%s' "$final"
}

echo "== cortar =="
# Se queda con 0-3 y 8-11: el resultado tiene que durar ~6 s, no 12.
G1="{\"fuente\":[\"$TW\\\\fuente.mp4\"],\"salida\":{\"nombre\":\"cortado.mp4\",\"calidad\":\"media\"},\"pasos\":[{\"tipo\":\"cortar\",\"tramos\":[{\"desde_s\":0,\"hasta_s\":3},{\"desde_s\":8,\"hasta_s\":11}]}]}"
F1="$(_correr "$G1" corte)"
if [ -n "$F1" ] && [ -s "$F1" ]; then
  D="$(_dur "$F1")"
  if [ -n "$D" ] && [ "$D" -ge 5 ] && [ "$D" -le 7 ]; then
    _ok "cortar dos tramos deja ~6 s (dio ${D}s de 12)"
  else
    _mal "duracion del corte" "esperaba ~6 s y dio '${D}'"
  fi
  _tiene_audio "$F1" && _ok "el corte conserva el audio" || _mal "audio del corte" "quedo sin pista de audio"
else
  _mal "cortar" "no se genero el archivo -- ver $T/corte.log"
fi

echo "== formato vertical =="
G2="{\"fuente\":[\"$TW\\\\fuente.mp4\"],\"salida\":{\"nombre\":\"vertical.mp4\",\"formato\":\"9:16\",\"calidad\":\"baja\"},\"pasos\":[{\"tipo\":\"formato\"}]}"
F2="$(_correr "$G2" vertical)"
if [ -n "$F2" ] && [ -s "$F2" ]; then
  R="$(_res "$F2")"
  [ "$R" = "1080x1920" ] && _ok "9:16 sale exactamente 1080x1920" || _mal "resolucion vertical" "dio '$R'"
else
  _mal "formato" "no se genero el archivo -- ver $T/vertical.log"
fi

echo "== titulo con caracteres que rompen filtros =="
# Dos puntos, comillas y barra invertida: los tres rompen el parser de filtros si no se escapan.
# Este es el caso que en el resto del proyecto se conoce como ERR-159.
G3="{\"fuente\":[\"$TW\\\\fuente.mp4\"],\"salida\":{\"nombre\":\"titulado.mp4\",\"calidad\":\"baja\"},\"pasos\":[{\"tipo\":\"titulo\",\"texto\":\"Precio: 5 'pesos'\",\"desde_s\":0,\"dura_s\":2}]}"
F3="$(_correr "$G3" titulo)"
if [ -n "$F3" ] && [ -s "$F3" ]; then
  D="$(_dur "$F3")"
  if [ -n "$D" ] && [ "$D" -ge 11 ]; then
    _ok "el titulo con ':' y comillas se dibuja sin romper el filtro"
  else
    _mal "titulo" "el video quedo de ${D}s: el filtro fallo y no se escribio entero"
  fi
else
  _mal "titulo" "no se genero el archivo -- ver $T/titulo.log"
fi

echo "== musica con ducking =="
ffmpeg -y -f lavfi -i sine=frequency=220:duration=12 -c:a libmp3lame "$T/musica.mp3" >/dev/null 2>&1
G4="{\"fuente\":[\"$TW\\\\fuente.mp4\"],\"salida\":{\"nombre\":\"conmusica.mp4\",\"calidad\":\"baja\"},\"pasos\":[{\"tipo\":\"musica\",\"archivo\":\"$TW\\\\musica.mp3\",\"volumen\":0.2,\"ducking\":true}]}"
F4="$(_correr "$G4" musica)"
if [ -n "$F4" ] && [ -s "$F4" ]; then
  _tiene_audio "$F4" && _ok "la mezcla con ducking produce audio" || _mal "ducking" "el archivo quedo sin audio"
  D="$(_dur "$F4")"
  if [ -n "$D" ] && [ "$D" -ge 11 ]; then
    _ok "la musica no acorta el video (duration=first)"
  else
    _mal "duracion con musica" "quedo de ${D}s en vez de 12"
  fi
else
  _mal "musica" "no se genero el archivo -- ver $T/musica.log"
fi

echo "== la cadena completa: cortar + formato + titulo =="
G5="{\"fuente\":[\"$TW\\\\fuente.mp4\"],\"salida\":{\"nombre\":\"completo.mp4\",\"formato\":\"9:16\",\"calidad\":\"baja\"},\"pasos\":[{\"tipo\":\"cortar\",\"tramos\":[{\"desde_s\":1,\"hasta_s\":6}]},{\"tipo\":\"formato\"},{\"tipo\":\"titulo\",\"texto\":\"Fin\",\"desde_s\":0,\"dura_s\":2}]}"
F5="$(_correr "$G5" completo)"
if [ -n "$F5" ] && [ -s "$F5" ]; then
  D="$(_dur "$F5")"; R="$(_res "$F5")"
  # Las tres cosas a la vez: el corte se aplico, el formato se aplico, y el titulo no rompio nada.
  if [ -n "$D" ] && [ "$D" -ge 4 ] && [ "$D" -le 6 ] && [ "$R" = "1080x1920" ]; then
    _ok "los tres pasos se encadenan (${D}s, $R)"
  else
    _mal "cadena de tres pasos" "duracion='${D}' resolucion='$R' (esperaba ~5s y 1080x1920)"
  fi
else
  _mal "cadena completa" "no se genero el archivo -- ver $T/completo.log"
fi

echo ""
printf 'test-editor-humo: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
