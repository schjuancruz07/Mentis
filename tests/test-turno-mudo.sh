#!/usr/bin/env bash
# test-turno-mudo.sh -- que NINGUN camino deje al usuario sin respuesta.
#
# LA INVARIANTE, EN UNA LINEA: si el turno hizo algo, el usuario se entera. Siempre.
#
# DE DONDE SALE (2026-08-17, revision del motor en vivo, 4 de 7 modos). Dos de los cuatro turnos
# terminaron mudos:
#   - Mentis Designe genero un.docx en 50,9 segundos y despues el modelo devolvio JSON invalido
#     dos veces. El motor corto y salio sin decir nada. **El archivo existia y el usuario nunca se
#     entero**: trabajo hecho, pagado y tirado.
#   - Mentis se comio 117 segundos buscando en la web (seis veces lo mismo), la guarda de bucle
#     corto bien... y el turno tampoco dijo una palabra. Para quien lo mira es igual que un cuelgue.
#
# POR QUE PASABA: el cierre forzado -- el mecanismo que pide la respuesta final cuando el turno se
# corta -- solo se prendia en UN camino (objetivo logrado) y, en el del bucle, solo si habia
# "acciones reales". Un bucle de 'browse' no deja artefactos, asi que no contaba.
#
# Este test mira el CABLEADO en el archivo real, no una copia: que cada camino de corte encienda el
# cierre. Probar los tres caminos de punta a punta necesitaria tres turnos con modelo (varios
# minutos y plata); esto cuesta milisegundos y falla igual si alguien saca una de las lineas.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== los caminos que cortan un turno =="

# 1. JSON invalido dos veces.
if awk '/no devolvió JSON válido dos veces/,/STATUS="nojson"/' "$A" | grep -q 'CIERRE_FORZADO=1'; then
  _ok "cortar por JSON invalido pide igual la respuesta final"
else
  _mal "JSON invalido deja mudo" "el turno puede haber generado un documento y no contarlo"
fi

# 2. Bucle de aciertos, SIN condicion de acciones reales.
BLOQUE="$(awk '/EL AVISO SOLO NO ALCANZA/,/^    elif /' "$A")"
if printf '%s' "$BLOQUE" | grep -q 'CIERRE_FORZADO=1'; then
  _ok "cortar por bucle pide igual la respuesta final"
else
  _mal "el bucle deja mudo" "un bucle de browse/task termina sin decir nada"
fi
if printf '%s' "$BLOQUE" | grep -qE 'ACCIONES_N[^)]*-gt 0 \]\s*&&\s*CIERRE_FORZADO'; then
  _mal "el cierre por bucle sigue condicionado" "un bucle sin artefactos vuelve a quedar mudo"
else
  _ok "el cierre por bucle NO depende de que haya artefactos"
fi

# 3. Errores repetidos (el detector viejo). Aparecio en vivo DESPUES de tapar los otros dos:
# Cowork repitio 'edit' sin 'old' siete veces, se corto, y salio mudo. Tres ramas distintas para
# el mismo problema es la senal de que habia que buscarlas todas juntas.
if grep -A 8 'LOOP_DETECTADO=1' "$A" | grep -q 'CIERRE_FORZADO=1'; then
  _ok "cortar por errores repetidos pide igual la respuesta final"
else
  _mal "errores repetidos deja mudo" "el tercer camino de corte sigue saliendo sin decir nada"
fi

echo "== el texto del cierre no puede mentir =="
# Con 0 acciones no se le puede decir al modelo "terminaste la tarea": lo empuja a inventar que
# hizo algo, justo cuando lo que hace falta es que sea honesto.
CIERRE="$(awk '/EL PEDIDO CAMBIA SEGUN QUE PASO/,/_cierre_pie"$/' "$A")"
if printf '%s' "$CIERRE" | grep -q 'ACCIONES_N:-0}" -gt 0'; then
  _ok "el pedido de cierre distingue si hubo trabajo o no"
else
  _mal "el cierre es uno solo" "con 0 acciones le dice 'terminaste la tarea' y lo empuja a inventar"
fi
if printf '%s' "$CIERRE" | grep -qi 'SÉ HONESTO\|SE HONESTO'; then
  _ok "cuando no hizo nada, se le pide honestidad explicita"
else
  _mal "sin pedido de honestidad" "el modelo tiende a llenar el vacio con algo que suene bien"
fi

# Y el ultimo recurso (sin modelo) tampoco puede afirmar trabajo que no hubo.
# El rango del awk terminaba en el PRIMER "fi", que llega antes de la condicion que se busca.
# Se toma un bloque fijo desde la marca: el codigo estaba bien y el test se equivocaba solo.
ULTIMO="$(grep -A 8 'Sin modelo tampoco se miente' "$A")"
if printf '%s' "$ULTIMO" | grep -q 'ACCIONES_N:-0}" -gt 0'; then
  _ok "el mensaje de ultimo recurso tambien distingue los dos casos"
else
  _mal "ultimo recurso" "dice 'complete N acciones' aunque N sea 0"
fi

echo "== y el turno sigue pudiendo terminar bien =="
# La rama de exito no se toco: si STATUS=done, se imprime la respuesta y listo.
if grep -q 'if \[ "$STATUS" = "done" \]; then' "$A"; then
  _ok "la salida normal del turno sigue intacta"
else
  _mal "salida normal" "se rompio el camino feliz"
fi

echo
printf 'test-turno-mudo: %d ok, %d fallas\n' "$ok" "$fallo"
[ "$fallo" -eq 0 ]
