#!/usr/bin/env bash
# test-formato.sh -- el formato de las respuestas (negrita, cursiva, listas, codigo).
#
# QUE SE PRUEBA Y POR QUE:
#   Las respuestas se pintaban con textContent, o sea texto plano, y los modelos escriben en
#   markdown por costumbre: llegaban los asteriscos crudos. Ahora se formatean.
#
#   Lo que NO se puede fallar es el escapado: el texto viene de un modelo que pudo haber leido
#   cualquier pagina web. Si se formateara sin escapar antes, un "<img onerror=...>" en una pagina
#   cualquiera terminaria ejecutandose dentro de la ventana de Mentis, que tiene acceso a la
#   maquina. Por eso los primeros casos del set son de seguridad.
#
#   Y se prueba que el formateador sea UNO SOLO para la app y el celular: con dos copias, el dia
#   que se arregle un caso raro en una el otro se queda con el bug -- y el celular es donde menos
#   se mira.
set -uo pipefail
TF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "$TF_HERE/.." && pwd)"
TF_OK=0; TF_MAL=0
_ok()  { TF_OK=$((TF_OK+1));  echo "  OK   $1"; }
_mal() { TF_MAL=$((TF_MAL+1)); echo "  MAL  $1  ($2)"; }

echo "== formato de las respuestas =="

if ! command -v node >/dev/null 2>&1; then
  echo "ABORTA: hace falta node para correr los casos" >&2
  exit 1
fi

echo "-- los casos del formateador"
TF_SAL="$(node "$TF_HERE/formato_casos.mjs" 2>&1)"
if [ $? -eq 0 ]; then
  _ok "$(printf '%s' "$TF_SAL" | grep -o 'TODO OK ([0-9]* casos)')"
else
  _mal "hay casos fallando" "$(printf '%s' "$TF_SAL" | grep '^FALLA' | head -3 | tr '\n' ' ')"
fi

echo "-- un solo formateador para los dos lados"
[ -f "$TF_ROOT/app/renderer/formato.js" ] \
  && _ok "existe app/renderer/formato.js" \
  || _mal "falta el formateador" "app/renderer/formato.js"

grep -q "estatico/renderer/formato.js" "$TF_ROOT/engine/nv_web_server.py" \
  && _ok "el celular usa el MISMO archivo que la app (servido desde /estatico)" \
  || _mal "el celular no sirve formato.js" "o tiene una copia propia, que un dia va a divergir"

grep -q "MentisFormato" "$TF_ROOT/app/renderer/renderer.js" \
  && _ok "la app usa el formateador" \
  || _mal "la app no lo usa" "las respuestas seguirian en texto plano"

echo "-- el escapado no se puede desactivar"
# formatearMensaje SIEMPRE tiene que empezar escapando. Si alguien reordena y el escape queda
# despues del formateo, los casos de seguridad de arriba fallan -- pero este chequeo lo dice claro.
grep -q "escaparHtml(texto)" "$TF_ROOT/app/renderer/formato.js" \
  && _ok "formatearMensaje escapa el HTML antes de formatear" \
  || _mal "el escapado no esta al principio" "riesgo de inyeccion con texto de una pagina leida"

echo "-- lo del usuario se muestra tal cual"
# Las burbujas del usuario van SIN formato: es lo que el escribio y tiene que verse igual.
grep -q "bubble.textContent = cleanText" "$TF_ROOT/app/renderer/renderer.js" \
  && _ok "los mensajes del usuario siguen en texto plano" \
  || _mal "los mensajes del usuario cambiaron de camino" "revisar que no se les aplique markdown"

echo
echo "== $TF_OK OK, $TF_MAL MAL =="
[ "$TF_MAL" -eq 0 ]
