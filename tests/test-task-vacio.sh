#!/usr/bin/env bash
# Techo duro a la llamada vacia de 'task' (2026-08-18).
#
# POR QUE EXISTE: el 2026-08-12 la observacion de 'task' sin subject/description se cambio de
# "ERROR:" a instruccion, porque con el error el modelo reintentaba la llamada vacia tres veces.
# No alcanzo: medido el 2026-08-18 en un turno real, la repitio SEIS veces (~100 s) para una
# pregunta que se contestaba hablando. Dos intentos de convencerlo con texto, dos fracasos. El
# techo de abajo no le pide nada: cuenta y corta. Este test EJECUTA el bloque real del agente --
# un grep no puede ver si la condicion corta de verdad.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok    $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA $1  ($2)"; }

A="$HERE/engine/nv-agent.sh"
echo "-- techo de 'task' vacio"

# 1) el contador se incrementa donde corresponde: junto a la observacion de la llamada vacia
if grep -q 'TASK_VACIO_N=$(( ${TASK_VACIO_N:-0} + 1 ))' "$A"; then
  _ok "la llamada vacia de 'task' incrementa el contador"
else
  _mal "el contador no se incrementa" "sin contador el techo nunca se alcanza"
fi

# 2) el bloque del techo se extrae y SE EJECUTA
BLOQUE="$(mktemp)"
awk '/# TECHO DURO A LA LLAMADA VACIA/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 8 ]; then
  _mal "se puede extraer el bloque del techo" "no se encontro en $A (cambiaron los marcadores?)"
else
  _ok "el bloque del techo se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"

  correr() {  # $1 = cuantas llamadas vacias van; $2 = tope opcional
    (
      set +e
      TASK_VACIO_N="$1"; TASK_VACIO_MAX="${2:-2}"
      LOOP_DETECTADO=0; CIERRE_FORZADO=0; STATUS="budget"; OBS=""; it=3
      # el bloque hace 'break': se envuelve en un loop de una vuelta, como en el agente
      for _v in 1; do source "$BLOQUE"; done 2>/dev/null
      printf 'STATUS=%s|CIERRE=%s|LOOP=%s' "$STATUS" "$CIERRE_FORZADO" "$LOOP_DETECTADO"
    )
  }

  r="$(correr 1)"
  case "$r" in
    STATUS=budget*CIERRE=0*) _ok "UNA llamada vacia no corta (puede ser un desliz)" ;;
    *) _mal "no corta con una sola llamada vacia" "obtuvo: $r" ;;
  esac

  r="$(correr 2)"
  case "$r" in
    STATUS=task_vacio*CIERRE=1*LOOP=1*) _ok "DOS llamadas vacias cortan el turno" ;;
    *) _mal "dos llamadas vacias tienen que cortar" "obtuvo: $r" ;;
  esac

  r="$(correr 6)"
  case "$r" in
    STATUS=task_vacio*) _ok "seis (el caso real medido) tambien corta" ;;
    *) _mal "el caso real no corta" "obtuvo: $r" ;;
  esac

  # Corta PERO CONTESTA: sin CIERRE_FORZADO el turno se moriria mudo, que es peor que dar vueltas.
  r="$(correr 2)"
  case "$r" in
    *CIERRE=1*) _ok "al cortar pide el cierre forzado: el turno no queda mudo" ;;
    *) _mal "corta sin cierre forzado" "el usuario se queda sin respuesta: obtuvo $r" ;;
  esac

  # El tope se puede correr sin tocar el codigo.
  r="$(correr 2 9)"
  case "$r" in
    STATUS=budget*) _ok "TASK_VACIO_MAX corre el tope sin tocar el codigo" ;;
    *) _mal "el tope no es configurable" "obtuvo: $r" ;;
  esac
fi
rm -f "$BLOQUE"

echo
echo "== $OK ok, $MAL fallan =="
[ "$MAL" -eq 0 ]
