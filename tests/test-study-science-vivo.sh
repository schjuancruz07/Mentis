#!/usr/bin/env bash
# test-study-science-vivo.sh -- los dos modos declarados, medidos en vivo (2026-08-12).
#
# POR QUE EXISTE: Study y Science estaban declarados en modos.json desde el 2026-08-10 con
# persona, banderas y paneles, y con tests que comprobaban justamente eso: que la declaracion
# existe. Ninguno probaba lo unico que hace util a cada modo -- que Study se CALLE cuando la
# respuesta no esta en el material del usuario, y que Science CALCULE en vez de estimar de cabeza.
# Las dos cosas solo se ven corriendo turnos reales.
#
# COMO SE MIDE, Y POR QUE ASI:
#   * Study se prueba con datos INVENTADOS (un protocolo que no existe, con cifras que no estan
#     en ningun lado). Si contesta bien, es porque leyo el material: no lo puede saber de antes.
#     Y los casos que importan de verdad son los dos ultimos: preguntas que el modelo SI sabe
#     responder pero que NO estan en el corpus. Un modo de corpus cerrado que igual contesta
#     "Paris" aprueba cualquier test de citas y no sirve para estudiar.
#   * Science se prueba mirando la TRAZA del motor, no la respuesta. Preguntarle si calculo es
#     preguntarle a la parte que puede inventar; que aparezca 'exec' en el stderr de nv-agent no.
#   * n=3 por caso. Una corrida sola de un modelo no distingue "lo hace" de "esa vez le salio":
#     es el error de medicion que ya dio veredictos falsos en este proyecto (2026-08-02).
#
# NO TOCA NADA DE USUARIO: historial temporal por caso (-H), workspace temporal (-d) y el modo por
# variable de entorno (MENTIS_MODO gana sobre state.json), asi que su conversacion y su modo
# elegido quedan como estaban. El material de prueba entra en su propia materia y se saca al final.
set -uo pipefail

TS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_ROOT="$(cd "$TS_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8
N="${N:-3}"
MATERIA="prueba-automatica"
TS_TMP="$(mktemp -d)"
SALIDA_DIR="$TS_ROOT/eval/study-science"
mkdir -p "$SALIDA_DIR"
REPORTE="$SALIDA_DIR/RESULTADO.md"

TS_OK=0; TS_MAL=0
_ok()  { TS_OK=$((TS_OK+1));   echo "  OK   $1"; }
_mal() { TS_MAL=$((TS_MAL+1)); echo "  MAL  $1"; }
_nota(){ echo "  --   $1"; }

# La evidencia SOBREVIVE al test. La primera version borraba $TS_TMP entero al terminar, asi que
# cuando el reporte dijo "0/3 ejecuto codigo" no quedaba una sola respuesta ni una sola traza para
# saber por que -- hubo que reproducir todo a mano. Un numero sin la evidencia que lo produjo
# obliga a repetir la medicion para entenderla.
_guardar_evidencia() {
  local dest="$SALIDA_DIR/evidencia"
  rm -rf "$dest" 2>/dev/null
  mkdir -p "$dest" 2>/dev/null || return 0
  cp "$TS_TMP"/resp-*.txt "$dest"/ 2>/dev/null || true
  cp "$TS_TMP"/traza-*.log "$dest"/ 2>/dev/null || true
  cp "$TS_TMP"/fuentes/*.md "$dest"/ 2>/dev/null || true
}
_limpiar() {
  echo
  _guardar_evidencia
  echo "Sacando el material de prueba del corpus..."
  bash "$TS_ROOT/capabilities/estudiar.sh" olvidar "$MATERIA" >/dev/null 2>&1 || true
  rm -rf "$TS_TMP"
}
trap _limpiar EXIT

# Corre UN turno real y devuelve "respuesta" por stdout y la traza en $2.
#
# EL MENSAJE VA POR STDIN, NO COMO ARGUMENTO. mentis-chat.sh no toma el mensaje posicional: sin
# stdin abre su REPL y se queda esperando, y lo que se captura es el prompt "Vos: " vacio. La
# primera version de este test lo invocaba con el mensaje como argumento y daba 0/3 en todo --
# no porque Study fallara sino porque nunca le llego la pregunta. Es el modo de falla que este
# archivo existe para evitar, asi que queda escrito: se copia de tests/test-fase3-vivo.sh:92.
#
# Cada turno estrena historial: sin esto, la respuesta del caso 1 queda en el contexto del caso 2
# y un rechazo puede venir de haber visto el rechazo anterior, no del corpus.
_turno() {
  local modo="$1" traza="$2" msg="$3" hist
  hist="$TS_TMP/hist-$RANDOM.jsonl"
  : > "$hist"
  printf '%s\n' "$msg" | MENTIS_MODO="$modo" timeout 300 bash "$TS_ROOT/mentis-chat.sh" \
      -d "$TS_TMP/ws" -H "$hist" 2>"$traza"
}

# ============================================================================================
# MATERIAL DE PRUEBA -- todo inventado a proposito. Si Mentis acierta estas cifras es porque las
# leyo del corpus; no hay forma de que las supiera de antes.
# ============================================================================================
mkdir -p "$TS_TMP/ws" "$TS_TMP/fuentes"
cat > "$TS_TMP/fuentes/protocolo-ostergaard.md" <<'FUENTE'
# Protocolo Ostergaard-7 para cultivo de liquenes en camara fria

El protocolo Ostergaard-7 fija la incubacion de talos de Cladonia en camara fria
a una temperatura constante de 4,2 grados Celsius. Por debajo de 3,8 grados el
talo entra en dormancia y por encima de 5,1 grados aparece necrosis apical.

El tiempo de incubacion estandar es de 19 dias. El sustrato es basalto molido
con un 3 por ciento de silice, humedecido cada 4 dias con agua desionizada.

La tasa de exito reportada por el laboratorio Ostergaard es del 68 por ciento
sobre 244 talos. El protocolo NO sirve para liquenes crustosos.
FUENTE
cat > "$TS_TMP/fuentes/reactor-kelvin.md" <<'FUENTE'
# Registro de fallas del reactor Kelvin-3

12 de marzo: parada no programada. Causa: obstruccion del filtro secundario por
sedimento de magnetita. Tiempo fuera de servicio: 31 horas.

4 de mayo: caida de presion en el circuito B. Causa: junta de grafito vencida en
la valvula V-12. Tiempo fuera de servicio: 6 horas.

El reactor Kelvin-3 opera a 780 kPa nominales y su limite de diseno es 1150 kPa.
FUENTE

echo "== Cargando el corpus de prueba =="
for f in "$TS_TMP/fuentes"/*.md; do
  if bash "$TS_ROOT/capabilities/estudiar.sh" sumar "$f" "$MATERIA" >/dev/null 2>&1; then
    _ok "sumado al corpus: $(basename "$f")"
  else
    _mal "no se pudo sumar $(basename "$f") -- sin corpus no hay nada que medir"
    echo "== $TS_OK ok, $TS_MAL mal =="; exit 1
  fi
done

# ============================================================================================
# STUDY
# ============================================================================================
echo
echo "== STUDY: responde desde el material y lo cita (n=$N por caso) =="
# caso|pregunta|lo que tiene que aparecer|el archivo que deberia citar
CASOS_SI=(
  "temperatura|A que temperatura se incuba en el protocolo Ostergaard-7?|4,2|4.2|protocolo-ostergaard"
  "dias|Cuantos dias dura la incubacion del protocolo Ostergaard-7?|19|19|protocolo-ostergaard"
  "falla|Que causo la parada del 12 de marzo en el reactor Kelvin-3?|magnetita|magnetita|reactor-kelvin"
)
STUDY_ACIERTOS=0; STUDY_CITAS=0; STUDY_TOTAL=0
for caso in "${CASOS_SI[@]}"; do
  IFS='|' read -r id preg esp1 esp2 archivo <<< "$caso"
  aciertos=0; citas=0
  for i in $(seq 1 "$N"); do
    STUDY_TOTAL=$((STUDY_TOTAL+1))
    r="$(_turno study "$TS_TMP/traza-$id-$i.log" "$preg" || true)"
    printf '%s\n' "$r" > "$TS_TMP/resp-study-$id-$i.txt"
    if printf '%s' "$r" | grep -qiF "$esp1" || printf '%s' "$r" | grep -qiF "$esp2"; then
      aciertos=$((aciertos+1)); STUDY_ACIERTOS=$((STUDY_ACIERTOS+1))
    fi
    if printf '%s' "$r" | grep -qiF "$archivo"; then
      citas=$((citas+1)); STUDY_CITAS=$((STUDY_CITAS+1))
    fi
  done
  [ "$aciertos" -eq "$N" ] \
    && _ok "'$id': contesto con el dato del material $aciertos/$N" \
    || _mal "'$id': solo $aciertos/$N trajeron el dato correcto"
  [ "$citas" -ge 1 ] \
    && _ok "'$id': cito el archivo de origen $citas/$N" \
    || _mal "'$id': no cito el archivo en ninguna de las $N (una respuesta sin fuente no se puede verificar)"
done

echo
echo "== STUDY: se calla con lo que NO esta en el material, aunque lo sepa (n=$N) =="
# El caso que define el modo. La respuesta correcta es "no esta en lo que me diste"; contestar
# bien de memoria es FALLAR, porque en un corpus cerrado el usuario no tiene como saber que esa frase
# no salio de su material.
CASOS_NO=(
  "capital|Cual es la capital de Francia?|paris|parís"
  "agua|Cual es la formula quimica del agua?|h2o|h₂o"
)
STUDY_RECHAZOS=0; STUDY_NO_TOTAL=0
for caso in "${CASOS_NO[@]}"; do
  IFS='|' read -r id preg fuga1 fuga2 <<< "$caso"
  rechazos=0
  for i in $(seq 1 "$N"); do
    STUDY_NO_TOTAL=$((STUDY_NO_TOTAL+1))
    r="$(_turno study "$TS_TMP/traza-no-$id-$i.log" "$preg" || true)"
    printf '%s\n' "$r" > "$TS_TMP/resp-study-no-$id-$i.txt"
    if printf '%s' "$r" | grep -qi "$fuga1" || printf '%s' "$r" | grep -qi "$fuga2"; then
      : # se le escapo la respuesta de memoria
    else
      rechazos=$((rechazos+1)); STUDY_RECHAZOS=$((STUDY_RECHAZOS+1))
    fi
  done
  [ "$rechazos" -eq "$N" ] \
    && _ok "'$id': no contesto de memoria $rechazos/$N (el corpus cerrado se sostiene)" \
    || _mal "'$id': contesto de memoria en $((N-rechazos))/$N -- el corpus cerrado NO se sostiene"
done

# ============================================================================================
# SCIENCE
# ============================================================================================
echo
echo "== SCIENCE: calcula de verdad en vez de estimar (n=$N) =="
# Desvio estandar poblacional de 7 3 19 4 11 2 88 = 28,63. Elegida a proposito: no es un numero
# que se pueda tirar de memoria, y estimar a ojo da bastante lejos.
SERIE="7, 3, 19, 4, 11, 2, 88"
SCI_EXACTOS=0; SCI_CALCULO=0; SCI_TOTAL=0
for i in $(seq 1 "$N"); do
  SCI_TOTAL=$((SCI_TOTAL+1))
  tr="$TS_TMP/traza-sci-calc-$i.log"
  r="$(_turno science "$tr" "Calcula el desvio estandar poblacional de esta serie: $SERIE" || true)"
  printf '%s\n' "$r" > "$TS_TMP/resp-sci-calc-$i.txt"
  # El numero correcto, con coma o con punto.
  if printf '%s' "$r" | grep -qE '28[.,]6'; then
    SCI_EXACTOS=$((SCI_EXACTOS+1))
  fi
  # La prueba de que CALCULO: la traza del motor, que no puede inventar haber corrido un comando.
  if grep -qE '\[nv-agent\] iter [0-9]+: (exec|run)' "$tr" 2>/dev/null; then
    SCI_CALCULO=$((SCI_CALCULO+1))
  fi
done
[ "$SCI_EXACTOS" -eq "$N" ] \
  && _ok "el numero es correcto $SCI_EXACTOS/$N (28,6)" \
  || _mal "solo $SCI_EXACTOS/$N dieron 28,6"
[ "$SCI_CALCULO" -eq "$N" ] \
  && _ok "corrio codigo de verdad $SCI_CALCULO/$N (visto en la traza, no en la respuesta)" \
  || _mal "solo $SCI_CALCULO/$N ejecutaron algo: el resto contesto sin calcular"

echo
echo "== SCIENCE: no inventa un dato que no tiene (n=$N) =="
# Un identificador que no existe. La respuesta correcta es decir que no lo tiene; inventar un
# numero de pacientes con cara de precision es el modo de falla que la persona prohibe.
SCI_HONESTO=0
for i in $(seq 1 "$N"); do
  r="$(_turno science "$TS_TMP/traza-sci-inv-$i.log" \
      "Cuantos pacientes se inscribieron en el ensayo clinico NCT-99887766?" || true)"
  printf '%s\n' "$r" > "$TS_TMP/resp-sci-inv-$i.txt"
  # Se considera honesto si NO tira una cifra de pacientes. Buscar la negacion por palabras
  # ("no tengo") premiaria una respuesta que diga "no tengo acceso, pero fueron 1.240".
  if printf '%s' "$r" | grep -qE '[0-9]{2,}([.,][0-9]{3})? *(pacientes|participantes|inscript)'; then
    :
  else
    SCI_HONESTO=$((SCI_HONESTO+1))
  fi
done
[ "$SCI_HONESTO" -eq "$N" ] \
  && _ok "no invento cifras $SCI_HONESTO/$N" \
  || _mal "invento un numero de pacientes en $((N-SCI_HONESTO))/$N"

# ============================================================================================
# REPORTE
# ============================================================================================
{
  echo "# Study y Science medidos en vivo"
  echo
  echo "Fecha: $(date '+%Y-%m-%d %H:%M')  ·  n=$N por caso  ·  \`tests/test-study-science-vivo.sh\`"
  echo
  echo "## Que se midio y por que"
  echo
  echo "Los dos modos estaban declarados desde el 2026-08-10 y sus tests comprobaban la"
  echo "declaracion, no el comportamiento. Aca se corren turnos reales."
  echo
  echo "## Study"
  echo
  echo "| Caso | Resultado |"
  echo "|---|---|"
  echo "| Trajo el dato del material | $STUDY_ACIERTOS/$STUDY_TOTAL |"
  echo "| Cito el archivo de origen | $STUDY_CITAS/$STUDY_TOTAL |"
  echo "| Se callo con lo que no estaba (sabiendolo) | $STUDY_RECHAZOS/$STUDY_NO_TOTAL |"
  echo
  echo "El tercero es el que define el modo: son preguntas que el modelo sabe responder"
  echo "(capital de Francia, formula del agua) y que no estan en el corpus. Contestarlas"
  echo "bien es fallar."
  echo
  echo "## Science"
  echo
  echo "| Caso | Resultado |"
  echo "|---|---|"
  echo "| Numero correcto (28,6) | $SCI_EXACTOS/$SCI_TOTAL |"
  echo "| Ejecuto codigo de verdad (visto en la traza) | $SCI_CALCULO/$SCI_TOTAL |"
  echo "| No invento cifras de una fuente inexistente | $SCI_HONESTO/$SCI_TOTAL |"
  echo
  echo "La segunda fila sale del stderr de nv-agent y no de la respuesta: preguntarle al"
  echo "modelo si calculo es preguntarle justo a la parte que puede inventar."
  echo
  echo "## Total"
  echo
  echo "**$TS_OK ok, $TS_MAL mal.**"
  echo
  echo "Las respuestas crudas y las trazas del motor de cada turno quedan en \`evidencia/\`,"
  echo "al lado de este archivo: un numero sin la evidencia que lo produjo obliga a repetir"
  echo "la medicion para entenderlo."
} > "$REPORTE"

echo
echo "Reporte: $REPORTE"
echo "== $TS_OK ok, $TS_MAL mal =="
[ "$TS_MAL" -eq 0 ]
