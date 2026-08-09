#!/usr/bin/env bash
# test-deshacer.sh -- volver atrás lo que Mentis tocó, sin tocar el git del usuario.
#
# El test que más importa acá no es "restaura bien" sino "NO le mete mano al repo del usuario".
# El 2026-07-26 se creó un repo de git que el usuario no había pedido y hubo que borrarlo; este
# mecanismo se diseñó para que eso no pueda repetirse, y esto lo comprueba.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
OK=0; FALLOS=0
ok()  { echo "  ok   -- $1"; OK=$((OK+1)); }
mal() { echo "  MAL  -- $1"; FALLOS=$((FALLOS+1)); }

UND_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/undo-$$")"
SOMBRAS="$UND_TMP/sombras"
export MENTIS_SOMBRAS_DIR="$SOMBRAS"
trap 'rm -rf "$UND_TMP"' EXIT

PROY="$UND_TMP/proyecto"
mkdir -p "$PROY"

echo "== el repo del usuario queda intacto =="
( cd "$PROY" && git init -q && echo "algo del usuario" > suyo.txt && git add -A \
  && git -c user.email=j@j -c user.name=el usuario commit -qm "commit propio del usuario" ) 2>/dev/null
COMMITS_ANTES="$(cd "$PROY" && git rev-list --count HEAD 2>/dev/null)"

echo "contenido original" > "$PROY/datos.txt"
ID="$(bash "$RAIZ/mentis-deshacer.sh" foto "$PROY" "antes de la prueba" 2>/dev/null)"
if [ -n "${ID// }" ]; then ok "saca una foto y devuelve su id ($ID)"; else mal "no pudo sacar la foto"; fi

COMMITS_DESPUES="$(cd "$PROY" && git rev-list --count HEAD 2>/dev/null)"
if [ "$COMMITS_ANTES" = "$COMMITS_DESPUES" ]; then
  ok "el historial del usuario NO cambió ($COMMITS_ANTES commit(s) antes y después)"
else
  mal "le agregó commits al repo del usuario: $COMMITS_ANTES -> $COMMITS_DESPUES"
fi
if (cd "$PROY" && git log --all --oneline 2>/dev/null | grep -qi "antes de la prueba"); then
  mal "la foto de Mentis quedó DENTRO del repo del usuario"
else
  ok "la foto vive fuera del repo del usuario"
fi
if [ -d "$SOMBRAS" ]; then ok "las fotos van a su propio directorio"; else mal "no creo el repo sombra"; fi

echo "== restaura lo que se pisó y lo que se borró =="
echo "PISADO CON BASURA" > "$PROY/datos.txt"
rm -f "$PROY/suyo.txt"
bash "$RAIZ/mentis-deshacer.sh" volver "$PROY" "$ID" >/dev/null 2>&1
if [ "$(cat "$PROY/datos.txt" 2>/dev/null)" = "contenido original" ]; then
  ok "el archivo pisado volvió a su contenido"
else
  mal "no restauro el contenido pisado"
fi
if [ -f "$PROY/suyo.txt" ]; then ok "el archivo borrado volvió"; else mal "no recupero el archivo borrado"; fi

echo "== deshacer TAMBIEN se puede deshacer =="
# Antes de restaurar se guarda el estado actual: si el remedio fuera irreversible seria tan
# peligroso como el problema.
FOTOS="$(bash "$RAIZ/mentis-deshacer.sh" listar "$PROY" 2>/dev/null | grep -c.)"
if [ "$FOTOS" -ge 2 ]; then
  ok "quedo guardado el estado previo al deshacer ($FOTOS fotos)"
else
  mal "no guardo el estado anterior: deshacer seria irreversible"
fi

echo "== avisa que NO borra los archivos nuevos =="
echo "archivo que hizo el usuario despues" > "$PROY/nuevo-de-usuario.txt"
SALIDA="$(bash "$RAIZ/mentis-deshacer.sh" volver "$PROY" "$ID" 2>&1)"
if [ -f "$PROY/nuevo-de-usuario.txt" ]; then
  ok "no borra archivos creados despues (podrian ser del usuario)"
else
  mal "borro un archivo que el usuario creo despues de la foto"
fi
if echo "$SALIDA" | grep -qi "NO se borraron"; then
  ok "lo dice explicitamente en vez de dejarlo implicito"
else
  mal "no avisa que los archivos nuevos siguen ahi"
fi

echo
echo "RESULTADO: $OK ok, $FALLOS fallos."
[ "$FALLOS" -eq 0 ] || exit 1
