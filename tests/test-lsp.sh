#!/usr/bin/env bash
# test-lsp.sh -- el cliente LSP de Mentis (engine/lsp_client.py, agregado 2026-08-02).
#
# QUE SE PRUEBA:
#   Nuestro lado del protocolo, contra un servidor de mentira (tests/datos/lsp-servidor-falso.py)
#   que a proposito se comporta como los servidores reales en las tres cosas que rompen a un
#   cliente ingenuo: manda notificaciones antes de la respuesta, devuelve la definicion como
#   objeto suelto en formato LocationLink, y empuja los diagnosticos en vez de contestarlos.
#
#   Y se prueba que DEGRADE BIEN sin ningun servidor instalado, que es el estado real de esta
#   maquina hoy: un mensaje que diga que instalar vale mas que un traceback.
set -uo pipefail
TL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TL_ROOT="$(cd "$TL_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TL_OK=0; TL_MAL=0
_ok()  { TL_OK=$((TL_OK+1));  echo "  OK   $1"; }
_mal() { TL_MAL=$((TL_MAL+1)); echo "  MAL  $1  ($2)"; }

TL_TMP="$(mktemp -d)"
trap 'rm -rf "$TL_TMP"' EXIT

# Un archivo de prueba con una funcion, para que las lineas que devuelve el servidor falso
# correspondan a algo real si alguien mira.
cat > "$TL_TMP/ejemplo.py" <<'PY'
import os


def procesar(datos):
    acumulador = 0
    for d in datos:
        acumulador += d
    return acumulador


print(procesar([1, 2, 3]))
PY

# Registro apuntando al servidor falso. Es el mismo mecanismo que usaria el usuario para agregar un
# lenguaje nuevo: un JSON, sin tocar codigo.
#
# LA RUTA VA EN FORMATO WINDOWS, y no es un detalle: el cliente es python de Windows y NO entiende
# rutas MSYS (/c/Users/...) -- las abre y no encuentra nada. Es ERR-004/006. El sintoma era
# perfecto para perder una hora: el servidor arrancaba, moria enseguida sin decir nada (su stderr
# va a DEVNULL) y el cliente fallaba recien al escribirle, con "Invalid argument" en una linea que
# no tiene nada que ver. 'cygpath -m' da C:/Users/... que sirve de los dos lados.
TL_FALSO="$(cygpath -m "$TL_HERE/datos/lsp-servidor-falso.py" 2>/dev/null || printf '%s' "$TL_HERE/datos/lsp-servidor-falso.py")"
cat > "$TL_TMP/lsp-servidores.json" <<JSON
{
  ".py": {"cmd": ["python3", "$TL_FALSO"], "lenguaje": "python",
          "instalar": "es el servidor de prueba"}
}
JSON

echo "== degradar bien, que es el estado real de esta maquina =="
TL_S="$(python3 "$TL_ROOT/engine/lsp_client.py" servidores 2>&1)"
printf '%s' "$TL_S" | grep -q "no instalado" && _ok "dice cuales faltan en vez de fallar" || _mal "no reportó los faltantes" "$TL_S"
printf '%s' "$TL_S" | grep -q "npm i -g" && _ok "dice CÓMO instalar cada uno" || _mal "no dice cómo instalar" "$TL_S"

TL_S="$(python3 "$TL_ROOT/engine/lsp_client.py" simbolos --archivo "$TL_ROOT/modelos-override.json" 2>&1)"; TL_RC=$?
[ "$TL_RC" = "3" ] && _ok "extension sin servidor configurado: sale 3 con mensaje claro" || _mal "código de salida inesperado" "$TL_RC"

# El caso "servidor no instalado" se FABRICA, no se toma de la maquina. La version anterior de este
# test afirmaba que bash-language-server no estaba instalado -- y se rompio en el momento exacto en
# que se instalo, o sea cuando el sistema MEJORO. Un test no puede depender de que falte algo.
mkdir -p "$TL_TMP/inexistente"
cat > "$TL_TMP/inexistente/lsp-servidores.json" <<'JSON'
{".zz": {"cmd": ["servidor-que-no-existe-en-ninguna-parte"], "lenguaje": "zz",
         "instalar": "npm i -g el-comando-de-ejemplo"}}
JSON
cp "$TL_ROOT/engine/lsp_client.py" "$TL_TMP/inexistente/lsp_client.py"
printf 'hola\n' > "$TL_TMP/inexistente/x.zz"
TL_S="$(cd "$TL_TMP/inexistente" && python3 lsp_client.py simbolos --archivo "$TL_TMP/inexistente/x.zz" 2>&1)"; TL_RC=$?
[ "$TL_RC" = "4" ] && _ok "servidor no instalado: sale 4 y dice qué instalar" || _mal "código de salida inesperado" "$TL_RC"
printf '%s' "$TL_S" | grep -q "npm i -g el-comando-de-ejemplo" && _ok "el mensaje trae el comando exacto de ESE servidor" || _mal "el mensaje no trae el comando" "$TL_S"

echo "== el protocolo, contra un servidor que se porta como los de verdad =="
# El cliente lee el registro de al lado suyo, asi que se corre una copia en el temporal.
cp "$TL_ROOT/engine/lsp_client.py" "$TL_TMP/lsp_client.py"

TL_D="$(cd "$TL_TMP" && python3 lsp_client.py definicion --archivo "$TL_TMP/ejemplo.py" --linea 11 --columna 7 2>&1)"
printf '%s' "$TL_D" | grep -q ":3:5" && _ok "definicion: entiende LocationLink y objeto suelto" || _mal "no interpretó la definición" "$TL_D"
printf '%s' "$TL_D" | grep -qi "ejemplo.py" && _ok "convierte la URI file:// de vuelta a una ruta" || _mal "no convirtió la URI" "$TL_D"

TL_R="$(cd "$TL_TMP" && python3 lsp_client.py referencias --archivo "$TL_TMP/ejemplo.py" --linea 4 --columna 5 2>&1)"
printf '%s' "$TL_R" | grep -q "2 referencia" && _ok "referencias: cuenta las dos" || _mal "no contó las referencias" "$TL_R"
printf '%s' "$TL_R" | grep -q ":10:9" && _ok "referencias: convierte lineas y columnas a base 1" || _mal "las posiciones salieron mal" "$TL_R"

TL_Y="$(cd "$TL_TMP" && python3 lsp_client.py simbolos --archivo "$TL_TMP/ejemplo.py" 2>&1)"
printf '%s' "$TL_Y" | grep -q "funcion  procesar" && _ok "simbolos: nombra y clasifica la función" || _mal "no listó la función" "$TL_Y"
printf '%s' "$TL_Y" | grep -q "acumulador" && _ok "simbolos: baja a los hijos anidados" || _mal "no bajó a los hijos" "$TL_Y"

TL_G="$(cd "$TL_TMP" && python3 lsp_client.py diagnosticos --archivo "$TL_TMP/ejemplo.py" 2>&1)"
printf '%s' "$TL_G" | grep -q "totl" && _ok "diagnosticos: recibe los que el servidor EMPUJA" || _mal "no recibió los diagnósticos" "$TL_G"
printf '%s' "$TL_G" | grep -q "linea 7" && _ok "diagnosticos: la linea sale en base 1" || _mal "la línea salió mal" "$TL_G"

TL_J="$(cd "$TL_TMP" && python3 lsp_client.py referencias --archivo "$TL_TMP/ejemplo.py" --linea 4 --columna 5 --json 2>&1)"
printf '%s' "$TL_J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and len(d)==2 else 1)' 2>/dev/null \
  && _ok "--json devuelve JSON parseable" || _mal "el --json no era válido" "$TL_J"

echo "== el despacho de nv-agent, que es como lo usa Mentis de verdad =="
# EL CASO QUE MAS IMPORTA: sin servidor instalado, lsp_client.py sale con codigo 3 o 4. nv-agent.sh
# corre con `set -e`, asi que una asignacion desde ese comando ABORTABA EL TURNO ENTERO en vez de
# devolver una observacion (ERR-009). Encontrado probando esto: pedir 'lsp definicion' mataba la
# conversacion. Este bloque es la regresion de ese bug.
TL_DESP="$(cd "$TL_ROOT" && bash -c '
source engine/nv-agent.sh 2>/dev/null || true
_foto_antes_de_tocar() { :; }
D="$(mktemp -d)"; printf "def f():
    return 1
" > "$D/x.py"
ROOT="$D"; OBSMAX=3000; ALLOW_WRITE=0; it=1; TOOL="lsp"
PATH_B64="$(printf x.py | base64 -w0)"; ACTION_B64="$(printf definicion | base64 -w0)"
X_B64="$(printf 1 | base64 -w0)"; Y_B64="$(printf 5 | base64 -w0)"
QUERY_B64=""; CODE_B64=""; CONTENT_B64=""; ANSWER_B64=""; OLD_B64=""; NEW_B64=""; OBS=""
_dispatch_tool 1 2>/dev/null
printf "%s" "$OBS"
rm -rf "$D"' 2>&1)"; TL_RC=$?
[ "$TL_RC" = "0" ] && _ok "sin servidor instalado, el turno NO se aborta" || _mal "el despacho abortó el turno" "rc=$TL_RC"
printf '%s' "$TL_DESP" | grep -qi "no esta instalado\|npm i -g" && _ok "el modelo recibe qué instalar, no un error mudo" || _mal "la observación no orienta" "$TL_DESP"

TL_D2="$(cd "$TL_ROOT" && bash -c '
source engine/nv-agent.sh 2>/dev/null || true
_foto_antes_de_tocar() { :; }
D="$(mktemp -d)"; ROOT="$D"; OBSMAX=3000; ALLOW_WRITE=0; it=1; TOOL="lsp"
PATH_B64=""; ACTION_B64="$(printf servidores | base64 -w0)"
X_B64=""; Y_B64=""; QUERY_B64=""; CODE_B64=""; CONTENT_B64=""; ANSWER_B64=""; OLD_B64=""; NEW_B64=""; OBS=""
_dispatch_tool 1 2>/dev/null
printf "%s" "$OBS"; rm -rf "$D"' 2>&1)"
printf '%s' "$TL_D2" | grep -q "Servidores de lenguaje configurados" && _ok "'lsp servidores' funciona sin archivo" || _mal "no listó los servidores" "$TL_D2"

echo
echo "== RESULTADO: $TL_OK bien, $TL_MAL mal =="
[ "$TL_MAL" -eq 0 ]
