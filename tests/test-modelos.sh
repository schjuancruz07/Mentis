#!/usr/bin/env bash
# test-modelos.sh — tests de mentis-modelos.sh (chequeo de salud de los modelos).
# Todo OFFLINE: no llama al endpoint. Lo que se prueba es el parseo de la tabla de roles, el
# analisis de telemetria y las invariantes de configuracion que causaron bugs reales.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/mentis-modelos.sh"
ASK="$DIR/engine/ask-nvidia.sh"
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fail=1; fi; }

# --- 1. sintaxis ---
if bash -n "$SCRIPT" 2>/dev/null; then echo "ok: mentis-modelos.sh parsea sin errores"; else echo "FAIL: error de sintaxis"; fail=1; fi

# --- 2. la tabla de roles sale del propio ask-nvidia.sh, completa y sin recortes ---
# Bug real al escribirlo: los offsets de substr() en awk se comian el primer caracter de cada
# id ("z-ai/glm-5.2" -> "-ai/glm-5.2"), y un id recortado da 404 = "modelo muerto" inventado.
# Antes esto extraia el cuerpo de _mm_tabla_roles con sed y lo corria suelto. Se rompio el
# 2026-08-01 cuando la funcion se mudo a engine/nv-modelos-lib.sh (la comparte con el reparador
# automatico): extraer codigo por texto ata el test a DONDE esta escrita la funcion, no a lo que
# hace. Ahora se llama a la implementacion de verdad, que es lo que corre en produccion.
TABLA="$(bash -c 'source "'"$DIR"'/engine/nv-lib.sh"; source "'"$DIR"'/engine/nv-modelos-lib.sh"; nv_tabla_roles "'"$ASK"'"')"
NROLES="$(printf '%s\n' "$TABLA" | grep -c.)"
chk "$NROLES" "9" "se detectan los 9 roles de ask-nvidia.sh"
# Cada modelo parseado tiene que existir TEXTUALMENTE en ask-nvidia.sh (si se comio un char, no)
recortados=0
while read -r _rol pri fb fb2; do
  for m in "$pri" "$fb" "$fb2"; do
    [ "$m" = "-" ] && continue
    grep -q "\"$m\"" "$ASK" || { echo "  (modelo mal parseado: '$m')"; recortados=$((recortados+1)); }
  done
done <<< "$TABLA"
chk "$recortados" "0" "ningun id de modelo sale recortado del parseo"

# --- 3. invariante: ningun rol puede quedar sin techo de tiempo ---
# Con NVTO=0 curl espera para siempre, y el fallback solo salta si el principal FALLA: un modelo
# saturado (acepta la conexion y no contesta) dejaba a Mentis mudo sin caer nunca al fallback.
SIN_TECHO="$(grep -cE '^  [a-z]+\)[[:space:]]+NVMODEL=.*NVTO=0;' "$ASK")"
chk "$SIN_TECHO" "0" "ningun rol quedo con NVTO=0 (cuelgue infinito sin caer al fallback)"

# --- 4. telemetria: detecta el rol que vive cayendo al fallback ---
TMPLOG="$(mktemp)"
{
  for _ in 1 2 3 4 5 6 7; do echo '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S%z)"'","rol":"reason","modelo":"x","latencia_ms":900,"exit":0,"fallback":true}'; done
  for _ in 1 2 3;       do echo '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S%z)"'","rol":"reason","modelo":"x","latencia_ms":900,"exit":0,"fallback":false}'; done
  for _ in 1 2 3 4 5;   do echo '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S%z)"'","rol":"fast","modelo":"y","latencia_ms":800,"exit":0,"fallback":false}'; done
} > "$TMPLOG"
SALIDA="$(NV_LOGFILE="$TMPLOG" bash "$SCRIPT" -t -d 7 2>&1)"
case "$SALIDA" in *"SENALES DE QUE UN PRINCIPAL NO ESTA BIEN"*) echo "ok: la telemetria alerta cuando un rol cae al fallback el 70% de las veces";; *) echo "FAIL: no alerto con 70% de fallback"; fail=1;; esac
case "$SALIDA" in *"rol reason"*) echo "ok: la alerta nombra al rol afectado";; *) echo "FAIL: la alerta no dice que rol es"; fail=1;; esac
case "$SALIDA" in *"rol fast"*) echo "FAIL: alerto sobre un rol sano"; fail=1;; *) echo "ok: no alerta sobre el rol sano";; esac

# --- 5. telemetria: las lineas que no son llamadas a un modelo no cuentan como fallo ---
# nv_log lo usan tambien el indexador y nv-verify, que loguean sin 'exit' ni latencia: contarlas
# daba "100% fallidas" para roles que ni siquiera llaman a un modelo.
{
  echo '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S%z)"'","rol":"indexador","modelo":"z"}'
  echo '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S%z)"'","rol":"indexador","modelo":"z","exit":""}'
} >> "$TMPLOG"
SALIDA2="$(NV_LOGFILE="$TMPLOG" bash "$SCRIPT" -t -d 7 2>&1)"
case "$SALIDA2" in *indexador*) echo "FAIL: cuenta lineas que no son llamadas a un modelo"; fail=1;; *) echo "ok: ignora las lineas de log que no son llamadas a un modelo";; esac
rm -f "$TMPLOG"

# --- 6. telemetria sin datos no explota ---
VACIO="$(mktemp)"; : > "$VACIO"
SALIDA3="$(NV_LOGFILE="$VACIO" bash "$SCRIPT" -t 2>&1)"; rc=$?
chk "$rc" "0" "el modo telemetria sale limpio aunque el log este vacio"
case "$SALIDA3" in *"Sin llamadas registradas"*) echo "ok: avisa que no hay datos en vez de mostrar una tabla vacia";; *) echo "FAIL: no avisa que no hay datos"; fail=1;; esac
rm -f "$VACIO"

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
