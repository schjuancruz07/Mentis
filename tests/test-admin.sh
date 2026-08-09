#!/usr/bin/env bash
# test-admin.sh -- el modo administrador y los frenos para publicar (2026-08-07).
#
# QUE SE PRUEBA Y POR QUE:
#   El switch de "modo administrador" es COMODIDAD, no seguridad: la app es la misma en las cinco
#   maquinas, el switch esta en el codigo de todas y cualquiera con DevTools puede activarlo.
#
#   Entonces lo que hay que probar NO es que el switch se esconda bien, sino que activarlo no
#   alcance para publicar nada. Los frenos reales estan en mentis-publicar.sh y son los que se
#   prueban aca: sin clave, sin notas, con la version repetida o con los tests en rojo, no sale.
set -uo pipefail
TAD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAD_ROOT="$(cd "$TAD_HERE/.." && pwd)"
TAD_OK=0; TAD_MAL=0
_ok()  { TAD_OK=$((TAD_OK+1));  echo "  OK   $1"; }
_mal() { TAD_MAL=$((TAD_MAL+1)); echo "  MAL  $1  ($2)"; }

TAD_TMP="$(mktemp -d)"
case "$TAD_TMP" in "$TAD_ROOT"|"$TAD_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TAD_TMP" 2>/dev/null' EXIT

echo "== modo administrador =="

echo "-- el switch aparece solo donde hay clave privada"
# OJO CON LAS RUTAS (ERR-004/006, y volvio a morder aca): a node hay que darle rutas de Windows,
# no las de MSYS. Un require("/c/Users/...") falla y el test daria "no distingue" sobre una funcion
# que anda perfecto -- que es exactamente lo que paso al escribir esto. Se resuelve entrando a la
# carpeta y usando rutas relativas, y armando los temporales con el propio node.
( cd "$TAD_ROOT" && node -e '
const s = require("./app/lib/settings-store.js");
const fs = require("fs"), path = require("path"), os = require("os");
const base = fs.mkdtempSync(path.join(os.tmpdir(), "mentis-adm-"));
const sin = path.join(base, "sinclave");
fs.mkdirSync(sin, { recursive: true });
if (s.esAdministrador(sin)) { console.error("MAL: dijo administrador sin clave"); process.exit(1); }
const con = path.join(base, "conclave");
fs.mkdirSync(path.join(con, ".firma"), { recursive: true });
fs.writeFileSync(path.join(con, ".firma", "mentis-firma-privada.pem"), "x");
if (!s.esAdministrador(con)) { console.error("MAL: no reconocio la clave"); process.exit(1); }
fs.rmSync(base, { recursive: true, force: true });
' ) >/dev/null 2>&1 \
  && _ok "sin clave privada NO es administrador; con clave si" \
  || _mal "esAdministrador no distingue" "el panel aparecería donde no corresponde"

echo "-- los frenos de publicar (esto es lo que de verdad protege)"
_publicar() { ( cd "$TAD_ROOT" && MENTIS_CLAVES_DIR="$1" MENTIS_PUBLICAR_DIR="$TAD_TMP/salida" \
                 bash./mentis-publicar.sh publicar "${2-}" 2>&1 ); }

# 1. Sin notas no se publica: quien recibe tiene que poder decidir si la quiere.
TAD_SAL="$(_publicar "$TAD_ROOT/.firma" "")"
printf '%s' "$TAD_SAL" | grep -qi "falta decir que cambia" \
  && _ok "sin notas FRENA" \
  || _mal "publico sin notas" "$(printf '%s' "$TAD_SAL" | head -2 | tr '\n' ' ')"

# 2. Sin clave privada no se publica. Es el freno que hace que el switch no alcance.
TAD_SAL="$(_publicar "$TAD_TMP/no-hay-claves-aca" "unas notas cualquiera")"
printf '%s' "$TAD_SAL" | grep -qi "no hay clave privada" \
  && _ok "sin clave privada FRENA (activar el switch no alcanza)" \
  || _mal "intento publicar sin clave" "$(printf '%s' "$TAD_SAL" | head -2 | tr '\n' ' ')"

# 3. La version tiene que subir: publicar con el mismo numero deja a todos sin enterarse.
mkdir -p "$TAD_TMP/salida"
TAD_V="$(tr -d ' \r\n' < "$TAD_ROOT/VERSION")"
printf '{"version":"%s","notas":"ya publicada"}' "$TAD_V" > "$TAD_TMP/salida/manifiesto.json"
TAD_SAL="$(_publicar "$TAD_ROOT/.firma" "intento repetir la version")"
printf '%s' "$TAD_SAL" | grep -qi "no es mayor que la publicada" \
  && _ok "con la version repetida FRENA" \
  || _mal "dejo publicar la misma version" "$(printf '%s' "$TAD_SAL" | head -3 | tr '\n' ' ')"

echo "-- el trabajo pesado NO esta duplicado en la app"
# Si la interfaz repitiera los frenos, un dia dirian cosas distintas y se publicaria desde la app
# algo que el script habria rechazado.
grep -q "mentis-publicar.sh" "$TAD_ROOT/app/main.js" \
  && _ok "la app invoca el script en vez de reimplementarlo" \
  || _mal "la app no usa mentis-publicar.sh" "los frenos podrian divergir"
grep -q "esAdministrador(MENTIS_ENV_DIR)" "$TAD_ROOT/app/main.js" \
  && _ok "la app revalida la clave del lado del proceso principal" \
  || _mal "no hay segundo cerrojo en main.js" "forzar el switch alcanzaria para invocar publicar"

echo "-- la clave privada nunca sale de la maquina"
grep -q "mentis-firma-privada" "$TAD_ROOT/mentis-publicar.sh" \
  && _ok "la privada solo se usa para firmar, localmente" \
  || _mal "no encuentro el uso de la clave privada" "revisar mentis-publicar.sh"
# No puede viajar en el paquete ni en la copia para otros.
grep -q '"\.firma"' "$TAD_ROOT/mentis-publicar.sh" \
  && _ok "la carpeta.firma esta excluida del paquete" \
  || _mal "la clave privada podria viajar en la actualizacion" "GRAVE"
grep -q '"\.firma"' "$TAD_ROOT/mentis-instalar.sh" \
  && _ok "la carpeta.firma esta excluida de la copia para otros" \
  || _mal "la clave privada podria viajar en la copia" "GRAVE"

echo
echo "== $TAD_OK OK, $TAD_MAL MAL =="
[ "$TAD_MAL" -eq 0 ]
