#!/usr/bin/env bash
# test-webcam.sh — los ojos de Mentis.
#
# Lo que más importa acá NO es que la foto salga bien, sino que la cámara no se pueda encender
# sola. Es la única herramienta que ve la habitación del usuario: si algún día se enciende sin que él
# lo sepa, da igual lo bien que funcione todo lo demás.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/mentis-webcam.sh"
AGENTE="$DIR/engine/nv-agent.sh"
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fail=1; fi; }

bash -n "$SCRIPT" && echo "ok: mentis-webcam.sh parsea sin errores" || { echo "FAIL: sintaxis"; fail=1; }

echo "== 1. las DOS llaves: sin permiso no hay camara =="
grep -q 'ALLOW_WEBCAM:-0}" != "1"' "$AGENTE" && echo "ok: sin la bandera -V, la herramienta se rechaza" || { echo "FAIL: falta el chequeo de permiso"; fail=1; }
grep -q "_connector_enabled 'local:webcam'" "$AGENTE" && echo "ok: ademas exige el conector encendido desde la app" || { echo "FAIL: no chequea el conector"; fail=1; }

echo "== 2. arranca APAGADA =="
# getConnectorEnabled devuelve false para lo que nunca se toco. Que la clave NO este en settings
# es exactamente lo que se quiere: nadie la encendio todavia.
CONF="$(cygpath -w "$DIR/mentis-settings.json" 2>/dev/null || echo "$DIR/mentis-settings.json")"
MW_CONF="$CONF" python3 -c "
import json, os, sys
d = json.load(open(os.environ['MW_CONF'], encoding='utf-8'))
v = (d.get('connectorsEnabled') or {}).get('local:webcam')
if v is True:
    print('aviso: la camara figura ENCENDIDA en settings (la encendio el usuario a proposito?)')
else:
    print('ok: la camara no viene encendida de fabrica')
" || { echo "FAIL: no pude leer settings"; fail=1; }

echo "== 3. no queda ningun proceso mirando =="
# El contrato es: se prende, saca la foto, se apaga. Si el script dejara ffmpeg corriendo, la luz
# de la camara quedaria encendida y Mentis estaria grabando sin que nadie se lo pidiera.
ANTES="$(powershell.exe -NoProfile -NonInteractive -Command "(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r[:space:]')"
FOTO="$(mktemp -u).jpg"
bash "$SCRIPT" -o "$FOTO" >/dev/null 2>&1
sleep 1
DESPUES="$(powershell.exe -NoProfile -NonInteractive -Command "(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r[:space:]')"
chk "${DESPUES:-0}" "${ANTES:-0}" "no queda ffmpeg corriendo despues de la foto"

echo "== 4. la foto es una imagen de verdad =="
if [ -s "$FOTO" ]; then
  MAGIC="$(head -c 3 "$FOTO" | xxd -p 2>/dev/null)"
  case "$MAGIC" in
    ffd8ff) echo "ok: la camara devuelve un JPEG valido" ;;
    *) echo "FAIL: el archivo no es un JPEG (magic: $MAGIC)"; fail=1 ;;
  esac
else
  echo "aviso: no se genero foto -- puede no haber camara disponible en esta maquina"
fi

echo "== 5. avisa cuando la foto no sirve (esto evita que el modelo invente) =="
# Una webcam tapada devuelve un JPEG perfectamente valido y negro. Sin este aviso, el modelo
# describe la nada como si hubiera visto algo, y esa descripcion llega como un hecho.
grep -q "casi negra" "$SCRIPT" && echo "ok: mide el brillo y avisa si salio negra" || { echo "FAIL: no detecta fotos negras"; fail=1; }
grep -q "desconfiá" "$AGENTE" && echo "ok: ese aviso viaja al modelo junto con la descripcion" || { echo "FAIL: el aviso no llega al modelo"; fail=1; }
rm -f "$FOTO"

echo "== 6. las tres acciones que pidio el usuario estan =="
for acc in mirar leer presencia; do
  grep -q "$acc" "$AGENTE" && echo "ok: existe la accion '$acc'" || { echo "FAIL: falta '$acc'"; fail=1; }
done
grep -q "accion de webcam desconocida" "$AGENTE" && echo "ok: rechaza acciones que no existen" || { echo "FAIL: acepta cualquier accion"; fail=1; }

echo "== 7. no graba video ni guarda de mas =="
if grep -qE '\-t +[0-9]+|record|\.mp4' "$SCRIPT"; then
  echo "FAIL: el script parece grabar video, no sacar una foto"; fail=1
else
  echo "ok: solo saca fotos, no graba"
fi

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
