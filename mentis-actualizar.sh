#!/usr/bin/env bash
# mentis-actualizar.sh -- traer las mejoras que publica el administrador. Corre en TODAS las copias.
#
# ESTE ARCHIVO EJECUTA CODIGO QUE VIENE DE OTRA COMPUTADORA. Es la parte mas delicada de Mentis, y
# todo lo que sigue existe para que eso sea seguro:
#
#   1. NADA se instala sin firma valida. Si la firma no verifica -- por lo que sea -- no se instala.
#      Un "no se" significa "no". Es lo unico que impide que alguien que se meta en el medio del
#      canal ejecute lo que quiera en la maquina de cinco personas.
#   2. Se pregunta ANTES. Nunca se actualiza solo. Quien usa esta computadora decide.
#   3. Se respalda antes de tocar nada, y `volver` deshace.
#   4. Si la persona modifico un archivo de Mentis, se FRENA y se avisa. No se pisa el trabajo de
#      nadie en silencio.
#   5. Los datos NO se tocan nunca: conversaciones, memorias, claves y configuracion se quedan
#      como estan. Se actualiza el codigo, no la vida de la persona.
set -uo pipefail
MA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MA_HERE/engine/nv-firma-lib.sh" 2>/dev/null || { echo "ERROR: falta engine/nv-firma-lib.sh" >&2; exit 1; }

MA_PUB="$MA_HERE/mentis-firma-publica.pem"
MA_VERSION_ARCH="$MA_HERE/VERSION"
MA_CACHE="${MENTIS_ACTUALIZAR_CACHE:-$MA_HERE/.actualizaciones-cache}"
MA_RESPALDOS="${MENTIS_RESPALDOS_DIR:-$MA_HERE/.respaldos-actualizacion}"
MA_HUELLAS="$MA_HERE/.archivos-instalados.sha256"
# De donde se bajan. Se configura una vez; sale de mentis-settings.json o de la variable.
MA_ORIGEN="${MENTIS_ORIGEN_ACTUALIZACIONES:-}"

# Lo que NUNCA se pisa, pase lo que pase. Aunque el paquete lo traiga.
MA_INTOCABLE=(
  "mentis-settings.json" "modelos-override.json" ".custom-models-secrets.env"
  "conversations" "memoria" "engine/logs" "engine/index" "engine/recall-corpus"
  "engine/sombras" "engine/.web-token" "engine/.nv-secrets" "workspace" "avatar"
  "scheduled-runs" "knowledge" ".firma"
)

_ma_uso() {
  cat <<'FIN'
Uso:
  mentis-actualizar.sh revisar     ¿hay algo nuevo? (no toca nada)
  mentis-actualizar.sh instalar    lo instala, despues de preguntar
  mentis-actualizar.sh volver      deshace la ultima actualizacion
  mentis-actualizar.sh origen <url-del-repo>   configura de donde bajarlas
FIN
}

_ma_version() { tr -d ' \r\n' < "$MA_VERSION_ARCH" 2>/dev/null || printf '0.0.0'; }

_ma_mayor_que() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

_ma_origen() {
  [ -n "$MA_ORIGEN" ] && { printf '%s' "$MA_ORIGEN"; return 0; }
  python3 -c '
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as f:
        print(((json.load(f).get("actualizaciones") or {}).get("origen") or "").strip())
except Exception:
    pass
' "$(nv_winpath "$MA_HERE/mentis-settings.json" 2>/dev/null || printf '%s' "$MA_HERE/mentis-settings.json")" 2>/dev/null | tr -d ' \r\n'
}

# --- traer el manifiesto -----------------------------------------------------------------------
_ma_bajar() {
  local origen; origen="$(_ma_origen)"
  if [ -z "$origen" ]; then
    echo "No esta configurado de donde bajar las actualizaciones." >&2
    echo "  Pedile la direccion a quien te instalo Mentis y corre:" >&2
    echo "  mentis-actualizar.sh origen <url>" >&2
    return 2
  fi
  # Un origen local (una carpeta) sirve para probar sin red y para quien reparta por pendrive.
  if [ -d "$origen" ]; then
    mkdir -p "$MA_CACHE" 2>/dev/null || true
    cp -f "$origen/manifiesto.json" "$MA_CACHE/" 2>/dev/null || return 1
    mkdir -p "$MA_CACHE/paquetes" 2>/dev/null || true
    cp -f "$origen"/paquetes/*.tar.gz "$MA_CACHE/paquetes/" 2>/dev/null || true
    return 0
  fi
  if [ -d "$MA_CACHE/.git" ]; then
    ( cd "$MA_CACHE" && git pull --quiet 2>/dev/null ) || { echo "No pude traer novedades (¿internet? ¿permisos del repo?)" >&2; return 1; }
  else
    rm -rf "$MA_CACHE" 2>/dev/null
    git clone --quiet --depth 1 "$origen" "$MA_CACHE" 2>/dev/null || {
      echo "No pude bajar del repo. Revisa la direccion y que tengas acceso." >&2; return 1; }
  fi
}

_ma_campo() {
  python3 -c '
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as f:
        print(json.load(f).get(sys.argv[2], "") or "")
except Exception:
    pass
' "$(nv_winpath "$MA_CACHE/manifiesto.json" 2>/dev/null || printf '%s' "$MA_CACHE/manifiesto.json")" "$1" 2>/dev/null
}

# --- revisar -----------------------------------------------------------------------------------
_ma_revisar() {
  local mia; mia="$(_ma_version)"
  echo "Tu version: $mia"
  _ma_bajar || return 1
  [ -f "$MA_CACHE/manifiesto.json" ] || { echo "No hay ninguna actualizacion publicada."; return 0; }
  local nueva; nueva="$(_ma_campo version)"
  if [ -z "$nueva" ]; then echo "El manifiesto no dice que version es. No hago nada."; return 1; fi
  if ! _ma_mayor_que "$nueva" "$mia"; then
    echo "Estas al dia."
    return 0
  fi
  echo
  echo "== Hay una version nueva: $nueva =="
  echo "  publicada: $(_ma_campo fecha)"
  echo "  que cambia:"
  printf '    %s\n' "$(_ma_campo notas)"
  echo
  echo "Para instalarla:  mentis-actualizar.sh instalar"
  return 0
}

# --- huellas: para saber si la persona toco algun archivo --------------------------------------
_ma_guardar_huellas() {
  local lista="$1"
  ( cd "$MA_HERE" && while IFS= read -r f; do
      [ -f "$f" ] && printf '%s  %s\n' "$(openssl dgst -sha256 "$f" 2>/dev/null | sed -E 's/.*= *//')" "$f"
    done < "$lista" ) > "$MA_HUELLAS" 2>/dev/null
}

# Devuelve la lista de archivos que cambiaron desde la ultima instalacion.
_ma_modificados() {
  [ -f "$MA_HUELLAS" ] || return 0
  ( cd "$MA_HERE" && while read -r sha archivo; do
      [ -n "$archivo" ] || continue
      [ -f "$archivo" ] || continue
      local ahora; ahora="$(openssl dgst -sha256 "$archivo" 2>/dev/null | sed -E 's/.*= *//')"
      [ "$ahora" = "$sha" ] || printf '%s\n' "$archivo"
    done < "$MA_HUELLAS" )
}

# --- instalar ----------------------------------------------------------------------------------
_ma_instalar() {
  local mia; mia="$(_ma_version)"
  _ma_bajar || return 1
  [ -f "$MA_CACHE/manifiesto.json" ] || { echo "No hay nada publicado."; return 0; }

  local nueva firma sha arch
  nueva="$(_ma_campo version)"; firma="$(_ma_campo firma)"
  sha="$(_ma_campo sha256)";    arch="$(_ma_campo archivo)"
  if ! _ma_mayor_que "$nueva" "$mia"; then echo "Ya estas en la $mia. No hay nada que instalar."; return 0; fi

  local tgz="$MA_CACHE/$arch"
  [ -f "$tgz" ] || { echo "ERROR: el manifiesto habla de $arch pero el archivo no llego." >&2; return 1; }

  # --- LA VERIFICACION. Todo lo demas depende de esto. ---
  echo "-- verificando que la actualizacion sea legitima"
  if [ ! -f "$MA_PUB" ]; then
    echo "FRENO: no tengo la clave publica del administrador ($MA_PUB)." >&2
    echo "  Sin eso no puedo saber si esto lo publico quien dice. No instalo nada." >&2
    return 1
  fi
  local sha_real; sha_real="$(openssl dgst -sha256 "$tgz" 2>/dev/null | sed -E 's/.*= *//')"
  if [ -n "$sha" ] && [ "$sha_real" != "$sha" ]; then
    echo "FRENO: el paquete no coincide con lo que dice el manifiesto." >&2
    echo "  Puede ser una descarga cortada, o que alguien lo haya cambiado. No instalo." >&2
    return 1
  fi
  if ! nv_firma_verificar "$tgz" "$firma" "$MA_PUB"; then
    echo "FRENO: LA FIRMA NO ES VALIDA." >&2
    echo "  Esta actualizacion NO la publico quien tiene la clave de administrador." >&2
    echo "  No se instala nada. Avisale a quien te instalo Mentis." >&2
    return 1
  fi
  echo "   firma correcta (huella del administrador: $(nv_firma_huella "$MA_PUB"))"

  # --- ¿toco algo la persona? ---
  local modificados; modificados="$(_ma_modificados)"
  if [ -n "$modificados" ]; then
    echo
    echo "FRENO: estos archivos los modificaste vos desde la ultima actualizacion:"
    printf '   %s\n' $modificados | head -10
    echo
    echo "  Si sigo, pierdo esos cambios. No lo hago sin que lo sepas."
    echo "  Hablalo con quien te instalo Mentis, o guarda una copia de esos archivos y volve a intentar."
    return 2
  fi

  # --- pedir permiso. Nunca se actualiza sin que la persona diga que si. ---
  echo
  echo "== Actualizacion $mia -> $nueva =="
  echo "  que cambia: $(_ma_campo notas)"
  echo
  echo "  Tus conversaciones, memorias y claves NO se tocan."
  printf '  ¿La instalo? [s/N]: '
  local r=""; read -r r
  case "$r" in
    s|S|si|SI|Si|y|Y) ;;
    *) echo "No se instalo nada."; return 0 ;;
  esac

  # --- respaldo ---
  local sello; sello="$(date +%Y%m%d-%H%M%S)"
  local resp="$MA_RESPALDOS/$sello-v$mia"
  mkdir -p "$resp" 2>/dev/null || true
  echo "-- respaldando la version actual en $(basename "$resp")"
  local lista_nueva; lista_nueva="$(mktemp)"
  tar -tzf "$tgz" 2>/dev/null | grep -v '/$' | sed 's|^\./||' > "$lista_nueva"
  # Solo se respalda lo que el paquete va a pisar: copiar todo seria copiar tambien los datos.
  ( cd "$MA_HERE" && while IFS= read -r f; do
      [ -f "$f" ] || continue
      mkdir -p "$resp/$(dirname "$f")" 2>/dev/null
      cp -f "$f" "$resp/$f" 2>/dev/null
    done < "$lista_nueva" )
  printf '%s' "$mia" > "$resp/.version-anterior"

  # --- aplicar, salteando lo intocable ---
  echo "-- instalando"
  local tmp; tmp="$(mktemp -d)"
  tar -xzf "$tgz" -C "$tmp" 2>/dev/null || { echo "ERROR: el paquete no se pudo abrir" >&2; rm -rf "$tmp"; return 1; }
  local saltados=0
  while IFS= read -r f; do
    local salta=0
    for x in "${MA_INTOCABLE[@]}"; do
      case "$f" in "$x"|"$x"/*) salta=1; break ;; esac
    done
    if [ "$salta" = "1" ]; then saltados=$((saltados+1)); continue; fi
    [ -f "$tmp/$f" ] || continue
    mkdir -p "$MA_HERE/$(dirname "$f")" 2>/dev/null
    cp -f "$tmp/$f" "$MA_HERE/$f" 2>/dev/null
  done < "$lista_nueva"
  rm -rf "$tmp"

  _ma_guardar_huellas "$lista_nueva"
  rm -f "$lista_nueva"
  printf '%s\n' "$nueva" > "$MA_VERSION_ARCH"

  echo
  echo "Listo: ahora tenes la version $nueva."
  [ "$saltados" -gt 0 ] && echo "  ($saltados archivo(s) tuyos quedaron intactos, como corresponde)"
  echo
  echo "Si algo quedo raro:  mentis-actualizar.sh volver"
  echo "Si cambio la ventana de Mentis, cerrala y corre:  cd app && npm run empaquetar"
}

# --- volver ------------------------------------------------------------------------------------
_ma_volver() {
  local ultimo; ultimo="$(ls -1d "$MA_RESPALDOS"/*/ 2>/dev/null | sort | tail -1)"
  if [ -z "$ultimo" ]; then echo "No hay ningun respaldo para volver."; return 1; fi
  local antes; antes="$(cat "$ultimo/.version-anterior" 2>/dev/null || echo "?")"
  echo "Volviendo a la version $antes (respaldo: $(basename "$ultimo"))"
  ( cd "$ultimo" && find. -type f ! -name ".version-anterior" -print | sed 's|^\./||' | while IFS= read -r f; do
      mkdir -p "$MA_HERE/$(dirname "$f")" 2>/dev/null
      cp -f "$ultimo/$f" "$MA_HERE/$f" 2>/dev/null
    done )
  [ "$antes" != "?" ] && printf '%s\n' "$antes" > "$MA_VERSION_ARCH"
  echo "Listo: volviste a la $antes."
}

# --- origen ------------------------------------------------------------------------------------
_ma_origen_set() {
  local url="${1:?falta la direccion}"
  MAO_URL="$url" python3 -c '
import json, io, os, sys
ruta = sys.argv[1]
try:
    with io.open(ruta, encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
d.setdefault("actualizaciones", {})["origen"] = os.environ["MAO_URL"]
tmp = ruta + ".tmp"
with io.open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, ruta)
' "$(nv_winpath "$MA_HERE/mentis-settings.json" 2>/dev/null || printf '%s' "$MA_HERE/mentis-settings.json")" \
    && echo "Origen guardado. Proba:  mentis-actualizar.sh revisar"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    revisar)  _ma_revisar ;;
    instalar) _ma_instalar ;;
    volver)   _ma_volver ;;
    origen)   _ma_origen_set "${2:-}" ;;
    *) _ma_uso; exit 2 ;;
  esac
fi
