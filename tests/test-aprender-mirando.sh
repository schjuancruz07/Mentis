#!/usr/bin/env bash
# test-aprender-mirando.sh -- grabar acciones y convertirlas en una skill (idea 1 del usuario).
#
# QUE SE PRUEBA OFFLINE (que es casi todo): que una grabacion se lea como una secuencia de pasos
# entendible, que los clics se agrupen en vez de soltar una linea por clic, y -- lo mas importante
# -- QUE NO SE GUARDE EL CONTENIDO DE LO QUE SE ESCRIBE. Esa ultima es la unica comprobacion que no
# se puede aflojar: sin ella, esto es un keylogger.
#
# La grabacion en vivo necesita a alguien usando la computadora, asi que se prueba con un jsonl
# fabricado con la misma forma que escribe mentis-grabar-acciones.ps1, BOM incluido.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok   -- $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA-- $1"; }

AM_TMP="$(mktemp -d)"
trap 'rm -rf "$AM_TMP"' EXIT
echo "== aprender mirando =="

# --- 1. sintaxis ---------------------------------------------------------------------------------
for f in "$RAIZ/mentis-aprender-mirando.sh"; do
  bash -n "$f" 2>/dev/null && _ok "sintaxis ok: $(basename "$f")" || _mal "sintaxis rota: $f"
done
if python3 -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read())" \
     "$(cygpath -w "$RAIZ/engine/grabacion_legible.py" 2>/dev/null || printf '%s' "$RAIZ/engine/grabacion_legible.py")" 2>/dev/null; then
  _ok "sintaxis ok: grabacion_legible.py"
else
  _mal "grabacion_legible.py no compila"
fi

# --- 2. EL GRABADOR NO PUEDE GUARDAR LO QUE SE ESCRIBE --------------------------------------------
# Se mira el codigo del grabador: las letras y numeros solo pueden SUMAR a un contador. Si alguna
# vez alguien las escribiera al archivo, esto es lo que lo tiene que frenar.
PS="$RAIZ/mentis-grabar-acciones.ps1"
if [ -f "$PS" ]; then
  if grep -qE 'textoAcumulado\+\+' "$PS"; then
    _ok "las teclas comunes solo incrementan un contador"
  else
    _mal "no se ve el contador de caracteres: revisar que no se esten guardando las teclas"
  fi
  # El evento 'escribio' solo puede llevar una CANTIDAD, nunca el texto.
  if grep -E 'tipo = "escribio"' "$PS" | grep -q 'caracteres = '; then
    _ok "el evento de escritura guarda la cantidad, no el texto"
  else
    _mal "el evento de escritura cambio de forma: verificar que no incluya el contenido"
  fi
  # El patron busca un CAMPO llamado texto/contenido/tecleado, no la subcadena "texto" en
  # cualquier lado: la primera version marcaba como fuga la variable $textoAcumulado, que es
  # justamente el contador que evita la fuga.
  if grep -qiE '(^|[;{[:space:]])(texto|contenido|tecleado|teclas) *=' "$PS"; then
    _mal "el grabador tiene un campo que podria guardar el contenido tipeado"
  else
    _ok "no hay ningun campo con el contenido tipeado"
  fi
else
  _mal "falta mentis-grabar-acciones.ps1"
fi

# --- 3. la grabacion se lee como una secuencia ---------------------------------------------------
# Con BOM al principio a proposito: Add-Content de PowerShell 5.1 lo escribe siempre, y sin
# contemplarlo se perdia el primer evento en silencio.
GRAB="$AM_TMP/grab.jsonl"
printf '\xef\xbb\xbf' > "$GRAB"
{
  echo '{"ventana":"Calculadora","t":0,"tipo":"inicio"}'
  echo '{"ventana":"Calculadora","t":900,"tipo":"clic","boton":"izquierdo","x":100,"y":200}'
  echo '{"ventana":"Calculadora","t":1200,"tipo":"clic","boton":"izquierdo","x":110,"y":210}'
  echo '{"ventana":"Calculadora","t":1500,"tipo":"clic","boton":"izquierdo","x":120,"y":220}'
  echo '{"ventana":"Calculadora","t":2000,"tipo":"escribio","caracteres":7}'
  echo '{"ventana":"Calculadora","t":2400,"tipo":"tecla","tecla":"Enter"}'
  echo '{"ventana":"Bloc de notas","t":3000,"tipo":"ventana"}'
  echo '{"ventana":"Bloc de notas","t":3500,"tipo":"atajo","tecla":"Ctrl+V"}'
  echo '{"t":4000,"tipo":"fin"}'
} >> "$GRAB"

SAL="$(python3 "$RAIZ/engine/grabacion_legible.py" "$(cygpath -w "$GRAB" 2>/dev/null || printf '%s' "$GRAB")" 2>&1)"

case "$SAL" in
  *"Calculadora"*) _ok "el primer evento sobrevive al BOM (aparece la primera ventana)" ;;
  *) _mal "se perdio el primer evento: volvio el problema del BOM" ;;
esac
case "$SAL" in
  *"3 clics"*) _ok "los clics seguidos se agrupan en un paso ('3 clics')" ;;
  *) _mal "los clics no se agruparon: la lista queda ilegible" ;;
esac
case "$SAL" in
  *"escribio 7 caracteres"*) _ok "lo escrito se cuenta, no se transcribe" ;;
  *) _mal "no aparece el conteo de caracteres" ;;
esac
case "$SAL" in
  *"Enter"*) _ok "las teclas de control quedan como pasos con nombre" ;;
  *) _mal "se perdieron las teclas de control" ;;
esac
case "$SAL" in
  *"Ctrl+V"*) _ok "los atajos quedan como pasos con nombre" ;;
  *) _mal "se perdieron los atajos" ;;
esac
case "$SAL" in
  *"Bloc de notas"*) _ok "el cambio de ventana se registra" ;;
  *) _mal "no se registro el cambio de ventana" ;;
esac
case "$SAL" in
  *"duro 4 segundos"*) _ok "informa cuanto duro la tarea" ;;
  *) _mal "no informa la duracion" ;;
esac
# El orden importa: una secuencia desordenada no sirve para reconstruir nada.
if printf '%s' "$SAL" | grep -n "Calculadora" | head -1 | grep -q "^[0-9]*:" && \
   [ "$(printf '%s\n' "$SAL" | grep -n "Calculadora" | head -1 | cut -d: -f1)" -lt \
     "$(printf '%s\n' "$SAL" | grep -n "Bloc de notas" | head -1 | cut -d: -f1)" ]; then
  _ok "los pasos salen en el orden en que ocurrieron"
else
  _mal "los pasos salieron desordenados"
fi

# --- 4. una grabacion vacia no explota ------------------------------------------------------------
VACIA="$AM_TMP/vacia.jsonl"; : > "$VACIA"
SAL2="$(python3 "$RAIZ/engine/grabacion_legible.py" "$(cygpath -w "$VACIA" 2>/dev/null || printf '%s' "$VACIA")" 2>&1)"
case "$SAL2" in
  *vacia*) _ok "una grabacion vacia lo dice en vez de romperse" ;;
  *) _mal "una grabacion vacia no se maneja: $SAL2" ;;
esac

# --- 5. la skill generada no entra sin compilar ---------------------------------------------------
# No se llama al modelo (costaria una llamada y depende de la red): se comprueba que la guarda
# ESTE en el codigo. Una skill rota en capabilities/ rompe el listado entero, no solo a si misma.
if grep -q 'bash -n "$DEST"' "$RAIZ/mentis-aprender-mirando.sh"; then
  _ok "la skill generada se rechaza si no compila"
else
  _mal "falta la guarda que impide guardar una skill con error de sintaxis"
fi
if grep -q 'rechazada' "$RAIZ/mentis-aprender-mirando.sh"; then
  _ok "y la rechazada se guarda aparte para poder mirarla"
else
  _mal "una skill rechazada se pierde sin dejar rastro"
fi
if grep -q 'Ya existe capabilities' "$RAIZ/mentis-aprender-mirando.sh"; then
  _ok "no pisa una skill que ya existe"
else
  _mal "podria sobrescribir una skill existente"
fi

echo
echo "== $OK ok, $MAL falla(s) =="
[ "$MAL" -eq 0 ]
