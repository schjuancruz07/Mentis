#!/usr/bin/env bash
# El canal de actualizaciones.
#
# REESCRITO EL 2026-08-18. La version anterior probaba un mecanismo que ya no existe: manifiesto
# JSON firmado + tarball bajado de MENTIS_ORIGEN_ACTUALIZACIONES. mentis-actualizar.sh hace hoy
# `git pull --ff-only origin main`, asi que sus 11 aserciones fallaban contra codigo correcto.
# Una de ellas gritaba "ACEPTO UNA FIRMA INVALIDA -- cualquiera podria ejecutar codigo en esta
# maquina": alarma falsa, porque el script cortaba mucho antes y no instalaba nada. Un test que
# da una alarma de seguridad falsa es peor que no tener test, porque entrena a ignorarlo.
#
# Se monta un repositorio git DE VERDAD (bare + clon) y se prueba el flujo real.
TA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TA_ROOT="$(cd "$TA_HERE/.." && pwd)"
TA_OK=0; TA_MAL=0
_ok()  { TA_OK=$((TA_OK+1));  echo "  OK   $1"; }
_mal() { TA_MAL=$((TA_MAL+1)); echo "  MAL  $1  ($2)"; }

TA_TMP="$(mktemp -d)"
trap 'rm -rf "$TA_TMP"' EXIT
GIT() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

echo "== el canal de actualizaciones =="

# --- el repositorio "publico" ------------------------------------------------------------------
TA_ORIGEN="$TA_TMP/origen.git"
TA_SIEMBRA="$TA_TMP/siembra"
GIT init --quiet --bare "$TA_ORIGEN"
GIT init --quiet "$TA_SIEMBRA" 2>/dev/null
mkdir -p "$TA_SIEMBRA/engine" "$TA_SIEMBRA/app"
cp "$TA_ROOT/mentis-actualizar.sh" "$TA_SIEMBRA/"
printf '0.1.0\n' > "$TA_SIEMBRA/VERSION"
printf 'codigo viejo\n' > "$TA_SIEMBRA/archivo-de-codigo.sh"
printf 'conversations/\nmemoria/\nmentis-settings.json\n' > "$TA_SIEMBRA/.gitignore"
( cd "$TA_SIEMBRA" && GIT add -A && GIT commit --quiet -m "version 0.1.0" \
  && GIT remote add origin "$TA_ORIGEN" && GIT push --quiet -u origin main ) 2>/dev/null

# --- la instalacion de la persona, que vino de git clone ---------------------------------------
TA_COPIA="$TA_TMP/mentis"
GIT clone --quiet "$TA_ORIGEN" "$TA_COPIA" 2>/dev/null
mkdir -p "$TA_COPIA/conversations" "$TA_COPIA/memoria"
printf 'mi conversacion privada\n' > "$TA_COPIA/conversations/charla.jsonl"
printf 'mi memoria\n'              > "$TA_COPIA/memoria/recuerdo.md"
printf '{"apariencia":{"nombre":"Nina"}}' > "$TA_COPIA/mentis-settings.json"

_correr() { ( cd "$TA_COPIA" && GIT config pull.ff only >/dev/null 2>&1; bash./mentis-actualizar.sh "$@" 2>&1 ); }

# --- el administrador publica la 0.2.0 ---------------------------------------------------------
_publicar() {  # $1 = que cambia ("codigo" | "app")
  ( cd "$TA_SIEMBRA"
    printf '0.2.0\n' > VERSION
    if [ "$1" = "app" ]; then printf 'ventana nueva\n' > app/main.js
    else printf 'codigo NUEVO\n' > archivo-de-codigo.sh; fi
    GIT add -A && GIT commit --quiet -m "version 0.2.0" && GIT push --quiet origin main ) 2>/dev/null
}
_publicar codigo

echo "-- 1. avisa que hay algo nuevo, sin instalarlo"
TA_SAL="$(_correr buscar)"
if printf '%s' "$TA_SAL" | grep -q "version 0.2.0"; then
  _ok "'buscar' lista el cambio nuevo"
else
  _mal "no detecto la actualizacion" "$(printf '%s' "$TA_SAL" | tail -2 | tr '\n' ' ')"
fi
if [ "$(tr -d ' \r\n' < "$TA_COPIA/VERSION")" = "0.1.0" ]; then
  _ok "'buscar' no instala nada"
else
  _mal "'buscar' instalo" "buscar tiene que mirar, no tocar"
fi

echo "-- 2. NO instala sin que la persona diga que si"
TA_SAL="$(printf 'n\n' | _correr instalar)"
if [ "$(tr -d ' \r\n' < "$TA_COPIA/VERSION")" = "0.1.0" ]; then
  _ok "contestando que no, no instala nada"
else
  _mal "instalo sin permiso" "la version cambio contestando que no"
fi

echo "-- 3. EL FRENO: no pisa trabajo de la persona"
printf 'lo estuve tocando yo\n' >> "$TA_COPIA/archivo-de-codigo.sh"
TA_SAL="$(printf 's\n' | _correr instalar)"
if printf '%s' "$TA_SAL" | grep -q "PARO:"; then
  _ok "se planta si hay archivos de Mentis modificados"
else
  _mal "no freno con archivos modificados" "pisaria el trabajo de la persona"
fi
if grep -q "lo estuve tocando yo" "$TA_COPIA/archivo-de-codigo.sh"; then
  _ok "el archivo modificado sigue intacto"
else
  _mal "piso un archivo modificado por la persona" "perdio su trabajo sin avisar"
fi
( cd "$TA_COPIA" && GIT checkout --quiet --. ) 2>/dev/null

echo "-- 4. instala cuando esta todo limpio y se dice que si"
TA_SAL="$(printf 's\n' | _correr instalar)"
if [ "$(tr -d ' \r\n' < "$TA_COPIA/VERSION")" = "0.2.0" ]; then
  _ok "la version quedo actualizada"
else
  _mal "no instalo" "$(printf '%s' "$TA_SAL" | tail -2 | tr '\n' ' ')"
fi
if grep -q "codigo NUEVO" "$TA_COPIA/archivo-de-codigo.sh"; then
  _ok "el codigo quedo actualizado"
else
  _mal "el codigo no se actualizo" "sigue el viejo"
fi

echo "-- 5. los datos de la persona no se tocan NUNCA"
grep -q "mi conversacion privada" "$TA_COPIA/conversations/charla.jsonl" \
  && _ok "las conversaciones siguen intactas" || _mal "toco las conversaciones" "dato personal perdido"
grep -q "mi memoria" "$TA_COPIA/memoria/recuerdo.md" \
  && _ok "la memoria sigue intacta" || _mal "toco la memoria" "dato personal perdido"
grep -q "Nina" "$TA_COPIA/mentis-settings.json" \
  && _ok "la configuracion sigue intacta" || _mal "toco la configuracion" "se perdio la personalizacion"

echo "-- 6. deja como volver atras"
if ls "$TA_COPIA"/.respaldos-actualizacion/*.punto >/dev/null 2>&1; then
  _ok "guardo el punto de retorno antes de tocar nada"
else
  _mal "no guardo punto de retorno" "sin esto 'volver' no puede funcionar"
fi

echo "-- 7. avisa cuando hay que rearmar la ventana"
# La app empaquetada NO se actualiza sola: si cambio app/ y no se avisa, la persona queda con el
#.exe viejo creyendo que actualizo. Es un problema real y repetido de este proyecto.
_publicar app
TA_SAL="$(printf 's\n' | _correr instalar)"
if printf '%s' "$TA_SAL" | grep -q "npm run empaquetar"; then
  _ok "avisa que hay que re-empaquetar cuando cambia app/"
else
  _mal "no aviso de re-empaquetar" "queda con la ventana vieja sin saberlo"
fi

echo
echo "== $TA_OK OK, $TA_MAL MAL =="
[ "$TA_MAL" -eq 0 ]
