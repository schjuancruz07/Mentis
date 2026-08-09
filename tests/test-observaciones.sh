#!/usr/bin/env bash
# test-observaciones.sh -- las salidas largas se GUARDAN, no se tiran (2026-07-27).
#
# Antes, una observación que no entraba en el prompt se cortaba con `head -c 2000` y el resto
# desaparecía: si Mentis leía un archivo de 12 KB, los últimos 10 KB dejaban de existir para él.
# Si después los necesitaba, tenía que volver a leer el archivo -- otra iteración, otra llamada
# al modelo, y el mismo recorte otra vez.
#
# Se prueba la función DIRECTAMENTE y no a través del agente: con el agente, qué herramienta usa
# y en qué orden lo decide el modelo, así que el test daría verde o rojo según el humor del día.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
OK=0; FALLOS=0
ok()  { echo "  ok   -- $1"; OK=$((OK+1)); }
mal() { echo "  MAL  -- $1"; FALLOS=$((FALLOS+1)); }

OBS_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/obs-$$")"
trap 'rm -rf "$OBS_TMP"' EXIT

# Se extrae la función real del agente (no una copia que podría quedar desincronizada).
sed -n '/^_trunc() {/,/^}/p' "$RAIZ/engine/nv-agent.sh" > "$OBS_TMP/funcion.sh"
if [ -s "$OBS_TMP/funcion.sh" ]; then ok "se pudo extraer _trunc del agente"; else mal "no se encontro _trunc"; fi

# Mismo entorno que tiene la función cuando corre dentro del agente.
export ROOT="$OBS_TMP/raiz"; mkdir -p "$ROOT"
export OBSMAX=2000 OBS_PREVIEW=700 OBSDIR_REL=".mentis-obs" it=7 _obs_seq=0
# shellcheck source=/dev/null
source "$OBS_TMP/funcion.sh"

echo "== una salida CORTA pasa igual que siempre =="
CORTA="$(printf 'hola mundo' | _trunc)"
if [ "$CORTA" = "hola mundo" ]; then ok "no toca lo que ya entraba"; else mal "altero una salida corta: '$CORTA'"; fi
if [ -d "$ROOT/.mentis-obs" ]; then mal "creo un archivo para una salida que entraba"; else ok "no crea archivos de mas"; fi

echo "== una salida LARGA se guarda entera y se avisa donde =="
python3 -c "
print('PRINCIPIO QUE SI SE VE')
for i in range(400): print('relleno %d de una salida larga que no entra en el prompt' % i)
print('FINAL QUE ANTES SE PERDIA: la respuesta es 42')
" > "$OBS_TMP/larga.txt"
TAM_ORIGINAL=$(wc -c < "$OBS_TMP/larga.txt")
SALIDA="$(_trunc < "$OBS_TMP/larga.txt")"

if [ "${#SALIDA}" -lt "$TAM_ORIGINAL" ]; then
  ok "lo que va al prompt es mas chico que el original (${#SALIDA} vs $TAM_ORIGINAL)"
else
  mal "no achico nada"
fi
if echo "$SALIDA" | grep -q "PRINCIPIO QUE SI SE VE"; then ok "el principio se ve"; else mal "perdio el principio"; fi
if echo "$SALIDA" | grep -q "\.mentis-obs/"; then ok "avisa donde quedo el resto"; else mal "no dice donde esta el resto"; fi
if echo "$SALIDA" | grep -q "read"; then ok "le dice COMO leerlo"; else mal "no explica como recuperarlo"; fi
# REGRESION del bucle infinito (2026-07-27): la primera version avisaba "leelo con read" a secas.
# Pero el archivo guardado TAMBIEN supera el tope, asi que leerlo generaba otra descarga, que al
# leerse generaba otra: obs-1-1 -> obs-2-1 -> obs-3-1, sin llegar nunca al final. El aviso tiene
# que decir desde DONDE seguir, no solo que el archivo existe.
if echo "$SALIDA" | grep -q '"value"'; then
  ok "indica desde que posicion seguir (sin esto, vuelve a empezar de cero y cicla)"
else
  mal "no dice desde donde continuar: el agente releeria el mismo principio para siempre"
fi

ARCHIVO="$(ls "$ROOT/.mentis-obs/"*.txt 2>/dev/null | head -1)"
if [ -n "$ARCHIVO" ]; then ok "guardo la salida en un archivo"; else mal "no guardo nada"; fi
# LO QUE IMPORTA: el dato del final, que antes desaparecia, sigue existiendo.
if grep -q "FINAL QUE ANTES SE PERDIA" "$ARCHIVO" 2>/dev/null; then
  ok "el final del contenido NO se perdio (antes se tiraba)"
else
  mal "se perdio el final: el offload no sirve de nada"
fi
if [ "$(wc -c < "$ARCHIVO")" -eq "$TAM_ORIGINAL" ]; then
  ok "se guardo COMPLETO, byte por byte"
else
  mal "el archivo guardado no coincide con el original"
fi

echo "== el archivo queda DENTRO de la raiz del agente =="
# Si quedara afuera, la tool 'read' (enjaulada) no podria abrirlo y la referencia seria inutil.
case "$ARCHIVO" in
  "$ROOT"/*) ok "queda dentro de la raiz, alcanzable con 'read'" ;;
  *)         mal "quedo fuera de la raiz: el agente no podria leerlo" ;;
esac

echo
echo "RESULTADO: $OK ok, $FALLOS fallos."
[ "$FALLOS" -eq 0 ] || exit 1
