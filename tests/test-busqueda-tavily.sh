#!/usr/bin/env bash
# test-busqueda-tavily.sh -- que la busqueda web use Tavily cuando hay clave, y que sin clave
# siga funcionando exactamente como antes.
#
# POR QUE EXISTE: la primera version de esto iba embebida como `python3 -c` adentro del bash y los
# "\n" del formato se convirtieron en saltos de linea reales al escribir el archivo. El Python
# quedo partido, no compilaba, y el `2>/dev/null` se comia el error: el motor veia una respuesta
# vacia, indistinguible de "Tavily no encontro nada". Habria quedado roto en silencio.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
P="$HERE/engine/tavily_buscar.py"
ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el script existe y COMPILA =="
[ -f "$P" ] && _ok "engine/tavily_buscar.py existe" || _mal "el script" "no esta"
python3 -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read())" "$(cygpath -w "$P" 2>/dev/null || printf '%s' "$P")" 2>/dev/null \
  && _ok "compila (esto es lo que fallaba embebido en el bash)" \
  || _mal "compila" "el Python quedo roto y el motor no se enteraria"

echo ""
echo "== sin clave no rompe nada =="
SALIDA="$(TAVILY_API_KEY="" python3 "$(cygpath -w "$P" 2>/dev/null || printf '%s' "$P")" "lo que sea" 2>&1)"; RC=$?
[ "$RC" = "0" ] && _ok "sale con 0 aunque no haya clave" || _mal "exit sin clave" "dio $RC; cortaria la busqueda"
[ -z "${SALIDA// }" ] && _ok "no imprime nada (el motor lo lee como 'sin resultados')" || _mal "salida sin clave" "imprimio: $SALIDA"

echo ""
echo "== el cableado en el motor =="
grep -q 'tavily_buscar.py' "$A" && _ok "el agente llama al script" || _mal "cableado" "el script existiria sin que nadie lo use"
grep -q 'TAVILY_API_KEY=' "$A" && _ok "lee la clave del archivo de secretos" || _mal "clave" "no habria de donde sacarla"
# Tavily va PRIMERO y la escalera vieja queda de respaldo. Si se invirtiera, se gastarian cuatro
# viajes contra buscadores con CAPTCHA antes de usar el que si funciona.
if awk '/# TAVILY PRIMERO/,/done <<< /' "$A" | grep -q 'La escalera de buscadores queda de RESPALDO'; then
  _ok "Tavily va primero y la escalera queda de respaldo"
else
  _mal "orden" "la escalera correria antes que Tavily"
fi
if awk '/La escalera de buscadores queda de RESPALDO/,/done <<< /' "$A" | grep -q 'if \[ -z "${BRESP// }" \]; then'; then
  _ok "la escalera solo corre si Tavily no trajo nada"
else
  _mal "respaldo condicionado" "se gastarian los viajes igual"
fi
echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
