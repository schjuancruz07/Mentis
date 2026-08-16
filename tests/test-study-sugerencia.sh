#!/usr/bin/env bash
# test-study-sugerencia.sh -- que el modo Study OFREZCA los nueve formatos de /material sin
# depender de que el modelo se acuerde.
#
# QUE SE PRUEBA (2026-08-15): los nueve formatos existen desde el 2026-08-12, pero se ofrecian
# unicamente desde la persona del modo en modos.json. En uso real aparecian a veces si y a veces
# no. Nueve formatos que el usuario no sabe que existen son nueve formatos que no existen.
#
# LO QUE ESTE TEST NO HACE, Y ES LO IMPORTANTE: no comprueba una copia del mecanismo. La funcion
# se toma de la libreria real (engine/nv-modos-lib.sh) y el enganche se EXTRAE de mentis-chat.sh
# con awk y se corre tal cual. Un test contra una copia aprueba codigo que ya no es el que corre
# (ERR-130, ya pasado en este proyecto).
#
# LA MITAD DE LOS CASOS SON NEGATIVOS a proposito. Una sugerencia que aparece siempre es una firma
# pegada al pie de cada respuesta, y una firma se deja de leer a los tres dias. Lo dificil de esto
# no es que aparezca: es que NO aparezca cuando no corresponde.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$HERE/engine/nv-modos-lib.sh"
CHAT="$HERE/mentis-chat.sh"
REGLAS="$HERE/study-sugerencias.json"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== reglas =="
if [ -f "$REGLAS" ]; then _ok "existe study-sugerencias.json"; else _mal "existe study-sugerencias.json" "no esta"; fi

# El JSON tiene que ser valido Y sus formatos tienen que ser de los nueve que /material acepta.
# Una regla con formato inventado ofreceria una linea que despues no hace nada, que es peor que
# no ofrecer: manda al usuario a escribir un comando que le va a contestar con un error.
VALIDOS="audio video presentacion informe tabla mapa tarjetas cuestionario infografia"
MALOS="$(REGLAS="$REGLAS" VALIDOS="$VALIDOS" node -e '
  const fs = require("fs");
  const d = JSON.parse(fs.readFileSync(process.env.REGLAS, "utf8"));
  const ok = new Set(process.env.VALIDOS.split(" "));
  const malos = [];
  for (const r of (d.reglas || [])) {
    if (!ok.has(r.formato)) malos.push("formato desconocido: " + r.formato);
    if (!r.linea || !r.linea.includes("/material " + r.formato)) malos.push("la linea de " + r.formato + " no nombra su propio comando");
    if (!(r.frases || []).length) malos.push("la regla de " + r.formato + " no tiene frases");
  }
  process.stdout.write(malos.join(" | "));
' 2>&1)"
if [ -z "${MALOS// }" ]; then _ok "las 9 reglas apuntan a formatos reales de /material"; else _mal "reglas coherentes" "$MALOS"; fi

echo "== la funcion (de la libreria real) =="
# shellcheck source=/dev/null
source "$LIB"
if declare -f nv_study_sugerencia >/dev/null; then _ok "nv_study_sugerencia existe en la libreria"; else _mal "nv_study_sugerencia existe" "no esta en $LIB"; fi

_caso() { # _caso <nombre> <esperado: linea|vacio> <modo> <mensaje> <respuesta>
  local nombre="$1" esperado="$2" modo="$3" msg="$4" resp="$5" out
  out="$(nv_study_sugerencia "$modo" "$msg" "$resp" 2>/dev/null || true)"
  if [ "$esperado" = "vacio" ]; then
    [ -z "${out// }" ] && _ok "$nombre" || _mal "$nombre" "esperaba nada y devolvio: $out"
  else
    case "$out" in
      *"/material $esperado"*) _ok "$nombre" ;;
      *) _mal "$nombre" "esperaba /material $esperado y devolvio: [$out]" ;;
    esac
  fi
}

# POSITIVOS: el mensaje trae una intencion que un formato resuelve.
_caso "un parcial pide cuestionario"          cuestionario  study "tengo un parcial el viernes de fotosintesis" "La fotosintesis es el proceso..."
_caso "memorizar fechas pide tarjetas"        tarjetas      study "no me acuerdo nunca las fechas"             "Las fechas principales son..."
_caso "viajando pide audio"                   audio         study "manana lo repaso en el colectivo"           "Te resumo el tema..."
_caso "exponer pide presentacion"             presentacion  study "necesito exponer esto en clase"             "El tema se divide en..."
_caso "comparar pide tabla"                   tabla         study "quiero comparar los dos procesos"           "Se diferencian en..."
# Los acentos no pueden decidir si una funcion del producto existe o no: el usuario escribe
# "presentación" y "presentacion" el mismo dia.
_caso "matchea con acentos"                   presentacion  study "tengo que hacer una presentación"           "Dale, el tema es..."
_caso "matchea con mayusculas"                cuestionario  study "TENGO PARCIAL EL LUNES"                     "Repasemos..."

echo "== los negativos (lo dificil) =="
# Si el modelo ya lo ofrecio, agregarlo de nuevo delata la costura: el usuario leeria dos ofrecimientos
# del mismo formato, uno escrito y otro pegado.
_caso "no repite si el modelo ya lo ofrecio"  vacio study "tengo un parcial" "Podes pedirme /material cuestionario fotosintesis"
_caso "no aparece fuera de Study"             vacio mentis "tengo un parcial el viernes" "Bueno..."
_caso "no aparece fuera de Study (code)"      vacio code   "tengo un parcial el viernes" "Bueno..."
_caso "una pregunta comun no dispara nada"    vacio study "que es la mitosis"            "La mitosis es la division celular..."
_caso "un saludo no dispara nada"             vacio study "hola"                         "Hola! En que te ayudo?"

OUT_OFF="$(MENTIS_SUGERENCIA_OFF=1 nv_study_sugerencia study "tengo un parcial" "bla" 2>/dev/null || true)"
if [ -z "${OUT_OFF// }" ]; then _ok "MENTIS_SUGERENCIA_OFF=1 la apaga"; else _mal "MENTIS_SUGERENCIA_OFF" "devolvio: $OUT_OFF"; fi

# CORPUS VACIO: ofrecerle convertir material que no cargo lo manda contra una pared -- /material le
# contestaria "de ese tema no hay nada", y el ofrecimiento habria salido del propio Mentis.
TMPRAIZ="$(mktemp -d)"
cp "$HERE/modos.json" "$TMPRAIZ/" 2>/dev/null
cp "$REGLAS" "$TMPRAIZ/" 2>/dev/null
mkdir -p "$TMPRAIZ/knowledge/estudio"
OUT_VACIO="$( MENTIS_ROOT="$TMPRAIZ" bash -c '
  source "$1/engine/nv-modos-lib.sh"
  nv_study_sugerencia study "tengo un parcial" "bla" 2>/dev/null || true
' _ "$HERE" )"
if [ -z "${OUT_VACIO// }" ]; then _ok "con el corpus vacio no ofrece nada"; else _mal "corpus vacio" "devolvio: $OUT_VACIO"; fi
rm -rf "$TMPRAIZ"

echo "== el enganche REAL de mentis-chat.sh =="
BLOQUE="$(mktemp)"
awk '/# OFRECER LOS FORMATOS DE \/material EN STUDY/,/^  fi$/' "$CHAT" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 10 ]; then
  _mal "se puede extraer el enganche" "no se encontro en $CHAT"
else
  _ok "el enganche se extrae de mentis-chat.sh ($(wc -l < "$BLOQUE") lineas)"

  # Se corre el bloque de verdad, con las variables que tendria en un turno real.
  MODO_REMOTO=0; MC_MODO="study"; MSG="tengo un parcial el viernes"; ANSWER="La fotosintesis es un proceso."
  # shellcheck source=/dev/null
  source "$BLOQUE"
  case "$ANSWER" in
    *"La fotosintesis es un proceso."*"/material cuestionario"*) _ok "el turno real termina con la sugerencia pegada" ;;
    *) _mal "el turno real pega la sugerencia" "quedo: [$ANSWER]" ;;
  esac

  # Desde el telefono el modo no puede ejecutar /material: ofrecerlo ahi es peor que callarse.
  MODO_REMOTO=1; MC_MODO="study"; MSG="tengo un parcial el viernes"; ANSWER="La fotosintesis es un proceso."
  # shellcheck source=/dev/null
  source "$BLOQUE"
  case "$ANSWER" in
    *"/material"*) _mal "en remoto no ofrece" "quedo: [$ANSWER]" ;;
    *) _ok "en remoto no ofrece nada" ;;
  esac

  # La respuesta original no se toca nunca: la sugerencia se SUMA al final, no reemplaza.
  MODO_REMOTO=0; MC_MODO="study"; MSG="que es la mitosis"; ANSWER="La mitosis es la division celular."
  # shellcheck source=/dev/null
  source "$BLOQUE"
  if [ "$ANSWER" = "La mitosis es la division celular." ]; then
    _ok "sin match, la respuesta queda intacta"
  else
    _mal "sin match la respuesta queda intacta" "quedo: [$ANSWER]"
  fi
fi
rm -f "$BLOQUE"

echo
printf 'test-study-sugerencia: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
