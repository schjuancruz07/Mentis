#!/usr/bin/env bash
# test-core-fs-exec.sh -- ejercita las tools read/write/exec de nv-agent.sh contra escenarios
# reales. Raiz de trabajo dedicada y descartable (no toca el workspace real del usuario).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
rm -rf "$ROOT"; mkdir -p "$ROOT"
printf 'linea uno\nlinea dos\nSCH-MARKER-12345\n' > "$ROOT/archivo-prueba.txt"

_sk_section "core-fs-exec (read/write/exec de nv-agent.sh)"

_sk_case "read: leer un archivo real y citar su contenido" \
  bash "$TOOLSDIR/nv-agent.sh" -w -d "$ROOT" -m general -i 5 \
  "Leé el archivo archivo-prueba.txt y decime EXACTAMENTE qué dice la tercera línea."

_sk_case "write: crear un archivo nuevo real con contenido especifico" \
  bash "$TOOLSDIR/nv-agent.sh" -w -d "$ROOT" -m general -i 6 \
  "Creá un archivo llamado saludo.txt con el texto exacto 'hola desde el test' adentro, nada mas."

_sk_case "exec: correr un comando real y devolver su salida" \
  bash "$TOOLSDIR/nv-agent.sh" -w -d "$ROOT" -m general -i 6 \
  "Ejecutá el comando 'echo MENTIS-EXEC-OK' en la terminal y decime la salida exacta que dio."

echo "  -- verificacion adicional (fuera del modelo): existe saludo.txt con el contenido esperado?"
if [ -f "$ROOT/saludo.txt" ]; then
  echo "  saludo.txt existe. Contenido: $(cat "$ROOT/saludo.txt")"
else
  echo "  AVISO: saludo.txt NO se creo en disco (el modelo puede haber fallado el paso write)."
fi
