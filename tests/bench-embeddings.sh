#!/usr/bin/env bash
# bench-embeddings.sh -- compara modelos de embeddings para Kai Vault con evidencia, no por catalogo.
#
# Por que existe: hay que reindexar Mentis de cero (el indice viejo apuntaba a rutas de antes de
# la migracion), asi que hay que elegir modelo. El catalogo de NVIDIA no alcanza para decidir
# -- ya se comprobo que miente (ERR-003: kimi-k2.6 figura listado y responde "Not found for
# account"). Se mide igual que se eligio el cerebro 'deep': con tareas reales y numeros.
#
# Metrica: de N consultas con respuesta conocida, cuantas traen el archivo correcto en el top-3
# (recall@3) y en el top-1. Las consultas estan escritas como las haria el usuario, no con las
# palabras exactas del codigo -- si no, se estaria midiendo grep, no busqueda semantica.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_OUT="${1:-$HERE/tests/bench-embeddings-resultado.md}"

# consulta ::: archivo que DEBE aparecer
CASOS=(
  "donde se decide que modelo de IA atiende cada tipo de pedido:::engine/ask-nvidia.sh"
  "un modelo distinto escribe los tests para verificar el codigo:::engine/nv-agent.sh"
  "matar los procesos que quedan vivos despues de frenar:::app/lib/mentis-process.js"
  "crear la carpeta de un proyecto nuevo con sus subdivisiones:::app/lib/project-store.js"
  "saber en que lugar estoy usando el wifi:::mentis-location.sh"
  "copia de seguridad automatica todos los dias:::mentis-backup.sh"
  "correr codigo aislado sin que toque el resto de la maquina:::engine/nv-lib.sh"
  "decidir si el mensaje es de codigo o de conversacion:::engine/nv-classify-lib.sh"
  "generar una imagen a partir de un texto:::mentis-image-gen.sh"
  "pasar un audio a texto:::mentis-transcribe.sh"
  "mover el mouse y escribir con el teclado solo:::mentis-computer-control.sh"
  "armar un documento de Word:::mentis-doc-gen.sh"
  "programar una tarea para que corra sola mas tarde:::capabilities/programar.sh"
  "agregar un conector nuevo al sistema:::capabilities/conectar.sh"
  "impedir que se ejecute un comando peligroso:::engine/nv-agent.sh"
)

MODELOS=("nvidia/nv-embedqa-e5-v5" "nvidia/nemotron-3-embed-1b")

{
  echo "# Comparativa de modelos de embeddings para Kai Vault"
  echo
  echo "Fecha: $(date '+%Y-%m-%d %H:%M')"
  echo "Casos: ${#CASOS[@]} consultas con respuesta conocida."
  echo
} > "$BENCH_OUT"

for MODELO in "${MODELOS[@]}"; do
  echo "== $MODELO ==" >&2
  IDX="/tmp/bench-$(printf '%s' "$MODELO" | md5sum | cut -d' ' -f1).jsonl"
  T0="$(date +%s)"
  # UNA sola raiz: indexar engine/, app/lib/ y capabilities/ ademas de la raiz que ya los
  # contiene duplicaba cada archivo con rutas relativas distintas, y el pareo por nombre se
  # volvia ambiguo. La raiz sola cubre todo.
  IDXOUT="$(bash "$HERE/engine/nv-index.sh" -m "$MODELO" -o "$IDX" --completo "$HERE" 2>&1 | tail -1)"
  T_INDEX=$(( $(date +%s) - T0 ))
  if [[ "$IDXOUT" != OK* ]]; then
    { echo "## $MODELO"; echo; echo "FALLO al indexar: $IDXOUT"; echo; } >> "$BENCH_OUT"
    echo "  FALLO: $IDXOUT" >&2
    continue
  fi
  CHUNKS="$(printf '%s' "$IDXOUT" | grep -oE 'chunks=[0-9]+' | cut -d= -f2)"

  ACIERTOS_3=0; ACIERTOS_1=0; TOTAL=0; T_BUSQ=0
  DETALLE=""
  for caso in "${CASOS[@]}"; do
    CONSULTA="${caso%%:::*}"
    ESPERADO="${caso##*:::}"
    TB0="$(date +%s%3N)"
    RES="$(bash "$HERE/engine/nv-search.sh" -k 3 -m "$MODELO" -i "$IDX" --json -- "$CONSULTA" 2>/dev/null)"
    T_BUSQ=$(( T_BUSQ + $(date +%s%3N) - TB0 ))
    TOTAL=$((TOTAL+1))
    POS="$(BENCH_RES="$RES" BENCH_ESP="$ESPERADO" python3 -c '
import json, os, sys
try:
    filas = json.loads(os.environ["BENCH_RES"])
except Exception:
    print(0); sys.exit(0)
esperado = os.environ["BENCH_ESP"].lower()
for i, f in enumerate(filas, start=1):
    # el indice guarda la ruta relativa a la raiz indexada, asi que se compara por sufijo
    if f.get("file","").lower().replace("\\","/").endswith(esperado.split("/")[-1]):
        print(i); sys.exit(0)
print(0)
' 2>/dev/null || echo 0)"
    if [ "$POS" = "1" ]; then ACIERTOS_1=$((ACIERTOS_1+1)); fi
    if [ "$POS" != "0" ]; then ACIERTOS_3=$((ACIERTOS_3+1)); MARCA="OK  (pos $POS)"; else MARCA="fallo"; fi
    DETALLE="$DETALLE
| $CONSULTA | \`$ESPERADO\` | $MARCA |"
  done

  MS_PROM=$(( T_BUSQ / (TOTAL>0?TOTAL:1) ))
  {
    echo "## $MODELO"
    echo
    echo "- Chunks indexados: **$CHUNKS** (tardo ${T_INDEX}s)"
    echo "- Acierto en top-3: **$ACIERTOS_3 / $TOTAL**"
    echo "- Acierto en top-1: **$ACIERTOS_1 / $TOTAL**"
    echo "- Latencia media por busqueda: **${MS_PROM} ms**"
    echo
    echo "| Consulta | Esperado | Resultado |"
    echo "|---|---|---|$DETALLE"
    echo
  } >> "$BENCH_OUT"
  echo "  top3=$ACIERTOS_3/$TOTAL top1=$ACIERTOS_1/$TOTAL ${MS_PROM}ms indexado=${T_INDEX}s chunks=$CHUNKS" >&2
done

echo >&2
echo "Resultado completo en: $BENCH_OUT" >&2
cat "$BENCH_OUT"
