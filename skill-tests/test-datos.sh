#!/usr/bin/env bash
# test-datos.sh -- tool 'datos' de nv-agent.sh (fuentes externas reales sin key). Se llama al
# script standalone DIRECTO para cada fuente (deterministico, sin depender de que el modelo
# elija bien la accion) y ADEMAS un caso end-to-end real vía nv-agent.sh para confirmar el wiring
# completo (clasificacion de la accion por el modelo + dispatcher + resultado final).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "datos (fuentes externas reales, sin key)"

_sk_case "overpass directo: cafes reales en Plaza de Mayo" \
  bash "$MENTIS_ENV_DIR/mentis-datos.sh" overpass '[out:json];node["amenity"="cafe"](around:500,-34.60,-58.38);out 10;'

_sk_case "nominatim directo: geocoding real (reemplazo de Mapbox)" \
  bash "$MENTIS_ENV_DIR/mentis-datos.sh" nominatim "Obelisco, Buenos Aires"

_sk_case "wikipedia directo: resumen real de un termino" \
  bash "$MENTIS_ENV_DIR/mentis-datos.sh" wikipedia "Python (lenguaje de programación)"

_sk_case "nasa directo: foto astronomica del dia" \
  bash "$MENTIS_ENV_DIR/mentis-datos.sh" nasa apod

_sk_case "end-to-end vía nv-agent.sh: el modelo elige la accion correcta" \
  bash "$TOOLSDIR/nv-agent.sh" -D -d "$ROOT" -m general -i 6 \
  "Buscá en OpenStreetMap si hay farmacias reales cerca de Plaza de Mayo, Buenos Aires (usá la tool datos, accion overpass)."
