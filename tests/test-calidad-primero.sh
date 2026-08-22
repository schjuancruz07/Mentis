#!/usr/bin/env bash
# test-calidad-primero.sh -- el reparador de modelos no puede degradar un rol por lentitud.
#
# POR QUE EXISTE (2026-08-21). El reparador mide si un modelo esta VIVO y si contesta rapido. No
# mide si escribe buen codigo -- no puede, no tiene con que. Y con ese criterio hizo dos cambios
# que nadie reviso:
#
#   14/08  rol 'code'   deepseek-v4-flash -> nemotron-nano-30b   ("esta vivo pero tarda")
#   12/08  rol 'reason' nemotron-ultra-550b -> llama-super-49b   ("esta vivo pero tarda")
#
# Medido el 2026-08-21 con el duelo de codigo (arreglar 3 bugs reales en un archivo, 3 vueltas):
# deepseek 3 de 3 con mediana 69 s; nemotron-nano 1 de 3 con mediana 118 s. El cambio hecho POR
# VELOCIDAD dejo un modelo PEOR Y MAS LENTO, y estuvo una semana asi sin que nadie lo notara.
#
# El sintoma que veia el usuario era otro: "Mentis ya no modifica codigo". No era el motor ni el
# prompt -- le habian cambiado el cerebro.
#
# LO QUE ESTE TEST PROTEGE: que el campo `calidad_primero` este CABLEADO. Un campo declarado y sin
# leer seria exactamente el error que se persiguio toda esa sesion (cinco campos muertos en
# modos.json), y encima en el lugar mas caro: el que elige los modelos.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPARADOR="$HERE/mentis-modelos-reparar.sh"
OVERRIDE="$HERE/modelos-override.json"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== los roles donde la calidad importa estan marcados =="
for rol in code reason; do
  if node -e "
    const d = require('$(cygpath -m "$OVERRIDE")');
    process.exit(d.roles['$rol'] && d.roles['$rol'].calidad_primero === true ? 0 : 1);
  " 2>/dev/null; then
    _ok "'$rol' esta marcado como calidad_primero"
  else
    _mal "'$rol' no esta protegido" "el reparador puede degradarlo por lentitud otra vez"
  fi
done

echo ""
echo "== EL CAMPO ESTA CABLEADO (no es decorativo) =="
# La comprobacion que de verdad importa: que el reparador LEA el campo, y que lo lea ANTES de
# decidir el reemplazo por presupuesto. Si lo leyera despues, ya habria cambiado el modelo.
if grep -q "_mr_campo_rol" "$REPARADOR"; then
  _ok "el reparador tiene la funcion que lee el campo"
else
  _mal "no existe _mr_campo_rol en el reparador" "el campo seria decorativo"
fi
if grep -q 'calidad_primero' "$REPARADOR"; then
  _ok "y consulta 'calidad_primero'"
else
  _mal "el reparador no consulta el campo" "esta declarado en el JSON y no lo lee nadie"
fi
# El orden: la guarda tiene que estar ANTES de la linea que marca la causa 'presupuesto'.
LN_GUARDA="$(grep -n 'calidad_primero' "$REPARADOR" | head -1 | cut -d: -f1)"
LN_CAUSA="$(grep -n 'MR_CAUSA="presupuesto"' "$REPARADOR" | head -1 | cut -d: -f1)"
if [ -n "$LN_GUARDA" ] && [ -n "$LN_CAUSA" ] && [ "$LN_GUARDA" -lt "$LN_CAUSA" ]; then
  _ok "la guarda corta ANTES de decidir el reemplazo (linea $LN_GUARDA < $LN_CAUSA)"
else
  _mal "la guarda esta despues de la decision" "avisaria cuando el modelo ya se cambio"
fi

echo ""
echo "== la funcion lee bien, y distingue los roles protegidos de los que no =="
# Se ejecuta la funcion REAL extraida del reparador, no una copia escrita aca.
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
awk '/^_mr_campo_rol\(\)/,/^}/' "$REPARADOR" > "$SB/fn.sh"
if [ "$(wc -l < "$SB/fn.sh")" -lt 4 ]; then
  _mal "no se pudo extraer _mr_campo_rol" "sin esto lo de abajo no prueba nada"
else
  _ok "la funcion se extrajo del reparador ($(wc -l < "$SB/fn.sh") lineas)"
  # shellcheck source=/dev/null
  MR_OVERRIDE="$OVERRIDE"; source "$SB/fn.sh"
  for rol in code reason; do
    [ "$(_mr_campo_rol "$rol" calidad_primero)" = "True" ] \
      && _ok "lee 'True' para '$rol'" || _mal "no leyo el campo de '$rol'" "devolvio: '$(_mr_campo_rol "$rol" calidad_primero)'"
  done
  for rol in extract general multimodal; do
    [ -z "$(_mr_campo_rol "$rol" calidad_primero)" ] \
      && _ok "'$rol' NO esta protegido (se sigue reparando solo, como antes)" \
      || _mal "'$rol' quedo protegido sin querer" "el reparador dejaria de arreglarlo"
  done
  # Un rol que no existe no puede romper la funcion.
  [ -z "$(_mr_campo_rol "no-existe" calidad_primero)" ] && _ok "un rol inexistente devuelve vacio" \
    || _mal "un rol inexistente no devuelve vacio" ""
fi

echo ""
echo "== la proteccion es SOLO contra la lentitud, no contra la muerte =="
# Si el modelo se muere de verdad, el reparador tiene que seguir actuando: un rol sin cerebro es
# peor que un rol con un cerebro lento.
if awk "NR>=$LN_GUARDA && NR<=$((LN_GUARDA+8))" "$REPARADOR" | grep -qiE "lentitud|tarda|presupuesto"; then
  _ok "la guarda esta en la rama de LATENCIA, no en la de muerte"
else
  _mal "no se puede confirmar en que rama esta la guarda" "si bloquea la muerte, un rol podria quedarse sin modelo"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
