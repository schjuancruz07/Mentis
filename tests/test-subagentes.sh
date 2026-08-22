#!/usr/bin/env bash
# test-subagentes.sh — los sub-agentes de Mentis.
#
# Contexto (2026-07-28): Mentis se auto-investigó y reportó que sus sub-agentes no podían hacer
# casi nada. Tenía razón, y estaba escrito así a propósito -- pero con DOS problemas de verdad:
#   1. presupuesto clavado en 4 iteraciones, tan poco que ni una tarea de clasificación terminaba;
#   2. cuando se quedaban sin presupuesto, al cerebro principal le llegaba el historial crudo sin
#      ninguna señal de que estaba leyendo un intento fallido, y lo trataba como una respuesta.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTE="$DIR/engine/nv-agent.sh"
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fail=1; fi; }

bash -n "$AGENTE" && echo "ok: nv-agent.sh parsea sin errores" || { echo "FAIL: sintaxis"; fail=1; }

echo "== 1. el presupuesto se puede pedir, con topes =="
grep -q 'SAITER=8' "$AGENTE" && echo "ok: el default subio de 4 a 8 iteraciones" || { echo "FAIL: sigue el default viejo"; fail=1; }
grep -q '\[ "\$SAITER" -lt 2 \] && SAITER=2' "$AGENTE" && echo "ok: hay piso de 2 iteraciones" || { echo "FAIL: sin piso"; fail=1; }
grep -q '\[ "\$SAITER" -gt 12 \] && SAITER=12' "$AGENTE" && echo "ok: hay techo de 12 iteraciones" || { echo "FAIL: sin techo"; fail=1; }

echo "== 2. lo que un sub-agente NO puede hacer (y no debe poder) =="
# La linea que lo invoca no puede llevar -w (escribir) ni -e (ejecutar). Si alguien las agrega,
# un sub-agente sin supervision pasa a tocar archivos y correr comandos: esto se rompe a proposito.
LINEA="$(grep -n 'NVA_SUBAGENT_DEPTH=1 bash' "$AGENTE" | head -1)"
[ -n "$LINEA" ] || { echo "FAIL: no encontre la invocacion del sub-agente"; fail=1; }
case "$LINEA" in
  *" -w"*) echo "FAIL: el sub-agente recibe permiso de ESCRITURA"; fail=1 ;;
  *" -e"*) echo "FAIL: el sub-agente recibe permiso de EJECUCION"; fail=1 ;;
  *) echo "ok: no recibe permisos de escritura ni de ejecucion" ;;
esac
grep -q 'NVA_SUBAGENT_DEPTH:-0}" -ge 1' "$AGENTE" && echo "ok: sigue sin poder lanzar otro sub-agente" || { echo "FAIL: se perdio el limite de profundidad"; fail=1; }

echo "== 3. la web es opcional y explicita =="
grep -q 'SAFLAGS+=(-b)' "$AGENTE" && echo "ok: se le puede prestar la navegacion con args.web" || { echo "FAIL: no se puede habilitar la web"; fail=1; }

echo "== 4. quedarse sin presupuesto se AVISA, no se disfraza de respuesta =="
grep -q 'SIN PRESUPUESTO' "$AGENTE" && echo "ok: el aviso de presupuesto agotado existe" || { echo "FAIL: no avisa"; fail=1; }
grep -q 'no lo cites como si lo fuera' "$AGENTE" && echo "ok: le aclara al cerebro principal que NO es una conclusion" || { echo "FAIL: falta la aclaracion"; fail=1; }
grep -q 'STATUS=budget' "$AGENTE" && echo "ok: detecta el STATUS=budget del sub-agente" || { echo "FAIL: no detecta el status"; fail=1; }

echo "== 5. el protocolo se lo explica al modelo =="
# El protocolo se mudo a engine/textos/protocolo/*.txt: buscar solo en nv-agent.sh daba
# FAIL con el texto intacto, en base.txt. Se busca en las dos fuentes (2026-08-18).
grep -rq "'value' es su presupuesto de iteraciones" "$AGENTE" "$(dirname "$AGENTE")/textos" && echo "ok: el protocolo documenta el presupuesto" || { echo "FAIL: el modelo no sabe que puede pedirlo"; fail=1; }

echo "== 6. prueba VIVA: un sub-agente con presupuesto corto termina en budget, no en silencio =="
# Esto llama modelos de verdad. Es la unica forma de comprobar que el contrato (STATUS=budget +
# exit 4) sigue siendo el que el codigo de arriba espera encontrar.
TMPROOT="$(mktemp -d)"
printf 'hola\n' > "$TMPROOT/dato.txt"
SALIDA="$(NVA_SUBAGENT_DEPTH=1 timeout 300 bash "$AGENTE" -d "$TMPROOT" -m general -i 2 \
  "Leé todos los archivos de este directorio, después buscá la palabra hola en todos, y recién ahí respondé cuántos archivos hay." 2>/dev/null)"; RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$SALIDA" | head -1 | grep -q '^STATUS='; then
  echo "ok: al quedarse corto devuelve STATUS=... y exit 4 (el contrato que el codigo espera)"
elif [ "$RC" -eq 0 ]; then
  echo "ok: lo resolvio dentro del presupuesto (tambien es un resultado valido)"
else
  echo "FAIL: termino de una forma que el codigo de arriba no sabe interpretar (rc=$RC, primera linea: $(printf '%s' "$SALIDA" | head -1))"; fail=1
fi
rm -rf "$TMPROOT"

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
