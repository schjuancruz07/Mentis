#!/usr/bin/env bash
# test-modelos-guardia.sh -- que el guardia clasifique bien y que NO toque produccion.
#
# NO usa la red. Lo que se prueba es la decision -- "¿este numero entra en el presupuesto?" --
# que es donde estuvo el agujero de ERR-128, no la llamada HTTP.
#
# POR QUE NO SE PRUEBA CON UN MODELO LENTO DE VERDAD: el 2026-08-07 glm-5.2 medía 90 s a la
# mañana y 3 s a la tarde. Un test que dependa de que un modelo externo este lento hoy es un test
# que falla o pasa segun la hora, y eso es peor que no tenerlo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$HERE/mentis-modelos-guardia.sh"

ok=0; fallo=0
check() {
  local nombre="$1" esperado="$2" obtenido="$3"
  if [ "$esperado" = "$obtenido" ]; then ok=$((ok+1)); printf '  ok    %s\n' "$nombre"
  else fallo=$((fallo+1)); printf '  FALLA %s -- esperaba [%s], obtuvo [%s]\n' "$nombre" "$esperado" "$obtenido"; fi
}

echo "== lo basico =="
bash -n "$G" 2>/dev/null; check "compila" "0" "$?"
[ -x "$G" ]; check "es ejecutable" "0" "$?"

echo "== NO escribe en produccion (ERR-119 / ERR-131) =="
# El guardia mide y avisa; el que cambia modelos es el reparador. Si algun dia alguien le agrega
# una escritura "para automatizar", este test tiene que gritar.
grep -qE '(>|>>)[[:space:]]*"?[^"|]*modelos-override\.json|(mv|cp|tee)[[:space:]][^|]*modelos-override\.json' "$G"
check "no escribe modelos-override.json" "1" "$?"
grep -qE '(>|>>)[[:space:]]*"?[^"|]*\.nv-secrets' "$G"
check "no escribe.nv-secrets" "1" "$?"

echo "== la clasificacion =="
# Misma regla que usa el guardia: se compara el PEOR tiempo contra el presupuesto en ms.
clasificar() {
  local peor="$1" presup_s="$2" hubo="${3:-1}"
  local presup_ms=$(( presup_s * 1000 ))
  if [ "$hubo" = "0" ]; then echo "MUERTO"
  elif [ "$peor" -gt "$presup_ms" ]; then echo "LENTO"
  else echo "ok"; fi
}
check "756 ms con 18 s -> ok"            "ok"     "$(clasificar 756 18)"
check "3.097 ms con 18 s -> ok"          "ok"     "$(clasificar 3097 18)"
check "82.510 ms con 18 s -> LENTO"      "LENTO"  "$(clasificar 82510 18)"
check "el caso real de ERR-128"          "LENTO"  "$(clasificar 93820 18)"
check "sin respuesta -> MUERTO"          "MUERTO" "$(clasificar 0 18 0)"
check "justo en el limite (18.000) -> ok" "ok"    "$(clasificar 18000 18)"
check "un ms pasado -> LENTO"            "LENTO"  "$(clasificar 18001 18)"
# Un rol deliberativo espera mas: lo que es LENTO para puede estar bien para ultra.
check "20 s con presupuesto de 45 -> ok" "ok"     "$(clasificar 20000 45)"

echo "== toma el PEOR, no el promedio =="
# La razon de ser del guardia: un modelo que a veces tarda 90 s falla a veces, y el promedio lo
# esconde. Con 3 s / 3 s / 90 s el promedio da 32 s, pero lo que importa es el 90.
peor=0
for ms in 3000 3100 90000; do [ "$ms" -gt "$peor" ] && peor="$ms"; done
check "peor de (3.000, 3.100, 90.000)" "90000" "$peor"
check "y ese peor clasifica LENTO"     "LENTO" "$(clasificar "$peor" 18)"

echo "== extrae bien el nombre del modelo de la tabla =="
# La primera corrida real reporto MUERTOS a 'fast', 'deep' y 'ultra' -- los tres roles SIN
# override -- porque el substr del awk se comia la primera letra del vendor: "vidia/nemotron..."
# y "eta/llama...". Los roles CON override no lo mostraban, porque su nombre sale del JSON.
# El sintoma era el peor posible: un modelo sano reportado como muerto.
extraer() {
  printf '%s\n' "$1" | awk -v rol="$2" '
    $0 ~ "^[[:space:]]*" rol "\\)" {
      if (match($0, /NVMODEL="[^"]+"/)) { print substr($0, RSTART+9, RLENGTH-10); exit }
    }'
}
check "vendor completo (nvidia, no vidia)" "nvidia/nemotron-3-super-120b-a12b" \
  "$(extraer '  deep)       NVMODEL="nvidia/nemotron-3-super-120b-a12b";      NVMAX=4096;' deep)"
check "vendor completo (meta, no eta)" "meta/llama-3.1-8b-instruct" \
  "$(extraer '  fast)       NVMODEL="meta/llama-3.1-8b-instruct";            NVMAX=200;' fast)"
check "no se come la ultima letra" "z-ai/glm-5.2" \
  "$(extraer '  code)       NVMODEL="z-ai/glm-5.2";                           NVMAX=4096;' code)"
# Y contra el archivo de verdad, que es lo unico que prueba que sigue andando manana.
real="$(bash -c '. '"$HERE"'/engine/nv-lib.sh 2>/dev/null;. '"$HERE"'/engine/nv-modelos-lib.sh 2>/dev/null
  awk -v rol=fast "\$0 ~ \"^[[:space:]]*\" rol \"\\\\)\" { if (match(\$0, /NVMODEL=\"[^\"]+\"/)) { print substr(\$0, RSTART+9, RLENGTH-10); exit } }" '"$HERE"'/engine/ask-nvidia.sh' | tr -d '\r')"
case "$real" in
  */*) check "sobre ask-nvidia.sh real: trae vendor/modelo" "0" "0" ;;
  *)   check "sobre ask-nvidia.sh real: trae vendor/modelo" "0" "1" ;;
esac

echo "== lee el modelo con el override aplicado =="
# Si midiera el modelo de la tabla default teniendo override, mediria algo que nadie ejecuta.
# Es la forma exacta de ERR-119.
grep -q "nv_override_rol" "$G"; check "consulta el override antes que la tabla" "0" "$?"
grep -q "nv_ttft_rol" "$G";     check "saca el presupuesto de ask-nvidia.sh" "0" "$?"

echo "== los codigos de salida distinguen los casos =="
grep -q "exit 2" "$G"; check "sale 2 si hay MUERTO" "0" "$?"
grep -q "exit 1" "$G"; check "sale 1 si hay LENTO"  "0" "$?"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
