#!/usr/bin/env bash
# test-numeros-rotos.sh -- que un calculo que salio mal no se le presente al usuario como bueno.
#
# EL CASO REAL (2026-08-17, revision del motor en vivo). A Mentis Science se le pidio la media y el
# desvio estandar de ocho numeros: 2, 4, 4, 4, 5, 5, 7, 9. Calculo con awk y su propia salida decia:
#
#     awk: warning: sqrt: received negative argument -25
#     Media: 5   Desviacion Estandar: -nan
#     Media: 5   Desviacion Estandar: 2.1213203435596424
#
# Y le respondio al usuario: "Media: 5, Desviacion Estandar: 2.12".
#
# 2.12 no es la desviacion poblacional (2.0) ni la muestral (2.14): sumo mal los cuadrados. El modo
# que se presenta como "calcula de verdad y dice sus limites" entrego un numero inventado teniendo
# el error impreso en su propia salida.
#
# LO QUE HACE LA GUARDA, Y LO QUE NO: no corrige la cuenta -- eso es del modelo. Le pone el
# problema ADELANTE de la salida para que no pueda pasarlo por alto, igual que las otras guardas
# del motor. Un modelo lee "-nan" y sigue de largo; un grep no.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== la funcion REAL, extraida del motor =="
BLOQUE="$(mktemp)"
awk '/^_nva_marcar_numeros_rotos\(\)/,/^}/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 3 ]; then
  _mal "se extrae la funcion" "no se encontro _nva_marcar_numeros_rotos en $A"
else
  _ok "la funcion se extrae de nv-agent.sh"
  # shellcheck source=/dev/null
  source "$BLOQUE"

  _marca()   { if _nva_marcar_numeros_rotos "$2"; then _ok "$1"; else _mal "$1" "no la marco"; fi; }
  _nomarca() { if _nva_marcar_numeros_rotos "$2"; then _mal "$1" "marco una salida sana"; else _ok "$1"; fi; }

  echo "-- lo que TIENE que marcar"
  # El caso exacto, palabra por palabra.
  _marca "el -nan del caso real"      "Media: 5	Desviación Estándar: -nan"
  _marca "el warning de awk del caso real" "awk: cmd. line:1: (FILENAME=- FNR=1) warning: sqrt: received negative argument -25"
  _marca "un infinito con signo"      "resultado: -inf"
  _marca "una division por cero"      "ZeroDivisionError: float division by zero"
  _marca "Infinity de JavaScript"     "total: Infinity"

  echo "-- y lo que NO puede marcar (si no, molesta en cada turno)"
  # El resultado BIEN calculado del mismo caso.
  _nomarca "el resultado correcto"    "Media: 5, Desviación Estándar: 2.14"
  # Falso positivo encontrado probando la funcion antes de encenderla.
  _nomarca "'inf' como palabra suelta" "hasta el inf y mas alla"
  _nomarca "'informacion' contiene inf" "esta es la informacion que pediste"
  _nomarca "una salida cualquiera"     "exit=0
listo: 42 archivos"
  _nomarca "texto vacio"               ""
fi
rm -f "$BLOQUE"

echo "== el cableado en el motor =="
if awk '/^    run\)/,/^    write\)/' "$A" | grep -q '_nva_marcar_numeros_rotos'; then
  _ok "'run' revisa su salida antes de entregarla"
else
  _mal "run no revisa" "un nan vuelve a pasar como resultado bueno"
fi
if awk '/^    run\)/,/^    write\)/' "$A" | grep -q 'NO sirve y no se lo podes pasar al usuario'; then
  _ok "el aviso le dice al modelo que ese numero no se entrega"
else
  _mal "el aviso es tibio" "sin decirle que no lo entregue, lo entrega igual"
fi

echo
printf 'test-numeros-rotos: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
