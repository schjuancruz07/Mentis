#!/usr/bin/env bash
# test-actualizar.sh -- el canal de actualizaciones (2026-08-07).
#
# QUE SE PRUEBA Y POR QUE:
#   Esto ejecuta codigo que viene de otra computadora, en la maquina de cinco personas. Es la parte
#   de Mentis donde un error no se paga con una funcion rota sino con la maquina de otro.
#
#   El chequeo que sostiene todo es el 3: UNA ACTUALIZACION CON FIRMA INVALIDA TIENE QUE SER
#   RECHAZADA. Si eso fallara, cualquiera que se meta en el medio del canal ejecuta lo que quiera.
#   Los demas chequeos son importantes; ese es innegociable.
#
#   Se prueba sobre una copia DE MENTIRA, nunca sobre la instalacion real: un test que actualiza el
#   Mentis del usuario es un test que un dia se lo rompe.
set -uo pipefail
TA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TA_ROOT="$(cd "$TA_HERE/.." && pwd)"
TA_OK=0; TA_MAL=0
_ok()  { TA_OK=$((TA_OK+1));  echo "  OK   $1"; }
_mal() { TA_MAL=$((TA_MAL+1)); echo "  MAL  $1  ($2)"; }

TA_TMP="$(mktemp -d)"
case "$TA_TMP" in "$TA_ROOT"|"$TA_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TA_TMP" 2>/dev/null' EXIT

source "$TA_ROOT/engine/nv-firma-lib.sh" 2>/dev/null || { echo "ABORTA: falta nv-firma-lib.sh" >&2; exit 1; }

echo "== el canal de actualizaciones =="

# --- montar un Mentis de mentira, version 0.1.0 ------------------------------------------------
TA_COPIA="$TA_TMP/mentis"
mkdir -p "$TA_COPIA/engine" "$TA_COPIA/conversations" "$TA_COPIA/memoria"
cp "$TA_ROOT/mentis-actualizar.sh" "$TA_COPIA/"
cp "$TA_ROOT/engine/nv-firma-lib.sh" "$TA_COPIA/engine/"
cp "$TA_ROOT/engine/nv-lib.sh" "$TA_COPIA/engine/" 2>/dev/null || true
printf '0.1.0\n' > "$TA_COPIA/VERSION"
printf 'codigo viejo\n' > "$TA_COPIA/archivo-de-codigo.sh"
# Datos de la persona: NO se pueden tocar pase lo que pase.
printf 'mi conversacion privada\n' > "$TA_COPIA/conversations/charla.jsonl"
printf 'mi memoria\n' > "$TA_COPIA/memoria/recuerdo.md"
printf '{"apariencia":{"nombre":"Nina"}}' > "$TA_COPIA/mentis-settings.json"

# --- el administrador publica la 0.2.0 ---------------------------------------------------------
TA_CLAVES="$TA_TMP/claves"
nv_firma_generar_par "$TA_CLAVES" >/dev/null 2>&1
cp "$TA_CLAVES/mentis-firma-publica.pem" "$TA_COPIA/mentis-firma-publica.pem"

TA_ORIGEN="$TA_TMP/origen"
mkdir -p "$TA_ORIGEN/paquetes" "$TA_TMP/nuevo"
printf 'codigo NUEVO y mejor\n' > "$TA_TMP/nuevo/archivo-de-codigo.sh"
printf '0.2.0\n' > "$TA_TMP/nuevo/VERSION"
# El paquete trae tambien un settings: NO tiene que pisar el de la persona.
printf '{"apariencia":{"nombre":"DEL PAQUETE"}}' > "$TA_TMP/nuevo/mentis-settings.json"
( cd "$TA_TMP/nuevo" && tar -czf "$TA_ORIGEN/paquetes/mentis-0.2.0.tar.gz". 2>/dev/null )

TA_TGZ="$TA_ORIGEN/paquetes/mentis-0.2.0.tar.gz"
TA_FIRMA="$(nv_firma_firmar "$TA_TGZ" "$TA_CLAVES/mentis-firma-privada.pem")"
TA_SHA="$(openssl dgst -sha256 "$TA_TGZ" 2>/dev/null | sed -E 's/.*= *//')"
_manifiesto() {
  printf '{"version":"%s","fecha":"2026-08-07","notas":"%s","archivo":"paquetes/mentis-0.2.0.tar.gz","sha256":"%s","firma":"%s"}\n' \
    "$1" "$2" "$3" "$4" > "$TA_ORIGEN/manifiesto.json"
}
_manifiesto "0.2.0" "arregle cosas" "$TA_SHA" "$TA_FIRMA"

_correr() { ( cd "$TA_COPIA" && MENTIS_ORIGEN_ACTUALIZACIONES="$TA_ORIGEN" bash./mentis-actualizar.sh "$@" 2>&1 ); }

echo "-- 1. avisa que hay algo nuevo"
TA_SAL="$(_correr revisar)"
printf '%s' "$TA_SAL" | grep -q "0.2.0" \
  && _ok "detecta la version nueva" \
  || _mal "no detecto la actualizacion" "$(printf '%s' "$TA_SAL" | tail -2 | tr '\n' ' ')"

echo "-- 2. NO instala sin que la persona diga que si"
TA_SAL="$(printf 'n\n' | _correr instalar)"
if [ "$(cat "$TA_COPIA/VERSION" | tr -d ' \r\n')" = "0.1.0" ]; then
  _ok "si contesta que no, no instala nada"
else
  _mal "instalo sin permiso" "la version cambio contestando que no"
fi

echo "-- 3. EL CHEQUEO QUE SOSTIENE TODO: firma invalida = no se instala"
_manifiesto "0.2.0" "actualizacion de un impostor" "$TA_SHA" "ZmlybWEgZmFsc2EgcXVlIG5vIHZhbGUgbmFkYQ=="
TA_SAL="$(printf 's\n' | _correr instalar)"
if [ "$(cat "$TA_COPIA/VERSION" | tr -d ' \r\n')" = "0.1.0" ] && printf '%s' "$TA_SAL" | grep -qi "FIRMA NO ES VALIDA"; then
  _ok "RECHAZA una actualizacion con firma invalida"
else
  _mal "ACEPTO UNA FIRMA INVALIDA" "cualquiera podria ejecutar codigo en esta maquina"
fi

echo "-- 4. tampoco instala si el paquete fue alterado despues de firmado"
printf 'paquete manipulado' >> "$TA_TGZ"
_manifiesto "0.2.0" "manipulada" "$TA_SHA" "$TA_FIRMA"
TA_SAL="$(printf 's\n' | _correr instalar)"
[ "$(cat "$TA_COPIA/VERSION" | tr -d ' \r\n')" = "0.1.0" ] \
  && _ok "rechaza un paquete que no coincide con su sha" \
  || _mal "instalo un paquete alterado" "el chequeo de integridad no funciona"

echo "-- 5. con la firma buena, instala"
( cd "$TA_TMP/nuevo" && tar -czf "$TA_TGZ". 2>/dev/null )
TA_FIRMA="$(nv_firma_firmar "$TA_TGZ" "$TA_CLAVES/mentis-firma-privada.pem")"
TA_SHA="$(openssl dgst -sha256 "$TA_TGZ" 2>/dev/null | sed -E 's/.*= *//')"
_manifiesto "0.2.0" "arregle cosas" "$TA_SHA" "$TA_FIRMA"
TA_SAL="$(printf 's\n' | _correr instalar)"
if [ "$(cat "$TA_COPIA/VERSION" | tr -d ' \r\n')" = "0.2.0" ]; then
  _ok "instala cuando la firma es correcta"
else
  _mal "no instalo con firma valida" "$(printf '%s' "$TA_SAL" | tail -3 | tr '\n' ' ')"
fi
grep -q "NUEVO" "$TA_COPIA/archivo-de-codigo.sh" 2>/dev/null \
  && _ok "el codigo quedo actualizado" \
  || _mal "el codigo no se actualizo" "sigue el viejo"

echo "-- 6. los datos de la persona NO se tocaron"
grep -q "mi conversacion privada" "$TA_COPIA/conversations/charla.jsonl" 2>/dev/null \
  && _ok "las conversaciones siguen intactas" || _mal "se perdieron las conversaciones" "grave"
grep -q "mi memoria" "$TA_COPIA/memoria/recuerdo.md" 2>/dev/null \
  && _ok "las memorias siguen intactas" || _mal "se perdieron las memorias" "grave"
grep -q "Nina" "$TA_COPIA/mentis-settings.json" 2>/dev/null \
  && _ok "la configuracion no fue pisada por la del paquete" \
  || _mal "el paquete piso la configuracion" "perdio su nombre y sus claves"

echo "-- 7. volver deja todo como estaba"
TA_SAL="$(_correr volver)"
if [ "$(cat "$TA_COPIA/VERSION" | tr -d ' \r\n')" = "0.1.0" ] && grep -q "codigo viejo" "$TA_COPIA/archivo-de-codigo.sh" 2>/dev/null; then
  _ok "volver restaura la version anterior"
else
  _mal "volver no restauro" "$(printf '%s' "$TA_SAL" | tail -2 | tr '\n' ' ')"
fi

echo "-- 8. frena si la persona modifico un archivo"
printf 's\n' | _correr instalar >/dev/null 2>&1     # volver a 0.2.0 para tener huellas
printf 'lo toque yo\n' > "$TA_COPIA/archivo-de-codigo.sh"
printf '0.3.0\n' > "$TA_TMP/nuevo/VERSION"
( cd "$TA_TMP/nuevo" && tar -czf "$TA_ORIGEN/paquetes/mentis-0.2.0.tar.gz". 2>/dev/null )
TA_FIRMA="$(nv_firma_firmar "$TA_TGZ" "$TA_CLAVES/mentis-firma-privada.pem")"
TA_SHA="$(openssl dgst -sha256 "$TA_TGZ" 2>/dev/null | sed -E 's/.*= *//')"
_manifiesto "0.3.0" "otra mas" "$TA_SHA" "$TA_FIRMA"
TA_SAL="$(printf 's\n' | _correr instalar)"
if printf '%s' "$TA_SAL" | grep -qi "modificaste" && grep -q "lo toque yo" "$TA_COPIA/archivo-de-codigo.sh" 2>/dev/null; then
  _ok "frena y no pisa lo que la persona modifico"
else
  _mal "piso un archivo modificado por la persona" "perdio su trabajo sin avisar"
fi

echo
echo "== $TA_OK OK, $TA_MAL MAL =="
[ "$TA_MAL" -eq 0 ]
