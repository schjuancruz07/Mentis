#!/usr/bin/env bash
# test-tavily.sh -- la busqueda web tiene que DEVOLVER RESULTADOS, no morir en silencio.
#
# POR QUE EXISTE (2026-08-20). Se descubrio con una tarea real: se le pidio a Mentis buscar un
# proyecto en GitHub y gasto LAS 25 ITERACIONES del turno pidiendo `browse` una y otra vez, sin
# entregar nada. La busqueda no fallaba: la busqueda ANDABA y moria al imprimir. Python en Windows
# escribe en cp1252 por defecto, asi que cualquier resultado con un acento, una comilla curva o un
# emoji reventaba con UnicodeEncodeError -- o sea, casi cualquier resultado real, y en español
# todos.
#
# Y no se veia por ningun lado: nv-agent.sh llama a este script con 2>/dev/null. El error se
# perdia y el motor recibia una salida vacia, indistinguible de "no encontre nada". El modelo hacia
# lo razonable -- volver a buscar -- y asi 25 veces.
#
# El propio archivo ya advertia de esta clase de error para otra causa ("el 2>/dev/null se comia el
# error de sintaxis"). Se arreglo aquella puerta y entro por la de al lado.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/engine/tavily_buscar.py"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

[ -f "$SCRIPT" ] || { echo "no existe $SCRIPT"; exit 1; }
WSCRIPT="$(cygpath -w "$SCRIPT" 2>/dev/null || printf '%s' "$SCRIPT")"

echo "== sin clave: vacio y sin ruido (asi lo espera quien lo llama) =="
SAL="$(TAVILY_API_KEY="" timeout -k 5 30 python3 "$WSCRIPT" "lo que sea" 2>&1)"; RC=$?
[ "$RC" = "0" ] && _ok "sale con 0 aunque no haya clave" || _mal "sin clave devuelve $RC" "el motor lo trata como error y corta la escalera de buscadores"
[ -z "${SAL// }" ] && _ok "y no imprime nada" || _mal "imprimio algo sin clave" "$SAL"

echo ""
echo "== EL CASO QUE ROMPIO TODO: texto que no entra en cp1252 =="
# Se prueba el camino REAL de escritura del script -- su stdout -- con el mismo tipo de contenido
# que trae cualquier resultado de verdad. Si el interprete no esta reconfigurado, esto explota
# igual que explotaba la busqueda.
CASO="$(mktemp)"
cat > "$CASO" <<'PY'
import sys, io, os
sys.argv = ["tavily_buscar.py", "prueba"]
os.environ["TAVILY_API_KEY"] = ""
ruta = sys.argv_ruta = None
PY
# Se importa el modulo de verdad (no una copia) y se escribe por SU stdout ya reconfigurado.
PRUEBA="$(mktemp)"
cat > "$PRUEBA" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("tv", os.environ["TV_PATH"])
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
# Lo mismo que hace el script al final: escribir resultados reales por stdout.
sys.stdout.write("- Título con acentos: cañón, café, ñandú\n")
sys.stdout.write("- Comillas curvas: “esto” y emoji: \U0001F600\n")
sys.stdout.write("- Braille (lo trae el README de vercel-labs/fx): ⠀⣠⣾\n")
PY
if TV_PATH="$WSCRIPT" timeout -k 5 30 python3 "$PRUEBA" > "$CASO" 2>&1; then
  _ok "imprimir acentos, comillas curvas, emoji y braille no explota"
else
  _mal "sigue explotando al imprimir" "$(head -3 "$CASO" | tr '\n' ' ')"
fi
grep -q "cañón" "$CASO" && _ok "y el texto sale legible (no se rompio en el camino)" \
  || _mal "el texto salio mal" "$(head -2 "$CASO")"
rm -f "$CASO" "$PRUEBA"

echo ""
echo "== con clave: busca de verdad y trae resultados =="
# Test VIVO: usa la red. Si no hay clave configurada se saltea diciendolo -- pero no se da por
# bueno en silencio, que es como esto estuvo roto.
CLAVE="$(grep -ohE 'TAVILY[A-Z_]*=.*' "$HERE/.custom-models-secrets.env" "$HERE/engine/.nv-secrets" 2>/dev/null | head -1 | cut -d= -f2-)"
if [ -z "${CLAVE// }" ]; then
  echo "  (sin clave de Tavily configurada: no se puede probar la busqueda de verdad)"
else
  SAL="$(TAVILY_API_KEY="$CLAVE" timeout -k 10 60 python3 "$WSCRIPT" "python programming language" 2>&1)"; RC=$?
  [ "$RC" = "0" ] && _ok "la busqueda sale con 0" || _mal "la busqueda fallo (rc=$RC)" "$(printf '%s' "$SAL" | head -3)"
  if [ "$(printf '%s' "$SAL" | grep -c 'https\?://')" -ge 2 ]; then
    _ok "trae al menos dos resultados con su URL"
  else
    _mal "no trajo resultados" "esto es lo que hacia que el modelo buscara 25 veces: $(printf '%s' "$SAL" | head -2)"
  fi
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
