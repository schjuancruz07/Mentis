#!/usr/bin/env bash
# test-humo-motor.sh -- ¿el motor ARRANCA? (2026-08-15)
#
# POR QUE EXISTE, Y POR QUE ES CORTO:
#   Hoy rompí nv-agent.sh agregando una línea de texto a la ficha de una herramienta: puse comillas
#   dobles sin escapar dentro de un string que ya usaba comillas escapadas, el string cerró antes de
#   tiempo y lo que seguía pasó a ser código. Mentis dejó de arrancar: `line 2539: se: command not
#   found` en el primer turno (ERR-159).
#
#   `bash -n` PASÓ. Y las siete suites de tests pasaron también, porque todas leen el archivo con
#   grep/awk o ejecutan bloques extraídos -- ninguna lo ARRANCA. El error lo encontró un duelo,
#   media hora después, por un puntaje imposible en un tiempo imposible.
#
# LO QUE PRUEBA: que el motor llegue hasta el loop con todo armado -- las fichas de herramientas,
# el protocolo, las guardas -- sin gastar una sola llamada al modelo. Con `-i 0` el bucle no entra
# y el turno termina solo. Es un test de UN segundo que cubre el agujero exacto de ERR-159.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el motor arranca de verdad (no solo compila) =="
bash -n "$A" && _ok "bash -n pasa (necesario, y NO suficiente: con ERR-159 tambien pasaba)" \
             || _mal "bash -n" "el archivo ni compila"

HUMO_TMP="$(mktemp -d)"
# CON TODAS LAS BANDERAS, y esto no es adorno: las fichas de herramientas se arman SOLO si su
# bandera esta puesta. Probado el 2026-08-15 reintroduciendo el bug de ERR-159 en una copia: sin
# "-D" el motor nunca llega a la ficha de 'datos' y el test pasaba con el archivo roto. Un test
# de humo que no enciende las luces no prueba que anden.
# Quedan afuera -x (sin frenos) y -C (personal): no arman ficha nueva y no hacen falta.
SALIDA="$(cd "$HUMO_TMP" && timeout 90 bash "$A" -d. -i 0 -w -b -t -g -s -c -e -a -D -V -P -K "tarea de humo" 2>&1)"
# Lo que delata el problema: cualquier "command not found" o "unexpected token" mientras el motor
# se arma. No se mira el codigo de salida: con -i 0 el turno termina sin respuesta a proposito.
if printf '%s' "$SALIDA" | grep -qiE 'command not found|unexpected token|unbound variable|syntax error'; then
  _mal "arranca limpio" "$(printf '%s' "$SALIDA" | grep -iE 'command not found|unexpected token|unbound variable|syntax error' | head -2 | tr '\n' ' ')"
else
  _ok "arranca sin errores de shell"
fi
printf '%s' "$SALIDA" | grep -q 'PRESUPUESTO:' \
  && _ok "llega a anunciar el presupuesto (o sea: armo el protocolo y las fichas)" \
  || _mal "llega al loop" "murio antes de armar el turno"

# Y las fichas de herramientas tienen que estar completas: si una comilla las corta, el modelo
# recibe media lista y no se entera nadie.
for t in read write exec browse datos gen done; do
  grep -q "\\\\\"tool\\\\\":\\\\\"$t\\\\\"" "$A" \
    && _ok "la ficha de '$t' sigue en el protocolo" \
    || _mal "ficha de '$t'" "desaparecio del protocolo"
done
rm -rf "$HUMO_TMP"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
