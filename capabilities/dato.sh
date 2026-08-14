# CAPABILITY: /dato | busca un dato científico REAL y te dice de dónde salió: constantes de física (CODATA/NIST), proteínas y genes (UniProt), y compuestos químicos (PubChem). "/dato velocidad de la luz", "/dato proteina hemoglobina", "/dato gen BRCA1". Si no lo tiene, lo dice en vez de inventarlo.
#
# POR QUE EXISTE (2026-08-13): el modo Science ya dibujaba estructuras con geometria medida, pero
# para cualquier otro dato -- una constante, una proteina, un gen -- dependia de lo que el modelo
# recordara. Y "lo que el modelo recuerda" es justo lo que este modo promete no usar: una cifra
# con cara de precision y sin fuente es peor que no responder.
#
# LAS TRES FUENTES, Y POR QUE ESAS:
#   fisica    -> CODATA 2022 (NIST). Tabla local: son numeros definidos por convenio internacional
#                que no cambian entre consultas, y NIST no publica un JSON oficial que consultar.
#   biologia  -> UniProt en vivo (EMBL-EBI / SIB / PIR). Cada respuesta trae su accession, asi que
#                se puede ir a verificarla.
#   quimica   -> PubChem, via capabilities/estructura.sh, que ademas la dibuja en 3D.
#
# SIEMPRE DEVUELVE LA FUENTE. Un dato cientifico sin procedencia no se puede verificar, y en un
# modo que promete no inventar eso lo vuelve inutil: quien lo lee no tiene como distinguirlo de
# algo recordado a medias.
set -uo pipefail
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUE="${*:-}"

if [ -z "${QUE// }" ]; then
  cat <<'AYUDA'
/dato -- un dato científico con su fuente.

  /dato velocidad de la luz        una constante física (CODATA/NIST)
  /dato constante de planck        idem; probá también: avogadro, boltzmann, gravedad...
  /dato proteina hemoglobina       una proteína (UniProt): gen, tamaño y función
  /dato gen BRCA1                  qué proteína produce ese gen
  /dato molecula cafeina           un compuesto químico, y te lo dibuja en 3D

Siempre te digo de dónde salió. Si no lo tengo, te lo digo en vez de inventarlo.
AYUDA
  exit 0
fi

_primera_palabra="$(printf '%s' "$QUE" | awk '{print tolower($1)}')"
_resto="$(printf '%s' "$QUE" | cut -d' ' -f2-)"

case "$_primera_palabra" in
  proteina|proteína|protein)
    MODO="proteina"; CONSULTA="$_resto" ;;
  gen|gene)
    MODO="gen"; CONSULTA="$_resto" ;;
  molecula|molécula|compuesto|quimica|química)
    # La quimica ya tiene su capacidad, que ademas la dibuja: se delega en vez de duplicarla.
    exec bash "$HERE/capabilities/estructura.sh" "$_resto" ;;
  *)
    MODO="constante"; CONSULTA="$QUE" ;;
esac

JSON="$(python3 "$HERE/engine/ciencia_datos.py" "$MODO" "$CONSULTA" 2>&1)"; RC=$?

printf '%s' "$JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('No pude leer la respuesta de la fuente.'); sys.exit(1)

if not d.get('ok'):
    print(d.get('error', 'no encontré ese dato'))
    if d.get('disponibles'):
        print('Constantes que sí tengo: ' + ', '.join(d['disponibles']))
    sys.exit(1)

if 'simbolo' in d:
    print(f\"{d['simbolo']} = {d['valor']} {d['unidad']}\")
    print(f\"Incertidumbre: {d['incertidumbre']}\")
    print(f\"Fuente: {d['fuente']}\")
else:
    for r in d['resultados'][:2]:
        print(f\"{r['proteina']}\")
        if r.get('genes'): print(f\"  Gen: {', '.join(r['genes'])}\")
        print(f\"  Tamaño: {r['aminoacidos']} aminoácidos  ·  {r['organismo']}\")
        if r.get('funcion'): print(f\"  Función: {r['funcion'][:260]}\")
        print(f\"  Ficha: {r['ficha']}\")
        print()
    print(f\"Fuente: {d['fuente']}\")
"
exit $RC
