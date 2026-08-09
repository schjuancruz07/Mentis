#!/usr/bin/env bash
# test-instalar.sh -- la copia de Mentis para otra persona sale SIN los datos del usuario.
#
# QUE SE PRUEBA Y POR QUE:
#   Esta carpeta tiene conversaciones enteras, memorias sobre la vida del usuario, su ubicacion y su
#   mail. Una copia mal hecha no es un bug de prolijidad: es filtrarle la vida a otra persona, y el
#   error se descubre cuando la copia ya esta en la maquina de un amigo.
#
#   Por eso se prueba sobre una copia DE VERDAD, hecha con el propio instalador, y se revisa con
#   chequeos independientes del que trae el script -- si el instalador tuviera un bug en su propia
#   revision, esta suite lo tiene que ver igual.
set -uo pipefail
TI_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TI_ROOT="$(cd "$TI_HERE/.." && pwd)"
TI_OK=0; TI_MAL=0
_ok()  { TI_OK=$((TI_OK+1));  echo "  OK   $1"; }
_mal() { TI_MAL=$((TI_MAL+1)); echo "  MAL  $1  ($2)"; }

TI_TMP="$(mktemp -d)"
case "$TI_TMP" in
  "$TI_ROOT"|"$TI_ROOT"/*) echo "ABORTA: el temporal cae dentro de Mentis" >&2; exit 1 ;;
esac
TI_COPIA="$TI_TMP/copia"
trap 'rm -rf "$TI_TMP" 2>/dev/null' EXIT

echo "== la copia para otra persona =="
echo "-- preparando una copia real (tarda un poco)"

if bash "$TI_ROOT/mentis-instalar.sh" preparar "$TI_COPIA" > "$TI_TMP/salida.txt" 2>&1; then
  _ok "el instalador dice que la copia esta limpia"
else
  _mal "el instalador reporto problemas" "$(grep 'MAL:' "$TI_TMP/salida.txt" | head -3 | tr '\n' ' ')"
fi

echo "-- lo personal no viajo (chequeos propios, no los del instalador)"

_vacio_o_ausente() {
  local ruta="$TI_COPIA/$1" que="$2"
  if [ ! -e "$ruta" ] || [ -z "$(ls -A "$ruta" 2>/dev/null)" ]; then
    _ok "$que no viajo"
  else
    _mal "$que VIAJO" "$(find "$ruta" -type f 2>/dev/null | wc -l) archivos en $1"
  fi
}
_vacio_o_ausente "conversations"        "las conversaciones"
_vacio_o_ausente "memoria"              "las memorias"
_vacio_o_ausente "engine/logs"          "los logs"
_vacio_o_ausente "engine/index"         "el indice de busqueda"
_vacio_o_ausente "engine/recall-corpus" "el corpus del pasado"
_vacio_o_ausente "scheduled-runs"       "las tareas programadas"
_vacio_o_ausente "avatar"               "la foto de perfil"

[ ! -e "$TI_COPIA/engine/.web-token" ] \
  && _ok "la llave de la pagina del celular no viajo" \
  || _mal "viajo el token de la web" "engine/.web-token"

# Claves de API. tests/ queda afuera porque test-guardas.sh usa claves de juguete a proposito.
TI_CLAVES="$(grep -rlE "nvapi-[A-Za-z0-9_-]{20,}" "$TI_COPIA" 2>/dev/null | grep -v "/tests/" | head -3)"
[ -z "$TI_CLAVES" ] \
  && _ok "no viajo ninguna clave de NVIDIA" \
  || _mal "VIAJARON CLAVES" "$(printf '%s' "$TI_CLAVES" | tr '\n' ' ')"

# El mail se arma en dos pedazos para que este archivo no lo contenga entero y no se detecte solo.
TI_U="usuario"; TI_U="${TI_U}07"
TI_MAIL="$(grep -rli "$TI_U" "$TI_COPIA" 2>/dev/null | grep -v "/docs/" | head -3)"
[ -z "$TI_MAIL" ] \
  && _ok "no quedo el mail del usuario en ningun lado" \
  || _mal "quedo el mail del usuario" "$(printf '%s' "$TI_MAIL" | tr '\n' ' ')"

TI_PERFIL="$(python3 -c '
import json, io, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
p = d.get("profile") or {}
print("".join(str(p.get(k) or "") for k in ("fullName", "nickname", "role", "instructions")))
' "$(cygpath -w "$TI_COPIA/mentis-settings.json" 2>/dev/null || printf '%s' "$TI_COPIA/mentis-settings.json")" 2>/dev/null)"
[ -z "$TI_PERFIL" ] \
  && _ok "el perfil viaja vacio" \
  || _mal "el perfil trae datos" "$TI_PERFIL"

echo "-- pero Mentis sigue entero"
# Una copia limpia que no funciona no sirve: se comprueba que el motor y las piezas esten.
for x in "engine/ask-nvidia.sh" "engine/nv-agent.sh" "engine/nv_stream.py" "mentis-chat.sh" \
         "app/main.js" "app/renderer/formato.js" "INSTALAR.md" "mentis-instalar.sh"; do
  [ -f "$TI_COPIA/$x" ] && _ok "esta $x" || _mal "falta $x" "la copia no arrancaria"
done

TI_SH="$(ls "$TI_COPIA"/*.sh 2>/dev/null | wc -l)"
[ "$TI_SH" -ge 30 ] \
  && _ok "viajaron los scripts ($TI_SH en la raiz)" \
  || _mal "faltan scripts" "solo $TI_SH en la raiz"

echo
echo "== $TI_OK OK, $TI_MAL MAL =="
[ "$TI_MAL" -eq 0 ]
