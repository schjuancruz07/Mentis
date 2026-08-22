#!/usr/bin/env bash
# Ejecuta DE VERDAD las funciones del tope de capacidades invasivas.
#
# POR QUE (2026-08-18): test-camara-tope.sh verificaba las 23 aserciones con `grep` sobre
# nv-agent.sh -- comprobaba que las lineas estuvieran escritas, no que el tope frenara. Es la
# capacidad que ya se fue en bucle una vez (la camara quedo prendida sola), asi que es justo
# donde un test declarativo es menos aceptable: puede estar en verde con el tope roto.
# Estas funciones se extraen del agente y se corren.
CT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$CT_HERE/engine/nv-agent.sh"
fallos=()

BLOQUE="$(mktemp)"
{
  sed -n '/^declare -A TOPE_MAX=(/,/^)/p' "$A"
  sed -n '/^declare -A TOPE_USOS=/p' "$A"
  sed -n '/^_tope_alcanzado()/,/^}/p' "$A"
  sed -n '/^_tope_sumar()/,/^}/p'     "$A"
  sed -n '/^_tope_mensaje()/,/^}/p'   "$A"
} > "$BLOQUE"
[ "$(wc -l < "$BLOQUE")" -lt 15 ] && { echo "MAL no se pudo extraer el bloque del tope"; exit 1; }
# shellcheck disable=SC1090
source "$BLOQUE"

# 1) los topes declarados son los que se esperan
[ "${TOPE_MAX[webcam]}" = "3" ] || fallos+=("el tope de webcam no es 3: ${TOPE_MAX[webcam]}")

# 2) EL COMPORTAMIENTO: la 4a llamada a la camara tiene que estar frenada
TOPE_USOS=()
permitidas=0
for i in 1 2 3 4 5; do
  if _tope_alcanzado webcam; then break; fi
  _tope_sumar webcam
  permitidas=$((permitidas+1))
done
[ "$permitidas" = "3" ] || fallos+=("la camara se pudo usar $permitidas veces, el tope es 3")

# 3) se suma ANTES de ejecutar: un fallo a mitad no puede dejar el contador quieto
TOPE_USOS=(); _tope_sumar webcam
[ "${TOPE_USOS[webcam]}" = "1" ] || fallos+=("_tope_sumar no incrementa")

# 4) el mensaje le dice que NO insista y que cierre -- sin eso gasta el presupuesto contra la puerta
TOPE_USOS=([webcam]=3)
msg="$(_tope_mensaje webcam)"
case "$msg" in
  *"No la pidas de nuevo"*) : ;;
  *) fallos+=("el mensaje de tope no le dice que no insista") ;;
esac
case "$msg" in *done*) : ;; *) fallos+=("el mensaje de tope no le ofrece cerrar con done") ;; esac

# 5) una capacidad sin tope declarado NO se frena (el tope no puede ser un freno universal)
TOPE_USOS=([read]=999)
if _tope_alcanzado read; then fallos+=("freno una capacidad que no tiene tope declarado"); fi

# 6) el tope se puede correr por variable de entorno, sin tocar codigo
MENTIS_WEBCAM_MAX=1 bash -c '
  eval "$(sed -n "/^declare -A TOPE_MAX=(/,/^)/p" "'"$A"'")"
  [ "${TOPE_MAX[webcam]}" = "1" ]' || fallos+=("MENTIS_WEBCAM_MAX no corre el tope")

# 7) cada capacidad invasiva declarada tiene tope > 0
for h in webcam screen control telefono arduino; do
  [ "${TOPE_MAX[$h]:-0}" -gt 0 ] || fallos+=("la capacidad '$h' quedo sin tope")
done

rm -f "$BLOQUE"
if [ "${#fallos[@]}" -gt 0 ]; then
  printf 'MAL %s\n' "${fallos[@]}"
  exit 1
fi
echo "casos: 7"
