#!/usr/bin/env bash
# Piezas para FABRICAR: que el guion se valide antes de generar nada, y que salga STEP.
#
# POR QUE IMPORTA: un taller no acepta un.glb, acepta un STEP -- geometria exacta, no triangulos.
# Y una pieza con un error de medidas descubierto a mitad del ensamblaje deja archivos a medias,
# que con piezas reales es peor que no generar nada: alguien puede mandar a cortar el equivocado.
TC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok    $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA $1  ($2)"; }
TC_TMP="$(mktemp -d)"; trap 'rm -rf "$TC_TMP"' EXIT

cat > "$TC_TMP/malo.json" <<'JSON'
{"unidades":"mm","piezas":[
  {"nombre":"x","forma":"caja","x":10,"y":10,"z":5,"agujeros":[{"diametro":20,"en":[0,0]}]},
  {"nombre":"x","forma":"esfera"}]}
JSON
cat > "$TC_TMP/bueno.json" <<'JSON'
{"unidades":"mm","piezas":[
  {"nombre":"base","forma":"caja","x":80,"y":60,"z":10,
   "agujeros":[{"diametro":6,"en":[25,18]},{"diametro":6,"en":[-25,-18]}]},
  {"nombre":"eje","forma":"cilindro","diametro":12,"alto":40}]}
JSON

echo "-- la validacion corre ANTES de generar"
SAL="$(python3 "$TC_HERE/engine/cad_pieza.py" "$TC_TMP/malo.json" "$TC_TMP/out-malo" 2>&1)"
case "$SAL" in *"no genere nada"*) _ok "un guion con errores no genera archivos" ;;
  *) _mal "genero pese a los errores" "$(printf '%s' "$SAL" | head -2 | tr '\n' ' ')" ;; esac
[ ! -d "$TC_TMP/out-malo" ] || [ "$(ls -1 "$TC_TMP/out-malo" 2>/dev/null | wc -l)" = "0" ] \
  && _ok "no quedo ningun archivo a medias" || _mal "quedaron archivos" "peligroso: se podria mandar a cortar"
case "$SAL" in *"no entra en una pieza"*) _ok "detecta un agujero mas grande que la pieza" ;;
  *) _mal "no detecta el agujero imposible" "saldria una pieza partida al medio" ;; esac
case "$SAL" in *"dos piezas con el nombre"*) _ok "detecta nombres repetidos (se pisarian los archivos)" ;;
  *) _mal "no detecta nombres repetidos" "una pieza sobreescribiria a la otra" ;; esac
case "$SAL" in *"que no conozco"*) _ok "rechaza una forma que no sabe hacer, en vez de inventarla" ;;
  *) _mal "no rechaza la forma desconocida" "" ;; esac

echo "-- generacion real (necesita build123d)"
if ! python3 -c "import build123d" 2>/dev/null; then
  echo "  -- build123d no instalado; la generacion se saltea"
else
  SAL="$(python3 "$TC_HERE/engine/cad_pieza.py" "$TC_TMP/bueno.json" "$TC_TMP/out" 2>&1)"
  [ -f "$TC_TMP/out/base-soporte.step" ] || [ -f "$TC_TMP/out/base.step" ] \
    && _ok "genera el STEP (lo que se manda al taller)" || _mal "no genero STEP" "$SAL"
  ls "$TC_TMP/out"/*.stl >/dev/null 2>&1 \
    && _ok "genera tambien el STL (para imprimir)" || _mal "no genero STL" ""
  # El STEP tiene que ser un STEP de verdad, no un archivo vacio con la extension puesta.
  if head -c 200 "$TC_TMP/out"/*.step 2>/dev/null | grep -qi "ISO-10303"; then
    _ok "el STEP tiene cabecera ISO-10303 (es un STEP de verdad)"
  else
    _mal "el.step no parece un STEP" "un taller lo rebotaria"
  fi
  # Y lo generado tiene que pasar el analisis de fabricabilidad de la etapa A.
  if python3 -c "import trimesh" 2>/dev/null; then
    for f in "$TC_TMP/out"/*.stl; do
      if python3 "$TC_HERE/engine/modelo3d_analizar.py" "$f" >/dev/null 2>&1; then
        _ok "$(basename "$f") pasa el analisis de fabricabilidad"
      else
        _mal "$(basename "$f") no pasa el analisis" "generamos una pieza que no se puede fabricar"
      fi
    done
  fi
fi

echo
echo "== $OK ok, $MAL fallan =="
[ "$MAL" -eq 0 ]
