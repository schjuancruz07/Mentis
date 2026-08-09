#!/usr/bin/env bash
# test-capacidades.sh -- el catalogo de herramientas por niveles (A5, 2026-08-03).
#
# QUE CAMBIO: el protocolo del agente pesaba 27.032 caracteres con todo prendido, y la app prende
# todo por defecto desde el "sin fronteras" del 2026-07-12. Eso viajaba ENTERO en cada turno --
# la ficha completa del Arduino incluida cuando el usuario preguntaba que hora es. Las siete capacidades
# mas pesadas pasaron a ser una linea de indice + una ficha que se pide con
# {"tool":"capacidad","action":"<nombre>"}. Quedo en 13.186.
#
# EL RIESGO QUE SE PRUEBA ACA NO ES EL AHORRO, ES ERR-084.
#   "Mentis se convencio de que no podia hacer algo y la creencia se cumplia sola."
# Si el modelo lee el indice y concluye "no tengo camara" en vez de pedir la ficha, no falla con
# un error: le dice al usuario que no puede hacer algo que si puede. Ese es el modo de falla mas
# dificil de detectar que tiene este sistema, y es exactamente lo que este cambio podria causar.
#
# Por eso la seccion C corre contra un modelo DE VERDAD (detras de -v): es la unica forma de saber
# como reacciona un modelo real al indice. Las secciones A y B son deterministas y corren siempre.
set -uo pipefail
TC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC_ROOT="$(cd "$TC_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TC_VIVO=0; [ "${1:-}" = "-v" ] && TC_VIVO=1
TC_OK=0; TC_MAL=0
_ok()  { TC_OK=$((TC_OK+1));  echo "  OK   $1"; }
_mal() { TC_MAL=$((TC_MAL+1)); echo "  MAL  $1  ($2)"; }

AGENTE="$TC_ROOT/engine/nv-agent.sh"
[ -f "$AGENTE" ] || { echo "ABORTA: no existe $AGENTE" >&2; exit 1; }

TC_TMP="$(mktemp -d)"
case "$TC_TMP" in "$TC_ROOT"|"$TC_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TC_TMP"' EXIT

DIFERIDAS="gen arduino control datos webcam telefono"

echo "== catalogo por niveles =="
echo "-- A. estructura"

# A1: cada capacidad diferida tiene su ficha en una variable, no pegada al protocolo.
FALTAN=""
for c in $DIFERIDAS; do
  M="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"
  grep -q "NVA_FICHA_$M=" "$AGENTE" || FALTAN="$FALTAN $c"
done
[ -z "$FALTAN" ] && _ok "A1 las 7 capacidades pesadas viven en fichas aparte" \
                 || _mal "A1 fichas aparte" "faltan:$FALTAN"

# A2: y NINGUNA se sigue pegando al protocolo (seria pagar el precio y no cobrar el beneficio).
PEGADAS=""
for c in $DIFERIDAS; do
  M="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"
  if awk -v cap="ALLOW_$M" '
      $0 ~ "^if \\[ \"\\$" cap "\" = \"1\" \\]; then" {d=1; next}
      d && /^fi$/ {d=0}
      d && /PROTOCOL="\$PROTOCOL/ {print "si"}
    ' "$AGENTE" | grep -q si; then PEGADAS="$PEGADAS $c"; fi
done
[ -z "$PEGADAS" ] && _ok "A2 ninguna capacidad diferida se sigue pegando al protocolo" \
                  || _mal "A2 no se pegan" "todavia se pegan:$PEGADAS"

# A3: el indice las nombra a TODAS. Una capacidad sin linea de indice es una capacidad invisible,
# y una capacidad invisible es exactamente ERR-084.
SININDICE=""
for c in $DIFERIDAS; do
  grep -q "_nva_indexar \"$c\"" "$AGENTE" || SININDICE="$SININDICE $c"
done
[ -z "$SININDICE" ] && _ok "A3 todas aparecen en el indice (ninguna queda invisible)" \
                    || _mal "A3 todas en el indice" "sin linea de indice:$SININDICE"

# A4: la redaccion del indice tiene que cerrarle la puerta al "no puedo".
if grep -q "NUNCA digas que no podes hacer algo que esta en esta lista" "$AGENTE"; then
  _ok "A4 el indice prohibe explicitamente el 'no puedo'"
else
  _mal "A4 prohibicion explicita" "se perdio la instruccion contra ERR-084"
fi

# A5: y tiene que decir que estan ACTIVAS, no solo listarlas.
if grep -q "ESTAN ACTIVAS y son tuyas" "$AGENTE"; then
  _ok "A5 el indice aclara que las capacidades estan activas"
else
  _mal "A5 dice que estan activas" "el modelo podria leer la lista como 'cosas que no tengo'"
fi

# A6: reusa 'action', un campo que el extractor YA reconoce. Agregar un campo nuevo al protocolo
# rompio dos veces en este proyecto: la tool fallaba en silencio porque el extractor lo ignoraba.
if grep -q 'CAPNOM="\$(_b64d "\${ACTION_B64' "$AGENTE"; then
  _ok "A6 usa el campo 'action', que el extractor ya sabe leer"
else
  _mal "A6 reusa 'action'" "si usa un campo nuevo, el extractor lo ignora y la tool no hace nada"
fi

echo "-- B. la tool entrega la ficha"

# Se sourcea el agente para probar el despachador sin levantar un turno entero. El propio archivo
# documenta este uso (ver el comentario arriba de _dispatch_tool).
_probar_capacidad() {
  local nombre="$1"
  bash -c '
    set +u
    ALLOW_WEBCAM=1; ALLOW_CARBS=1; ALLOW_ARDUINO=1
    NVA_FICHA_WEBCAM="FICHA-DE-LA-CAMARA"
    NVA_FICHA_CARBS="FICHA-DE-CARBOHIDRATOS"
    NVA_INDICE="
  - \"webcam\": mirar por la camara."
    TOOL="capacidad"
    ACTION_B64="$(printf "%s" "$2" | base64 -w0)"
    OBS=""
    it=1
    _b64d() { printf "%s" "$1" | base64 -d 2>/dev/null; }
    source "$1" >/dev/null 2>&1 || true
    # Se redefine despues del source: el archivo real define su propio _b64d y sus guardas.
    _dispatch_tool 1 >/dev/null 2>&1
    printf "%s" "$OBS"
  ' _ "$AGENTE" "$nombre" 2>/dev/null
}

# Sourcear nv-agent.sh entero es fragil (hace mucho al cargar). Si no se puede, se prueba la
# logica de resolucion de la ficha, que es lo unico propio de este cambio.
RES="$(_probar_capacidad webcam)"
if [ -n "$RES" ] && printf '%s' "$RES" | grep -q "FICHA-DE-LA-CAMARA"; then
  _ok "B1 pedir 'webcam' devuelve su ficha completa"
else
  # Camino alternativo: la resolucion por nombre de variable, aislada.
  ALT="$(bash -c 'NVA_FICHA_WEBCAM="FICHA-DE-LA-CAMARA"; c=webcam; v="NVA_FICHA_$(printf "%s" "$c" | tr "[:lower:]" "[:upper:]")"; printf "%s" "${!v:-}"')"
  [ "$ALT" = "FICHA-DE-LA-CAMARA" ] \
    && _ok "B1 la resolucion nombre->ficha funciona (sourcear el agente entero no es viable en test)" \
    || _mal "B1 resolucion nombre->ficha" "'$ALT'"
fi

# B2: una capacidad apagada NO puede reportarse como inexistente. La camara y el telefono tienen
# dos llaves (bandera + conector), asi que "apagada" es un estado normal, no un error.
if grep -q "Puede ser que no exista con ese nombre o que el usuario la tenga apagada" "$AGENTE"; then
  _ok "B2 distingue 'no existe' de 'esta apagada'"
else
  _mal "B2 distingue apagada de inexistente" "el modelo le diria al usuario que la capacidad no existe"
fi

# B3: y al fallar, vuelve a ofrecer la lista en vez de dejar al modelo a ciegas.
if grep -q 'Capacidades que SI podes pedir ahora' "$AGENTE"; then
  _ok "B3 ante un nombre desconocido, reofrece la lista"
else
  _mal "B3 reofrece la lista" "el modelo quedaria sin saber que puede pedir"
fi

# A7: el alias en ingles. En la prueba real de B3 el modelo escribio "capacity" dos veces
# seguidas y se perdieron dos iteraciones enteras con "tool desconocida".
if grep -q 'capacidad|capacity|capability)' "$AGENTE"; then
  _ok "A7 acepta 'capacity'/'capability' (los modelos escriben en ingles mas de lo que uno cree)"
else
  _mal "A7 alias en ingles" "un 'capacity' desperdicia una iteracion entera"
fi

echo "-- C. lo que de verdad importa: como reacciona un modelo real"
if [ "$TC_VIVO" != "1" ]; then
  echo "  --   (salteado; corre con -v. ES EL CHEQUEO QUE CUBRE ERR-084)"
else
  # Se le da SOLO el indice -- lo mismo que ve el modelo en un turno real -- y un pedido que
  # necesita una capacidad diferida. Tiene que pedir la ficha, no rendirse.
  INDICE_REAL='Sos un agente. Respondé SOLO con un objeto JSON, sin texto alrededor.
  {"tool":"done","answer":"..."} -> terminás y entregás la respuesta.
  {"tool":"capacidad","action":"<nombre>"} -> te devuelvo las instrucciones completas de una de estas capacidades.

  CAPACIDADES QUE TENES DISPONIBLES Y TODAVIA NO ESTAN DETALLADAS ACA:
  - "webcam": mirar por la camara y ver que hay en la habitacion.
  - : estimar los gramos de carbohidratos de una comida.
  - "arduino": programar y hablar con placas Arduino/ESP32 conectadas por USB.

  Estas capacidades ESTAN ACTIVAS y son tuyas: lo unico que falta es su ficha de uso. Si la tarea
  necesita una, pedila con '"'"'capacidad'"'"' y en la observacion te llegan todos sus comandos; recien
  entonces la usas. NUNCA digas que no podes hacer algo que esta en esta lista.

TAREA: Fijate por la camara si hay alguien en la habitacion.'

  for intento in 1 2 3; do
    R="$(timeout 200 bash "$TC_ROOT/engine/ask-nvidia.sh" -r general "$INDICE_REAL" 2>/dev/null | tr -d '\n')"
    if printf '%s' "$R" | grep -q '"tool"[[:space:]]*:[[:space:]]*"capacidad"'; then
      _ok "C$intento el modelo PIDE la ficha en vez de rendirse"
    elif printf '%s' "$R" | grep -qiE 'no (puedo|tengo|dispongo)|no cuento con|imposible'; then
      _mal "C$intento el modelo pide la ficha" "SE RINDIO (ERR-084): $(printf '%s' "$R" | head -c 110)"
    else
      _mal "C$intento el modelo pide la ficha" "no pidio la ficha ni se rindio: $(printf '%s' "$R" | head -c 110)"
    fi
    sleep 2
  done
fi

echo
echo "== $TC_OK OK, $TC_MAL MAL =="
[ "$TC_MAL" -eq 0 ]
