#!/usr/bin/env bash
# test-temas.sh -- las paletas y el nombre elegibles (2026-08-06).
#
# QUE SE PRUEBA Y POR QUE:
#   Mentis pasa a usarlo mas gente y cada uno elige como se ve y como se llama. Dos cosas pueden
#   fallar en silencio y las dos arruinan la funcion:
#
#   1. Que una paleta deje el texto ilegible. "Se ve bien" no es una medicion: temas_casos.mjs
#      calcula el contraste real (WCAG) de cada combinacion que importa y falla si baja del minimo.
#   2. Que el nombre cambie SOLO en la ventana. Si el prompt del sistema sigue diciendo "Sos
#      Mentis", la IA se presenta como Mentis por mas que la pantalla diga otra cosa -- y esa
#      contradiccion es peor que no dejar cambiarlo. Por eso se verifica que el nombre llegue al
#      PROMPT, que es lo unico que decide como se presenta.
#
#   Y que la app y el celular usen el MISMO archivo de paletas: con dos listas, el tema elegido se
#   veria distinto en el telefono.
set -uo pipefail
TT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TT_ROOT="$(cd "$TT_HERE/.." && pwd)"
TT_OK=0; TT_MAL=0
_ok()  { TT_OK=$((TT_OK+1));  echo "  OK   $1"; }
_mal() { TT_MAL=$((TT_MAL+1)); echo "  MAL  $1  ($2)"; }

echo "== temas y nombre =="

echo "-- las paletas (contraste medido, no a ojo)"
if command -v node >/dev/null 2>&1; then
  TT_SAL="$(node "$TT_HERE/temas_casos.mjs" 2>&1)"
  if [ $? -eq 0 ]; then
    _ok "$(printf '%s' "$TT_SAL" | grep -o 'TODO OK ([0-9]* temas)')"
  else
    _mal "hay paletas que no pasan" "$(printf '%s' "$TT_SAL" | grep '^FALLA' | head -2 | tr '\n' ' ')"
  fi
else
  _mal "no hay node" "no se puede medir el contraste"
fi

echo "-- un solo archivo de paletas para los dos lados"
[ -f "$TT_ROOT/app/renderer/temas.js" ] && _ok "existe app/renderer/temas.js" \
  || _mal "falta el archivo de paletas" "app/renderer/temas.js"
grep -q "estatico/renderer/temas.js" "$TT_ROOT/engine/nv_web_server.py" \
  && _ok "el celular sirve el MISMO archivo que usa la app" \
  || _mal "el celular no sirve temas.js" "el tema no llegaria al telefono"
grep -q "MentisTemas" "$TT_ROOT/app/renderer/renderer.js" \
  && _ok "la app aplica la paleta elegida" \
  || _mal "la app no usa MentisTemas" "el selector no haria nada"

echo "-- el nombre llega al PROMPT, no solo a la ventana"
grep -q "nv_nombre_ia" "$TT_ROOT/engine/nv-lib.sh" \
  && _ok "existe nv_nombre_ia en la libreria" \
  || _mal "no existe nv_nombre_ia" "cada script leeria el nombre por su cuenta"
grep -q 'Sos \$NOMBRE_IA' "$TT_ROOT/engine/ask-nvidia.sh" \
  && _ok "el prompt del rol rapido usa el nombre configurado" \
  || _mal "ask-nvidia.sh tiene el nombre fijo" "se presentaria como Mentis igual"
grep -q 'Sos \$MC_NOMBRE_IA' "$TT_ROOT/mentis-chat.sh" \
  && _ok "el prompt del chat usa el nombre configurado" \
  || _mal "mentis-chat.sh tiene el nombre fijo" "se presentaria como Mentis igual"

echo "-- la lectura del nombre funciona de verdad"
source "$TT_ROOT/engine/nv-lib.sh" 2>/dev/null
if type -t nv_nombre_ia >/dev/null 2>&1; then
  TT_TMP="$(mktemp -d)"
  trap 'rm -rf "$TT_TMP" 2>/dev/null' EXIT
  # Sin configuracion: tiene que devolver Mentis, no vacio. Una IA sin nombre no puede presentarse.
  printf '%s' '{}' > "$TT_TMP/mentis-settings.json"
  TT_N="$(MENTIS_SETTINGS_FILE="$TT_TMP/mentis-settings.json" nv_nombre_ia)"
  [ "$TT_N" = "Mentis" ] && _ok "sin configurar nada devuelve 'Mentis'" \
    || _mal "sin configurar devolvio '$TT_N'" "deberia ser Mentis"

  printf '%s' '{"apariencia":{"nombre":"Nina"}}' > "$TT_TMP/mentis-settings.json"
  TT_N="$(MENTIS_SETTINGS_FILE="$TT_TMP/mentis-settings.json" nv_nombre_ia)"
  [ "$TT_N" = "Nina" ] && _ok "lee el nombre elegido ('Nina')" \
    || _mal "leyo '$TT_N'" "esperaba Nina"

  # Un nombre en blanco no puede dejar a la IA sin nombre.
  printf '%s' '{"apariencia":{"nombre":"   "}}' > "$TT_TMP/mentis-settings.json"
  TT_N="$(MENTIS_SETTINGS_FILE="$TT_TMP/mentis-settings.json" nv_nombre_ia)"
  [ "$TT_N" = "Mentis" ] && _ok "un nombre en blanco vuelve a 'Mentis'" \
    || _mal "con el nombre en blanco devolvio '$TT_N'" "deberia caer a Mentis"

  # Un archivo roto tampoco: degrada, no rompe.
  printf '%s' '{"apariencia":{' > "$TT_TMP/mentis-settings.json"
  TT_N="$(MENTIS_SETTINGS_FILE="$TT_TMP/mentis-settings.json" nv_nombre_ia)"
  [ "$TT_N" = "Mentis" ] && _ok "con el archivo roto degrada a 'Mentis'" \
    || _mal "con JSON roto devolvio '$TT_N'" "deberia caer a Mentis"
else
  _mal "no pude cargar nv_nombre_ia" "revisar nv-lib.sh"
fi

echo "-- el celular puede pedir la apariencia"
grep -q "/api/apariencia" "$TT_ROOT/engine/nv_web_server.py" \
  && _ok "la pagina expone /api/apariencia" \
  || _mal "falta el endpoint de apariencia" "el telefono no sabria que tema usar"

echo
echo "== $TT_OK OK, $TT_MAL MAL =="
[ "$TT_MAL" -eq 0 ]
