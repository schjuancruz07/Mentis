#!/usr/bin/env bash
# test-gen-read.sh -- lo que el modelo VE despues de generar un archivo, y por que dejaba de
# entender que ya habia terminado (bug real 2026-07-30, encontrado por el usuario en la app).
#
# Sintoma: un PDF que salio bien costaba 4 pasos en vez de 1. El agente generaba el documento
# y despues intentaba LEERLO tres veces seguidas:
#     read RECHAZADO: C:/Users/<usuario>/Documents/Mentis/Documentos/gen-1785364312-12574.pdf
#     read RECHAZADO: /c/Users/<usuario>/Documents/Mentis/Documentos/gen-1785364312-12574.pdf
#     read RECHAZADO:.mentis-obs
#
# Dos causas, las dos de comunicacion y no de logica:
#   1. 'gen' devolvia como observacion la RUTA PELADA (mentis-doc-gen.sh imprime $OUT y nada mas).
#      Sin contexto, esa ruta es una invitacion a abrirla.
#   2. 'read' contestaba "ruta invalida, fuera de la raiz, o no es un archivo" a TODO: ruta
#      absoluta, directorio, archivo inexistente. Un error que no dice POR QUE no saca al modelo
#      del loop -- lo manda a probar la misma ruta escrita distinto (por eso el segundo intento
#      es la MISMA ruta en forma MSYS).
#
# Se prueba el loop REAL de nv-agent.sh con un stub deterministico de ask-nvidia.sh, y las
# aserciones miran EL PROMPT QUE RECIBE EL MODELO en la iteracion siguiente -- que es exactamente
# lo que fallaba. Ninguna llamada de API.
#
# OJO (ERR-095): las aserciones de este archivo son POSITIVAS a proposito. Las del tipo "que NO
# aparezca X" se cumplen solas cuando el agente no arranca, y asi fue como test-verify-escalera
# estuvo dando verde sin ejecutar nada. Igual hay una guardia de arranque al principio.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../engine"
PASS=0; FAIL=0
_ok()  { echo "  OK   -- $1"; PASS=$((PASS+1)); }
_bad() { echo "  FALLO-- $1"; FAIL=$((FAIL+1)); }
_expect() { # _expect <descripcion> <texto> <regex>
  if printf '%s' "$2" | grep -qF -- "$3"; then _ok "$1"; else _bad "$1 (no aparece: $3)"; fi
}

# ---- sandbox con la estructura REAL (raiz/ + raiz/engine/), misma leccion de ERR-095 ----------
SB_RAIZ="$(mktemp -d)"
trap 'rm -rf "$SB_RAIZ"' EXIT
SB="$SB_RAIZ/engine"
mkdir -p "$SB"
cp "$ENGINE/nv-agent.sh" "$ENGINE/nv-lib.sh" "$SB/"
cp "$ENGINE/nv-verify.sh" "$SB/" 2>/dev/null || true
cp "$HERE/../mentis-doc-gen.sh" "$HERE/../docgen.py" "$SB_RAIZ/" 2>/dev/null || true

# Carpeta de creaciones de MENTIRA: 'gen' escribe de verdad, pero en el sandbox. Sin esto el test
# dejaria archivos gen-*.pdf en la carpeta real de Documentos del usuario.
CREACIONES="$SB_RAIZ/creaciones"
mkdir -p "$CREACIONES"

cat > "$SB_RAIZ/mentis-deshacer.sh" <<'DESHACER'
#!/usr/bin/env bash
echo "foto-de-prueba-0000"
DESHACER
chmod +x "$SB_RAIZ/mentis-deshacer.sh"

# ---- stub: reproduce EXACTAMENTE la secuencia del bug ------------------------------------------
# Cada iteracion guarda el prompt que recibio, para poder mirar despues que observacion vio.
cat > "$SB/ask-nvidia.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
STUB_PROMPT="$(cat)"
STATE="${STUB_STATE:?}"
STUB_N="$(cat "$STATE" 2>/dev/null || echo 0)"; STUB_N=$((STUB_N+1)); echo "$STUB_N" > "$STATE"
printf '%s' "$STUB_PROMPT" > "$STATE.prompt.$STUB_N"

case "${STUB_ESC:?}:$STUB_N" in
  # --- escenario 1: la secuencia de rechazos del bug ---
  rechazos:1) printf '{"tool":"read","path":"C:/Users/<usuario>/Documents/Mentis/Documentos/gen-1785364312-12574.pdf"}\n' ;;
  rechazos:2) printf '{"tool":"read","path":"/c/Users/<usuario>/Documents/Mentis/Documentos/gen-1785364312-12574.pdf"}\n' ;;
  rechazos:3) printf '{"tool":"read","path":"grande.txt"}\n' ;;   # genera.mentis-obs de verdad
  rechazos:4) printf '{"tool":"read","path":".mentis-obs"}\n' ;;
  rechazos:5) printf '{"tool":"read","path":"C:/Windows/System32/drivers/etc/hosts"}\n' ;;
  rechazos:6) printf '{"tool":"read","path":"no-existe.txt"}\n' ;;
  rechazos:7) printf '{"tool":"read","path":"si-existe.txt"}\n' ;;  # el camino BUENO sigue vivo
  rechazos:*) printf '{"tool":"done","answer":"listo"}\n' ;;

  # --- escenario 2: gen doc real ---
  gendoc:1) printf '{"tool":"gen","action":"doc","format":"pdf","content":"# Informe de prueba\\n\\nUn parrafo cualquiera."}\n' ;;
  gendoc:*) printf '{"tool":"done","answer":"listo"}\n' ;;
esac
STUB
chmod +x "$SB/ask-nvidia.sh"

_run() { # _run <escenario> <iteraciones> [flags extra]
  local esc="$1" iters="$2"; shift 2
  local work="$SB/work-$esc"
  mkdir -p "$work"
  rm -f "$SB/state-$esc" "$SB/state-$esc".*
  STUB_ESC="$esc" STUB_STATE="$SB/state-$esc" \
  MENTIS_CREATIONS_DIR="$CREACIONES" MENTIS_SETTINGS_FILE="$SB/nope.json" \
    bash "$SB/nv-agent.sh" -d "$work" -m code -i "$iters" "$@" "tarea de prueba" 2>&1
}
_prompt() { cat "$SB/state-$1.prompt.$2" 2>/dev/null || true; }

# Material de trabajo del escenario 1.
mkdir -p "$SB/work-rechazos"
printf 'contenido chico y legible\n' > "$SB/work-rechazos/si-existe.txt"
python3 -c "
for i in range(400): print('relleno %d de una salida larga que no entra en el prompt' % i)
" > "$SB/work-rechazos/grande.txt"

echo "== 0. GUARDIA: el agente arranca de verdad en el sandbox =="
SALIDA="$(_run rechazos 9)"
if printf '%s' "$SALIDA" | grep -qE '\[nv-agent\] iter 1: read'; then
  _ok "el loop corrio (si esto falla, lo de abajo no significa nada)"
else
  _bad "el agente NO arranco -- test abortado"
  echo "$SALIDA" | head -20
  echo; echo "RESULTADO: $PASS ok, $FAIL fallos."; exit 1
fi

echo "== 1. ruta ABSOLUTA: las dos formas de la MISMA ruta dan el mismo diagnostico =="
_expect "detecta la forma Windows (C:/...)"  "$SALIDA" "read RECHAZADO (ruta absoluta): C:/Users/<usuario>/Documents"
_expect "detecta la forma MSYS (/c/...)"     "$SALIDA" "read RECHAZADO (ruta absoluta): /c/Users/<usuario>/Documents"
# Lo que ve el modelo. Esta es la parte que importa: antes las dos veces leia el mismo texto
# generico, que no le decia ni que la ruta era absoluta ni que el archivo ya estaba entregado.
_expect "le avisa que es una creacion YA entregada"        "$(_prompt rechazos 2)" "creación tuya que YA quedó entregada"
_expect "le dice que termine en vez de verificar"          "$(_prompt rechazos 2)" "terminá el turno con 'done'"
_expect "en el reintento MSYS recibe el mismo diagnostico" "$(_prompt rechazos 3)" "creación tuya que YA quedó entregada"

echo "== 2. una ruta absoluta que NO es una creacion explica la regla de rutas relativas =="
_expect "distingue el caso general"        "$(_prompt rechazos 6)" "es una ruta ABSOLUTA"
_expect "avisa que reescribirla no sirve"  "$(_prompt rechazos 6)" "Escribirla de otra forma va a fallar igual"

echo "== 3..mentis-obs es un DIRECTORIO, no un archivo ilegible =="
_expect "lo registra como directorio"          "$SALIDA" "read RECHAZADO (es un directorio):.mentis-obs"
_expect "le explica que es la carpeta de obs"  "$(_prompt rechazos 5)" "es la CARPETA donde se guardan las observaciones"
_expect "le lista los archivos que hay"        "$(_prompt rechazos 5)" ".mentis-obs/obs-"

echo "== 4. el archivo inexistente manda a buscar, no a adivinar otra ruta =="
_expect "sigue rechazando lo que no existe" "$SALIDA" "read RECHAZADO: no-existe.txt"
_expect "ofrece 'search' como salida"       "$(_prompt rechazos 7)" '"tool":"search"'

echo "== 5. REGRESION: leer un archivo normal sigue funcionando igual =="
_expect "el read bueno se ejecuta"      "$SALIDA" "iter 7: read si-existe.txt"
_expect "y devuelve el contenido real"  "$(_prompt rechazos 8)" "contenido chico y legible"

echo "== 6. 'gen doc' avisa que TERMINO, en vez de devolver una ruta pelada =="
if ! python3 -c "import reportlab" 2>/dev/null; then
  _bad "falta reportlab: no se pudo probar gen doc de verdad (instalar y volver a correr)"
else
  SALIDA_GEN="$(_run gendoc 3 -g)"
  _expect "el documento se genero"  "$SALIDA_GEN" "iter 1: gen doc (pdf)"
  _expect "y se anuncio como artefacto para la app" "$SALIDA_GEN" "[nv-agent] ARTIFACT:"
  ARCH="$(ls "$CREACIONES/Documentos/"*.pdf 2>/dev/null | head -1)"
  if [ -s "$ARCH" ]; then _ok "el PDF existe y pesa mas de 0 bytes"; else _bad "no quedo el PDF en la carpeta de creaciones"; fi

  P2="$(_prompt gendoc 2)"
  _expect "el modelo lee LISTO, no una ruta suelta" "$P2" "LISTO: el documento (pdf) creado en"
  _expect "le dice que el usuario ya lo tiene"            "$P2" "el usuario lo tiene a la vista"
  _expect "le prohibe verificarlo con read"         "$P2" "NO hace falta abrirlo"
  # La ruta se sigue diciendo: el modelo tiene que poder nombrarla en su respuesta al usuario.
  _expect "la ruta sigue estando (en formato Windows)" "$P2" "Documentos"
fi

echo
echo "RESULTADO: $PASS ok, $FAIL fallos."
[ "$FAIL" -eq 0 ] || exit 1
