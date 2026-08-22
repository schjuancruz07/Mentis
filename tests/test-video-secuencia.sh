#!/usr/bin/env bash
# test-video-secuencia.sh -- el analisis de video tiene que ver lo que PASA, no cinco fotos sueltas.
#
# QUE PRUEBA Y POR QUE ES ESTE VIDEO:
#   tests/datos/video-secuencia.mp4 dura 20 s: es azul, se pone ROJO entre el segundo 15 y el 16, y
#   vuelve a azul. Ese ROJO es el evento. La version vieja del analizador sacaba 5 fotogramas fijos
#   (2, 6, 10, 14 y 18 s) y los CINCO salian azules: el evento no existia para el sistema, y la
#   descripcion del video habria sido "una pantalla azul", con total seguridad y total error.
#
#   El video se genera con ffmpeg y esta en el repo porque un test que fabrica su propio video en
#   cada corrida mide tambien la fabricacion. Si falta, el test lo rehace y lo dice.
#
# COMO SE VERIFICA: se mira el COLOR DE LOS PIXELES de los fotogramas que el analizador eligio. No
# se le pregunta a ningun modelo -- un modelo de vision podria acertar o inventar, y este test
# quedaria midiendo al modelo en vez de al extractor.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
VIDEO="$HERE/datos/video-secuencia.mp4"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok   -- $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA-- $1"; }

echo "== analisis de video como secuencia =="
command -v ffmpeg >/dev/null 2>&1 || { echo "  -- (salteado) no hay ffmpeg"; exit 0; }

if [ ! -s "$VIDEO" ]; then
  mkdir -p "$HERE/datos"
  ffmpeg -y -f lavfi -i color=c=blue:s=320x240:d=15 -f lavfi -i color=c=red:s=320x240:d=1 \
         -f lavfi -i color=c=blue:s=320x240:d=4 \
         -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1[v]" -map "[v]" -pix_fmt yuv420p -r 10 \
         "$VIDEO" >/dev/null 2>&1
  [ -s "$VIDEO" ] && echo "  --   -- el video de prueba no estaba; lo regenere"
fi
[ -s "$VIDEO" ] || { _mal "no se pudo preparar el video de prueba"; echo "== $OK ok, $MAL falla(s) =="; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SAL="$(bash "$RAIZ/mentis-video-analyze.sh" "$VIDEO" "$TMP" 2>/dev/null)"

# 1. El formato tiene que seguir siendo el que espera quien lo llama.
case "$SAL" in
  *"DURACION:"*) _ok "informa la duracion" ;;
  *) _mal "falta la linea DURACION" ;;
esac
case "$SAL" in
  *"FRAMES:"*) _ok "informa los fotogramas" ;;
  *) _mal "falta la seccion FRAMES" ;;
esac
case "$SAL" in
  *"TRANSCRIPT:"*) _ok "informa la transcripcion" ;;
  *) _mal "falta la seccion TRANSCRIPT" ;;
esac

# 2. Cada fotograma viene con su marca de tiempo. Sin eso no hay secuencia, hay bolsa de imagenes.
LINEAS="$(printf '%s\n' "$SAL" | sed -n '/^FRAMES:/,/^TRANSCRIPT:/p' | grep -E '^[0-9]+\|' || true)"
CUANTOS="$(printf '%s\n' "$LINEAS" | grep -c. || true)"
if [ "${CUANTOS:-0}" -ge 5 ]; then
  _ok "salieron $CUANTOS fotogramas, todos con su segundo"
else
  _mal "solo $CUANTOS fotogramas con marca de tiempo (se esperaban 5 o mas)"
fi

# 3. Los tiempos tienen que ir en orden. Una linea de tiempo desordenada no es una linea de tiempo.
ORDEN_OK=1; ANT=-1
while IFS='|' read -r seg _; do
  [ -n "$seg" ] || continue
  [ "$seg" -lt "$ANT" ] && ORDEN_OK=0
  ANT="$seg"
done <<< "$LINEAS"
[ "$ORDEN_OK" = "1" ] && _ok "los fotogramas vienen ordenados en el tiempo" \
                      || _mal "los fotogramas salieron desordenados"

# 4. EL PUNTO DE TODO ESTO: que el evento de 1 segundo aparezca.
# El color se mira archivo por archivo con un.py aparte. La primera version encadenaba
# cut | while | python3 -c en un solo pipeline y daba 0 rojos con fotogramas que SI eran rojos:
# entre la traduccion de rutas y el heredoc de python habia demasiadas piezas para saber cual
# fallaba. Un archivo con nombre y una llamada por imagen se puede probar solo.
_es_rojo() {
  local w
  w="$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")"
  python3 "$HERE/datos/es_rojo.py" "$w" 2>/dev/null | tr -d '
'
}
ROJOS=0
SIN_PIL=0
while IFS='|' read -r _seg _ruta; do
  [ -n "$_ruta" ] || continue
  case "$(_es_rojo "$_ruta")" in
    si) ROJOS=$((ROJOS + 1)) ;;
    SIN-PIL) SIN_PIL=1 ;;
  esac
done <<< "$LINEAS"
[ "$SIN_PIL" = "1" ] && ROJOS="SIN-PIL"

if [ "$ROJOS" = "SIN-PIL" ]; then
  echo "  --   -- (salteado) sin PIL no se puede mirar el color de los fotogramas"
elif [ "${ROJOS:-0}" -ge 1 ]; then
  _ok "capturo el evento de 1 segundo ($ROJOS fotograma(s) del momento rojo)"
else
  _mal "NO capturo el evento: ningun fotograma es del momento rojo (es lo que hacia la version vieja)"
fi

# 5. Control: el metodo viejo (5 fijos cada 20%) NO lo captura. Sin esto, un dia alguien podria
#    creer que el video de prueba es facil y que cualquier extractor lo resuelve.
VIEJOS="$TMP/viejo"; mkdir -p "$VIEJOS"
for pct in 10 30 50 70 90; do
  ts=$((20 * pct / 100))
  ffmpeg -y -ss "$ts" -i "$VIDEO" -frames:v 1 -q:v 3 "$VIEJOS/v-$pct.jpg" >/dev/null 2>&1
done
ROJOS_VIEJO=0
for _f in "$VIEJOS"/*.jpg; do
  [ -e "$_f" ] || continue
  [ "$(_es_rojo "$_f")" = "si" ] && ROJOS_VIEJO=$((ROJOS_VIEJO + 1))
done

if [ "${ROJOS_VIEJO:-0}" -eq 0 ]; then
  _ok "control: el metodo viejo de 5 fotogramas fijos NO ve el evento (por eso se cambio)"
else
  _mal "el metodo viejo tambien lo capturaba: este video no prueba nada, hay que hacer uno mas dificil"
fi

echo
echo "== $OK ok, $MAL falla(s) =="
[ "$MAL" -eq 0 ]
