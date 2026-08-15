#!/usr/bin/env bash
# mentis-datos.sh -- helper real sobre APIs de datos externos (mapas/geoespacial, rastreo en
# vivo, ciencia/conocimiento abierto). Solo lo llama nv-agent.sh (tool "datos", opt-in con -D,
# ver ALLOW_DATOS) -- mismo patron que mentis-arduino.sh: un subcomando por accion, imprime
# resultado legible a stdout, codigo de salida indica exito/fallo.
#
# Fuentes SIN api key (funcionan de entrada):
#   mentis-datos.sh overpass "<query Overpass QL>"
#   mentis-datos.sh georef <endpoint> <nombre>       # endpoint: provincias|departamentos|municipios|localidades|calles
#   mentis-datos.sh opensky <lamin> <lomin> <lamax> <lomax>
#   mentis-datos.sh nasa apod [fecha YYYY-MM-DD]
#   mentis-datos.sh archive <query>
#   mentis-datos.sh doaj <query>
#   mentis-datos.sh papers <tema>                    # OpenAlex: 250M de trabajos con citas y DOI
#   mentis-datos.sh wikipedia <termino>
#   mentis-datos.sh overture <lonmin,latmin,lonmax,latmax> <tipo>   # tipo ej: building, place, segment
#   mentis-datos.sh nominatim <direccion>   # geocoding mundial (OSM), reemplaza a Mapbox -- sin api key
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$HERE/.custom-models-secrets.env"
# Fix real (2026-07-15): en Windows, python3 (shim -> py -3) NO usa UTF-8 en stdout por
# default cuando la salida esta redirigida/pipeada (usa el codepage de la consola, ej.
# cp1252/cp850) -- cualquier tilde/ñ en el JSON de estas APIs (nombres en español) se escribia
# como bytes invalidos, no solo "se veia mal" en la terminal. Forzarlo acá cubre TODAS las
# invocaciones de python3 de este script de una sola vez.
export PYTHONIOENCODING=utf-8

_die() { echo "ERROR: $1" >&2; exit 1; }

_secret() {
  local key="$1"
  [ -f "$SECRETS" ] || return 0
  grep "^${key}=" "$SECRETS" | head -1 | sed "s/^${key}=//"
}

# urlencode simple via python3 (evita romper URLs con espacios/acentos/simbolos del usuario)
_urlenc() {
  NV_TXT="$1" python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["NV_TXT"]))'
}

# User-Agent real (hallazgo real 2026-07-15: Overpass devuelve 406 Not Acceptable sin esto --
# varias APIs publicas bloquean el User-Agent default de curl como mitigacion basica de bots).
UA="Mentis/1.0 (asistente personal de escritorio; contacto: uso personal no comercial)"

cmd="${1:-}"; shift || true

case "$cmd" in

  # --- OSM Overpass: consultas geoespaciales crudas, sin API key ---
  overpass)
    QUERY="$*"
    [ -n "${QUERY// }" ] || _die "falta la query Overpass QL. Uso: overpass \"<query>\""
    RESP="$(curl -s -H "User-Agent: $UA" -m 30 --data-urlencode "data=$QUERY" https://overpass-api.de/api/interpreter)"
    [ -n "${RESP// }" ] || _die "sin respuesta de Overpass (revisar sintaxis de la query o intentar de nuevo)."
    NV_JSON="$RESP" python3 -c '
import json, os
try:
    data = json.loads(os.environ["NV_JSON"])
except Exception as e:
    print("ERROR: Overpass no devolvio JSON valido -- " + str(e)[:200])
    raise SystemExit(0)
els = data.get("elements", [])
print(f"{len(els)} elemento(s) encontrado(s).")
for el in els[:20]:
    tags = el.get("tags", {})
    nombre = tags.get("name", "(sin nombre)")
    tipo = el.get("type", "?")
    lat = el.get("lat", el.get("center", {}).get("lat", "?"))
    lon = el.get("lon", el.get("center", {}).get("lon", "?"))
    resumen_tags = ", ".join(f"{k}={v}" for k, v in list(tags.items())[:5])
    print(f"- [{tipo}] {nombre} ({lat},{lon}) -- {resumen_tags}")
if len(els) > 20:
    print(f"... y {len(els)-20} mas (no mostrados).")
'
    ;;

  # --- Georef Argentina: normalizacion oficial de direcciones/localidades, sin API key ---
  georef)
    ENDPOINT="${1:-}"; NOMBRE="${2:-}"
    [ -n "$ENDPOINT" ] || _die "falta el endpoint. Uso: georef <provincias|departamentos|municipios|localidades|calles> <nombre>"
    case "$ENDPOINT" in
      provincias|departamentos|municipios|localidades|calles) : ;;
      *) _die "endpoint invalido: '$ENDPOINT' (usar provincias|departamentos|municipios|localidades|calles)" ;;
    esac
    URL="https://apis.datos.gob.ar/georef/api/${ENDPOINT}"
    if [ -n "$NOMBRE" ]; then
      URL="${URL}?nombre=$(_urlenc "$NOMBRE")&max=15"
    else
      URL="${URL}?max=15"
    fi
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 "$URL")"
    [ -n "${RESP// }" ] || _die "sin respuesta de Georef."
    NV_JSON="$RESP" NV_ENDPOINT="$ENDPOINT" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
endpoint = os.environ["NV_ENDPOINT"]
items = data.get(endpoint, [])
print(f"{len(items)} resultado(s).")
for it in items:
    nombre = it.get("nombre", "?")
    prov = (it.get("provincia") or {}).get("nombre", "")
    extra = f" ({prov})" if prov else ""
    ident = it.get("id", "?")
    print(f"- {nombre}{extra} -- id {ident}")
'
    ;;

  # --- OpenSky Network: vuelos en vivo dentro de un bounding box, sin API key (limite anonimo
  # 400 consultas/dia, resolucion 10s, solo el estado mas reciente) ---
  opensky)
    LAMIN="${1:-}"; LOMIN="${2:-}"; LAMAX="${3:-}"; LOMAX="${4:-}"
    [ -n "$LOMAX" ] || _die "faltan coordenadas. Uso: opensky <lamin> <lomin> <lamax> <lomax>"
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 "https://opensky-network.org/api/states/all?lamin=${LAMIN}&lomin=${LOMIN}&lamax=${LAMAX}&lomax=${LOMAX}")"
    [ -n "${RESP// }" ] || _die "sin respuesta de OpenSky (¿se agoto el limite anonimo de 400 consultas/dia?)."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
states = data.get("states") or []
print(f"{len(states)} aeronave(s) en el area en este momento.")
for s in states[:25]:
    icao24, callsign, pais = s[0], (s[1] or "").strip(), s[2]
    lon, lat, alt, vel = s[5], s[6], s[7], s[9]
    alt_txt = f"{alt}m" if alt is not None else "?"
    vel_txt = f"{vel}m/s" if vel is not None else "?"
    print(f"- {callsign or icao24} ({pais}) -- lat={lat} lon={lon} altitud={alt_txt} vel={vel_txt}")
if len(states) > 25:
    print(f"... y {len(states)-25} mas (no mostradas).")
'
    ;;

  # --- NASA Open Data: foto astronomica del dia. DEMO_KEY funciona de entrada (limite bajo);
  # si el usuario carga una key real en.custom-models-secrets.env (NASA_API_KEY) se usa esa ---
  nasa)
    SUB="${1:-apod}"; FECHA="${2:-}"
    NASA_KEY="$(_secret NASA_API_KEY)"; [ -n "$NASA_KEY" ] || NASA_KEY="DEMO_KEY"
    case "$SUB" in
      apod)
        URL="https://api.nasa.gov/planetary/apod?api_key=${NASA_KEY}"
        [ -n "$FECHA" ] && URL="${URL}&date=${FECHA}"
        RESP="$(curl -s -H "User-Agent: $UA" -m 20 "$URL")"
        [ -n "${RESP// }" ] || _die "sin respuesta de NASA APOD."
        NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
if "error" in data:
    print("ERROR: " + str(data["error"].get("message", data["error"])))
    raise SystemExit(0)
titulo = data.get("title", "?")
fecha = data.get("date", "?")
print(f"{titulo} ({fecha})")
print(data.get("url", "(sin imagen)"))
print()
print(data.get("explanation", "")[:1500])
'
        ;;
      *) _die "subcomando de nasa desconocido: '$SUB' (usar apod)" ;;
    esac
    ;;

  # --- Internet Archive: busqueda en la biblioteca digital mas grande de internet ---
  archive)
    QUERY="$*"
    [ -n "${QUERY// }" ] || _die "falta la busqueda. Uso: archive <query>"
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 "https://archive.org/advancedsearch.php?q=$(_urlenc "$QUERY")&fl[]=identifier&fl[]=title&fl[]=description&fl[]=mediatype&rows=10&output=json")"
    [ -n "${RESP// }" ] || _die "sin respuesta de Internet Archive."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
docs = (data.get("response") or {}).get("docs", [])
num_found = (data.get("response") or {}).get("numFound", len(docs))
print(f"{num_found} resultado(s) (mostrando hasta 10).")
for d in docs:
    media = d.get("mediatype", "?")
    titulo = d.get("title", "?")
    ident = d.get("identifier", "?")
    print(f"- [{media}] {titulo} -- archive.org/details/{ident}")
'
    ;;

  # --- DOAJ: articulos academicos de acceso abierto ---
  doaj)
    QUERY="$*"
    [ -n "${QUERY// }" ] || _die "falta la busqueda. Uso: doaj <query>"
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 "https://doaj.org/api/search/articles/$(_urlenc "$QUERY")?pageSize=10")"
    [ -n "${RESP// }" ] || _die "sin respuesta de DOAJ."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
results = data.get("results", [])
total = data.get("total", len(results))
print(f"{total} articulo(s) encontrado(s) (mostrando hasta 10).")
for r in results:
    bib = (r.get("bibjson") or {})
    titulo = bib.get("title", "?")
    autores = ", ".join(a.get("name","") for a in (bib.get("author") or [])[:3])
    link = next((l.get("url") for l in (bib.get("link") or []) if l.get("url")), "")
    print(f"- {titulo} -- {autores} -- {link}")
'
    ;;

  # --- OpenAlex: papers con fuente, sin clave (2026-08-15) -------------------------------------
  # POR QUE, HABIENDO YA UN 'doaj': DOAJ indexa SOLO revistas de acceso abierto. OpenAlex tiene
  # 250 millones de trabajos -- abiertos y cerrados --, con año, cantidad de citas y DOI. Para los
  # modos Study y Science eso es la diferencia entre "encontré algo" y "encontré el paper que se
  # cita en todos lados". Los dos quedan: DOAJ para leer el texto completo gratis, OpenAlex para
  # saber qué existe y cuánto pesa.
  #
  # El User-Agent con un mail es lo que pide su documentación para el pool rápido; sin eso la API
  # responde igual pero por la cola lenta. No hay clave ni registro.
  papers)
    QUERY="$*"
    [ -n "${QUERY// }" ] || _die "falta la busqueda. Uso: papers <tema>"
    RESP="$(curl -s -H "User-Agent: Mentis/1.0 (https://github.com/usuario/Mentis)" -m 25 \
      "https://api.openalex.org/works?search=$(_urlenc "$QUERY")&per-page=8&sort=cited_by_count:desc")"
    [ -n "${RESP// }" ] || _die "sin respuesta de OpenAlex."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
total = (data.get("meta") or {}).get("count", 0)
res = data.get("results") or []
print(f"{total} trabajo(s) encontrado(s) (mostrando {len(res)}, los mas citados primero).")
for w in res:
    titulo = (w.get("title") or "sin titulo")[:130]
    anio = w.get("publication_year") or "?"
    citas = w.get("cited_by_count", 0)
    autores = ", ".join(
        ((a.get("author") or {}).get("display_name") or "") for a in (w.get("authorships") or [])[:3]
    )
    doi = w.get("doi") or ""
    # open_access.oa_url es el PDF gratis cuando existe; sin eso, el DOI es lo unico accionable.
    oa = ((w.get("open_access") or {}).get("oa_url") or "")
    link = oa or doi
    abierto = "ACCESO ABIERTO" if oa else "sin PDF gratis"
    print(f"- {titulo} ({anio}) -- {citas} citas -- {abierto}")
    if autores:
        print(f"    {autores}")
    if link:
        print(f"    {link}")
'
    ;;

  # --- Wikipedia/Wikimedia: resumen de un termino (API REST oficial, sin key) ---
  wikipedia)
    TERMINO="$*"
    [ -n "${TERMINO// }" ] || _die "falta el termino. Uso: wikipedia <termino>"
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 -L "https://es.wikipedia.org/api/rest_v1/page/summary/$(_urlenc "$TERMINO")")"
    [ -n "${RESP// }" ] || _die "sin respuesta de Wikipedia."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
if data.get("type") == "https://mediawiki.org/wiki/HyperSwitch/errors/not_found":
    print("No se encontro un articulo exacto con ese termino en Wikipedia en español.")
    raise SystemExit(0)
print(data.get("title", "?"))
print(data.get("description", ""))
print()
print(data.get("extract", "(sin resumen)"))
print()
print((data.get("content_urls") or {}).get("desktop", {}).get("page", ""))
'
    ;;

  # --- Overture Maps: descarga real por bounding box via el CLI oficial (pip install overturemaps) ---
  overture)
    BBOX="${1:-}"; TIPO="${2:-}"
    [ -n "$TIPO" ] || _die "faltan datos. Uso: overture <lonmin,latmin,lonmax,latmax> <tipo> (tipo ej: building, place, segment, land_use)"
    OVERTURE_CLI="overturemaps"
    if ! command -v "$OVERTURE_CLI" >/dev/null 2>&1; then
      # $USER no esta seteado de forma confiable en Git Bash en Windows -- $HOME si (ERR real
      # encontrado 2026-07-15 probando esto: "set -u" + $USER sin setear aborta el script).
      WIN_CLI="$HOME/AppData/Roaming/Python/Python314/Scripts/overturemaps.exe"
      [ -x "$WIN_CLI" ] && OVERTURE_CLI="$WIN_CLI"
    fi
    command -v "$OVERTURE_CLI" >/dev/null 2>&1 || [ -x "$OVERTURE_CLI" ] || _die "overturemaps no encontrado (instalar con: python3 -m pip install --user overturemaps)."
    OUT="$(mktemp -u --suffix=.geojson)"
    "$OVERTURE_CLI" download --bbox="$BBOX" -f geojson --type="$TIPO" -o "$OUT" 2>&1 | tail -3
    [ -f "$OUT" ] || _die "la descarga de Overture no genero salida."
    NV_FILE="$OUT" python3 -c '
import json, os

def centroide(geom):
    def aplanar(c):
        if not c:
            return []
        if isinstance(c[0], (int, float)):
            return [c]
        pts = []
        for sub in c:
            pts.extend(aplanar(sub))
        return pts
    pts = aplanar(geom.get("coordinates")) if geom else []
    if not pts:
        return None
    lon = sum(p[0] for p in pts) / len(pts)
    lat = sum(p[1] for p in pts) / len(pts)
    return round(lon, 5), round(lat, 5)

with open(os.environ["NV_FILE"], "r", encoding="utf-8") as f:
    data = json.load(f)
feats = data.get("features", [])
print(f"{len(feats)} elemento(s) encontrados en el area.")
nombrados = [feat for feat in feats if ((feat.get("properties") or {}).get("names") or {}).get("primary")]
print(f"{len(nombrados)} tienen nombre (mostrando hasta 20):")
for feat in nombrados[:20]:
    props = feat.get("properties", {})
    nombre = (props.get("names") or {}).get("primary")
    cat = ((props.get("categories") or {}).get("primary")) or ""
    c = centroide(feat.get("geometry") or {})
    ubic = f"lat={c[1]} lon={c[0]}" if c else "?"
    print(f"- {nombre}" + (f" [{cat}]" if cat else "") + f" -- {ubic}")
if len(nombrados) > 20:
    print(f"... y {len(nombrados)-20} con nombre mas (no mostrados).")
'
    rm -f "$OUT" "${OUT}.state" 2>/dev/null
    ;;

  # --- Nominatim (OSM): geocoding mundial, sin api key -- reemplaza a Mapbox (2026-07-16,
  # Mapbox dejo de ser gratuito). Mismo User-Agent real que el resto del script (Nominatim
  # tambien exige uno propio, ver politica de uso en operations.osmfoundation.org/policies/nominatim). ---
  nominatim)
    DIRECCION="$*"
    [ -n "${DIRECCION// }" ] || _die "falta la direccion. Uso: nominatim <direccion>"
    RESP="$(curl -s -H "User-Agent: $UA" -m 20 "https://nominatim.openstreetmap.org/search?q=$(_urlenc "$DIRECCION")&format=jsonv2&limit=5")"
    [ -n "${RESP// }" ] || _die "sin respuesta de Nominatim."
    NV_JSON="$RESP" python3 -c '
import json, os
data = json.loads(os.environ["NV_JSON"])
print(f"{len(data)} resultado(s).")
for f in data:
    lat = f.get("lat", "?")
    lon = f.get("lon", "?")
    nombre = f.get("display_name", "?")
    print(f"- {nombre} -- lat={lat} lon={lon}")
'
    ;;

  *)
    _die "subcomando desconocido: '$cmd'. Usar overpass|georef|opensky|nasa|archive|doaj|wikipedia|overture|nominatim."
    ;;
esac
