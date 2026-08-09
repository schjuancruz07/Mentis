#!/usr/bin/env bash
# test-classifier.sh -- nv_classify_msg (nv-classify-lib.sh), matriz de regresion. Incluye los
# casos reales de ERR-065 (trivial con acentos/prefijo) y ERR-067 (code por "que"+n8n suelto,
# el bug que reporto el usuario con respuesta vacia) para que una regresion futura se detecte sola.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"
source "$TOOLSDIR/nv-classify-lib.sh"

_sk_section "clasificador de turno (nv_classify_msg)"

# formato: "mensaje|||tipo_esperado|||motivo"
CASOS=(
  "hola|||trivial|||saludo simple"
  "gracias!|||trivial|||agradecimiento con signo"
  "cómo andás?|||trivial|||con acentos (ERR-065)"
  "listo|||trivial|||confirmacion corta"
  "hola, tengo una duda sobre python|||general|||NO trivial pese a empezar como saludo (ERR-065, prefijo no alcanza)"
  "che, implementame una funcion en python|||code|||pedido real de codigo"
  "que es un closure en javascript?|||code|||pregunta tecnica real con ?"
  "como funciona un webhook|||code|||pregunta tecnica real, arranca con 'como'"
  "Contexto: Tengo una empresa que se llama SCh que hace automatizaciones en n8n. Tengo un contacto que visite una vez y le ofreci una automatizacion. Esta persona se llama Mario, pasame la propuesta.|||general|||ERR-067: mensaje real del usuario, NO es pregunta tecnica pese a mencionar n8n"
  "trabajo con n8n haciendo automatizaciones para clientes|||general|||mencion de n8n sin pregunta real"
  "cuánto conviene, aws o gcp para este caso?|||reason|||pregunta de decision/comparacion"
  "mandame una foto de un gato|||multimodal|||pedido de imagen"
)

FALLOS=0
for c in "${CASOS[@]}"; do
  msg="${c%%|||*}"
  resto="${c#*|||}"
  esperado="${resto%%|||*}"
  motivo="${resto#*|||}"
  real="$(nv_classify_msg "$msg" 0 | awk '{print $1}')"
  if [ "$real" = "$esperado" ]; then
    echo "  OK: \"$msg\" -> $real (esperado: $esperado) -- $motivo"
  else
    echo "  FALLO: \"$msg\" -> $real (ESPERADO: $esperado) -- $motivo"
    FALLOS=$((FALLOS+1))
  fi
done

{
  echo "### Matriz de clasificacion (${#CASOS[@]} casos, $FALLOS fallo(s))"
  echo '```'
  for c in "${CASOS[@]}"; do
    msg="${c%%|||*}"
    resto="${c#*|||}"
    esperado="${resto%%|||*}"
    real="$(nv_classify_msg "$msg" 0 | awk '{print $1}')"
    estado="OK"; [ "$real" != "$esperado" ] && estado="FALLO"
    printf '[%s] "%s" -> %s (esperado %s)\n' "$estado" "$msg" "$real" "$esperado"
  done
  echo '```'
  echo ""
} | tee -a "$SKTEST_REPORT" >/dev/null

echo "  TOTAL: ${#CASOS[@]} casos, $FALLOS fallo(s)"
