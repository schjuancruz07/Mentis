#!/usr/bin/env bash
# mentis-location.sh -- ubicacion REAL del usuario (pedido 2026-07-25: "que sepa donde estoy en el
# saludo y en cualquier momento").
#
# Antes: la ubicacion estaba HARDCODEADA en Villa Lugano (main.js, 2026-07-16) porque el geo-IP
# que habia antes ubicaba mal (daba Lanus, ~10 km de error: el geo-IP resuelve la central del
# ISP, no la casa). Una constante en el codigo no es "saber donde estoy" -- si el usuario se muda o
# viaja, miente sin avisar.
#
# Ahora: dos fuentes reales, ninguna con API key ni costo.
#   1. COORDENADAS -- API nativa de Windows (Windows.Devices.Geolocation via WinRT). Triangula
#      por WiFi contra el servicio de Microsoft. Medido en esta maquina: 151 m de precision,
#      fuente WiFi. Requiere el servicio lfsvc corriendo y el permiso de ubicacion en Allow
#      (ambos ya verificados aca).
#   2. DIRECCION -- Nominatim (OpenStreetMap): coords -> calle, barrio, ciudad. Gratis, sin key.
#      Su politica de uso exige User-Agent identificatorio y como maximo 1 request por segundo;
#      por eso el cache de abajo no es solo una optimizacion, es cumplir la regla.
#
# Se eligio esta via sobre Google Maps (que el usuario menciono) porque da el mismo resultado sin
# tarjeta de credito ni key que rotar. El enganche para Google queda documentado al final.
#
# Uso:
#   mentis-location.sh              -> JSON con lat/lon/precision/direccion
#   mentis-location.sh --texto      -> una linea en castellano, lista para hablar o leer
#   mentis-location.sh --coords     -> solo "lat lon" (para encadenar con otros scripts)
#   mentis-location.sh --refrescar  -> ignora el cache y vuelve a medir
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE="${MENTIS_LOCATION_CACHE:-$HERE/location-cache.json}"
# 15 min: suficiente para no repetir la consulta en cada turno del chat, corto para que si el usuario
# se mueve de verdad la proxima respuesta ya lo refleje.
CACHE_MAX_SEG="${MENTIS_LOCATION_CACHE_SEG:-900}"
NOMINATIM_UA="Mentis/1.0 (asistente personal local; contacto: usuario@ejemplo.com)"

MODO="${1:-}"
[ "$MODO" = "--refrescar" ] && rm -f "$CACHE_FILE" 2>/dev/null

# ---------- cache ----------
_cache_vigente() {
  [ -f "$CACHE_FILE" ] || return 1
  CACHE_FILE_W="$CACHE_FILE" CACHE_MAX_SEG="$CACHE_MAX_SEG" python3 -c '
import json, os, sys, time
try:
    with open(os.environ["CACHE_FILE_W"], encoding="utf-8") as f:
        d = json.load(f)
    edad = time.time() - float(d.get("medido_en", 0))
    sys.exit(0 if edad < float(os.environ["CACHE_MAX_SEG"]) else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# ---------- 1. coordenadas via API nativa de Windows ----------
# El await de WinRT desde PowerShell 5.1 necesita este rodeo con reflection (AsTask): las
# operaciones asincronicas de WinRT no se pueden esperar directo desde PS. Sin esto, $op.Status
# vuelve vacio y parece que la API no anda (me paso en la primera prueba).
_coords_windows() {
  # La ruta se pasa traducida a formato Windows: powershell.exe es un binario nativo y no
  # entiende /c/Users/... (ERR-004/ERR-006, la misma trampa de siempre en este entorno).
  local ps1; ps1="$(cygpath -w "$HERE/mentis-location.ps1" 2>/dev/null || printf '%s' "$HERE/mentis-location.ps1")"
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" 2>/dev/null \
    | tr -d '\r' | grep -E '^(OK\||ERROR:)' | head -1
}

# ---------- 2. direccion legible via Nominatim (OpenStreetMap) ----------
_direccion_osm() {
  local lat="$1" lon="$2"
  curl -s -m 12 -A "$NOMINATIM_UA" \
    "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon&zoom=16&accept-language=es" 2>/dev/null
}

# ---------- flujo principal ----------
if _cache_vigente && [ "$MODO" != "--refrescar" ]; then
  DATOS="$(cat "$CACHE_FILE")"
else
  CRUDO="$(_coords_windows)"
  if [ -z "$CRUDO" ] || [[ "$CRUDO" == ERROR:* ]]; then
    # Degradado honesto: si hay un cache viejo se usa avisando que es viejo; si no, se dice que
    # no se pudo. NUNCA se inventa una ubicacion ni se vuelve a una constante hardcodeada --
    # ese era justamente el problema que este script viene a resolver.
    MOTIVO="${CRUDO#ERROR:}"; [ -z "$MOTIVO" ] && MOTIVO="la API de ubicacion de Windows no respondio"
    if [ -f "$CACHE_FILE" ]; then
      DATOS="$(CACHE_FILE_W="$CACHE_FILE" MOTIVO="$MOTIVO" python3 -c '
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8", newline="")
d = json.load(open(os.environ["CACHE_FILE_W"], encoding="utf-8"))
d["vigente"] = False
d["aviso"] = "dato viejo del cache: " + os.environ["MOTIVO"]
print(json.dumps(d, ensure_ascii=True))
')"
    else
      printf '{"ok":false,"error":%s}\n' "$(MOTIVO="$MOTIVO" python3 -c 'import json,os;print(json.dumps(os.environ["MOTIVO"]))')"
      [ "$MODO" = "--texto" ] && echo "No pude determinar la ubicacion ($MOTIVO)." >&2
      exit 1
    fi
  else
    IFS='|' read -r _ LAT LON PREC FUENTE <<< "$CRUDO"
    OSM="$(_direccion_osm "$LAT" "$LON")"
    DATOS="$(LAT="$LAT" LON="$LON" PREC="$PREC" FUENTE="$FUENTE" OSM="$OSM" python3 -c '
import json, os, sys, time
# Bug real encontrado al probarlo (2026-07-25): sin esto, python en Windows escribe el JSON en
# cp1252 y la "n con tilde" de "Albarino" (la calle real del usuario) sale como el byte 0xf1 suelto
# -- json.load(encoding="utf-8") del lado que lo lee explota y la ubicacion queda "(no
# disponible)". Doble cinturon: stdout en utf-8 Y ensure_ascii=True, asi el archivo queda ASCII
# puro y no depende del encoding de nadie.
sys.stdout.reconfigure(encoding="utf-8", newline="")
osm = {}
try:
    osm = json.loads(os.environ.get("OSM") or "{}")
except Exception:
    osm = {}
a = osm.get("address", {}) or {}
# Nominatim usa nombres de campo distintos segun el pais; para Buenos Aires el barrio puede
# venir como suburb, neighbourhood o city_district.
barrio = a.get("suburb") or a.get("neighbourhood") or a.get("city_district") or ""
ciudad = a.get("city") or a.get("town") or a.get("village") or a.get("state") or ""
calle = a.get("road") or ""
altura = a.get("house_number") or ""
d = {
    "ok": True,
    "vigente": True,
    "lat": float(os.environ["LAT"]),
    "lon": float(os.environ["LON"]),
    "precision_m": float(os.environ["PREC"]),
    "fuente": os.environ["FUENTE"],
    "calle": calle,
    "altura": altura,
    "barrio": barrio,
    "ciudad": ciudad,
    "direccion": (osm.get("display_name") or ""),
    "medido_en": time.time(),
}
print(json.dumps(d, ensure_ascii=True))
')"
    printf '%s\n' "$DATOS" > "$CACHE_FILE" 2>/dev/null
  fi
fi

case "$MODO" in
  --coords)
    printf '%s' "$DATOS" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("lat"), d.get("lon"))' ;;
  --texto)
    printf '%s' "$DATOS" | python3 -c '
import json, sys
sys.stdout.reconfigure(encoding="utf-8")
d = json.load(sys.stdin)
if not d.get("ok"):
    print("No pude determinar donde estas."); raise SystemExit(0)
lugar = d.get("barrio") or d.get("ciudad") or "una ubicacion desconocida"
partes = []
if d.get("calle"):
    partes.append(d["calle"] + ((" " + d["altura"]) if d.get("altura") else ""))
partes.append(lugar)
if d.get("ciudad") and d.get("ciudad") != lugar:
    partes.append(d["ciudad"])
txt = ", ".join([p for p in partes if p])
prec = d.get("precision_m")
# La precision se dice de verdad: 151 m no es "estas parado aca", y ocultarlo seria fingir
# una exactitud que el WiFi no da.
sufijo = (" (precision aproximada de %d metros)" % round(prec)) if prec else ""
if not d.get("vigente"):
    sufijo += " [dato del ultimo registro, no pude medir ahora]"
print(txt + sufijo)
' ;;
  *)
    printf '%s\n' "$DATOS" ;;
esac

# ---------- si algun dia se quiere Google Maps ----------
# Las coordenadas seguirian saliendo de Windows (Google cobra por su Geolocation API y da lo
# mismo). Lo unico que cambiaria es _direccion_osm por:
#   curl "https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lon&language=es&key=$GOOGLE_MAPS_KEY"
# La key iria en mcp-bridge/.secrets.env como GOOGLE_MAPS_KEY, nunca en este archivo.
