#!/usr/bin/env bash
# test-camara-tope.sh -- que la camara no se pueda disparar en bucle.
#
# QUE PASO (2026-08-08): Mentis se quedo sacando fotos con la webcam una y otra vez. el usuario apreto
# el boton de frenar y no paso nada. Recien paro cuando cerro la aplicacion entera.
#
# TRES COSAS FALLARON A LA VEZ, y este test cubre las tres:
#   1. La unica proteccion contra repetir una herramienta era SAME_TOOL_STREAK, que cuenta
#      repeticiones CONSECUTIVAS y encima no corta: le manda una nota al modelo pidiendole que
#      cambie de estrategia. Una defensa que depende de que el modelo obedezca no es una defensa.
#   2. El boton "Frenar ya" estaba OCULTO: solo aparecia con los flags de "sin frenos", control
#      de mouse o Arduino. La camara no contaba como capacidad de riesgo -- siendo que el propio
#      codigo la llama "la herramienta mas invasiva que tiene Mentis".
#   3. Sin tope, un bucle solo terminaba cuando se agotaba el presupuesto de iteraciones.
#
# NO ENCIENDE LA CAMARA. Se prueba la logica del tope y la del boton, leyendo el codigo y
# simulando el contador. Un test que prendiera la webcam del usuario para probar que no se prende
# demasiado seria absurdo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
R="$HERE/app/renderer/renderer.js"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el tope existe y es un numero, no un pedido =="
grep -q 'declare -A TOPE_MAX=(' "$A" \
  && _ok "hay una tabla de topes por herramienta" \
  || _mal "existe TOPE_MAX" "sin tope, el bucle solo para al agotarse el presupuesto"
grep -q '\[webcam\]="\${MENTIS_WEBCAM_MAX:-3}"' "$A" \
  && _ok "la camara sigue en 3 usos por turno, configurable" \
  || _mal "el tope de la camara" "era 3 y no hay motivo para haberlo cambiado"
grep -q 'declare -A TOPE_USOS=()' "$A" \
  && _ok "los contadores arrancan vacios cada turno" \
  || _mal "TOPE_USOS se inicializa" "un contador sin inicializar no cuenta"
grep -q 'elif _tope_alcanzado webcam; then' "$A" \
  && _ok "se rechaza la camara al llegar al tope" \
  || _mal "hay rechazo por tope" "el contador no sirve si nadie lo mira"

echo "== y ahora LAS CINCO invasivas, no solo la camara =="
# Cuando se cerro el agujero de la camara (2026-08-08) quedo escrito, en la propia bitacora, que
# faltaban las otras cuatro: 'screen', 'control', 'telefono' y 'arduino' tenian permiso de
# encendido y ningun limite de uso. Se cerraron el 2026-08-10 junto con el sistema de modos,
# porque repartir capacidades obliga a pasar por exactamente ese punto del codigo.
for _h in webcam screen control telefono arduino; do
  grep -q "\[$_h\]=" "$A" \
    && _ok "'$_h' tiene tope declarado" \
    || _mal "tope de '$_h'" "un permiso responde '¿puede?'; falta responder '¿cuantas veces?'"
  grep -q "_tope_alcanzado $_h" "$A" \
    && _ok "'$_h' se rechaza al llegar al tope" \
    || _mal "rechazo de '$_h'" "un tope declarado y no aplicado no protege de nada"
  grep -q "_tope_sumar $_h" "$A" \
    && _ok "'$_h' cuenta sus usos" \
    || _mal "contador de '$_h'" "sin contar, el tope nunca se alcanza"
done

echo "== el tope se suma apenas entra, no al terminar =="
# En las cuatro nuevas el _tope_sumar es la PRIMERA linea despues del else, a proposito: si se
# contara al final, un fallo a mitad de camino dejaria el contador quieto y el bucle podria seguir
# eternamente a base de intentos fallidos -- que es justamente como se comporta un bucle.
for _h in screen control telefono arduino; do
  if grep -A 1 "elif _tope_alcanzado $_h; then" "$A" >/dev/null 2>&1 && \
     grep -A 4 "elif _tope_alcanzado $_h; then" "$A" | grep -q "^        _tope_sumar $_h$"; then
    _ok "'$_h' suma el uso al entrar"
  else
    _mal "orden del contador de '$_h'" "si suma al final, los intentos fallidos no cuentan"
  fi
done

echo "== se cuenta ANTES de sacar la foto =="
# Si se contara despues, un fallo a mitad de camino dejaria el contador quieto y el bucle podria
# seguir para siempre a base de intentos fallidos.
if awk '/mirar\|leer\|presencia\)/,/;;/' "$A" | grep -B 20 'webcam \$WACTION ->' | grep -q '_tope_sumar webcam'; then
  _ok "el contador sube antes de encender la camara"
else
  _mal "el contador sube antes" "si sube despues, los intentos fallidos no cuentan y el bucle sigue"
fi

echo "== el mensaje le dice al modelo que corte, no solo que no puede =="
# Sin la parte de "cerra con done", un modelo obstinado gasta el resto del presupuesto
# reintentando una herramienta que ya sabe que le van a negar.
grep -q "No la pidas de nuevo" "$A" \
  && _ok "el rechazo le indica que cierre o cambie de herramienta" \
  || _mal "el rechazo guia al modelo" "reintentaria hasta quedarse sin presupuesto"

echo "== no se rompio el contrato con la interfaz =="
# La linea "webcam <accion> -> <ruta>" la parsea LIVE_PREVIEW_MARKER en main.js para mostrar la
# foto. Al agregar el contador se intento meterlo en esta linea y la app dejaba de mostrar la
# imagen EN SILENCIO. El contador va en la linea siguiente.
if grep -qE 'echo "\[nv-agent\] iter \$it: webcam \$WACTION -> \$\(_win_path "\$WEBCAM_PREVIEW"\)" >&2' "$A"; then
  _ok "la linea de la foto conserva el formato exacto que espera main.js"
else
  _mal "el formato de la linea de la foto" "si cambia, la app deja de mostrar lo que la camara vio"
fi
grep -q 'uso \${TOPE_USOS\[webcam\]} de \$WEBCAM_MAX' "$A" \
  && _ok "el contador se informa en la linea de al lado" \
  || _mal "se informa el uso" "conviene que se vea cuantos quedan"

echo "== el boton de frenar aparece con la camara prendida =="
if awk '/^function updateEmergencyStopVisibility/,/^}/' "$R" | grep -q "flagWebcamInput"; then
  _ok "la camara cuenta como capacidad de riesgo"
else
  _mal "la camara cuenta para mostrar el freno" "es LO QUE FALLO: no habia boton para frenar"
fi
if awk '/^function updateEmergencyStopVisibility/,/^}/' "$R" | grep -q "flagTelefonoInput"; then
  _ok "el telefono tambien"
else
  _mal "el telefono cuenta" "accede a mensajes y notificaciones reales"
fi
# Tiene que recalcularse al prender el conector, no sólo al tocar otros flags.
if awk '/toggleConnector\(id, input.checked\)/,/catch/' "$R" | grep -q "updateEmergencyStopVisibility"; then
  _ok "el freno aparece en el acto al prender la camara"
else
  _mal "se recalcula al prender el conector" "se podria estar con la camara viva y sin boton"
fi
# Y al arrancar la app, si la camara venia prendida de antes.
if awk '/^async function sincronizarBotonesDeConectores/,/^}/' "$R" | grep -q "updateEmergencyStopVisibility"; then
  _ok "y tambien al abrir la app con la camara ya prendida"
else
  _mal "estado inicial del freno" "si venia prendida, el boton no aparece hasta tocar otra cosa"
fi

echo "== las otras dos llaves siguen puestas =="
# El tope es la TERCERA llave. Las otras dos no se tocaron.
grep -q 'if \[ "\${ALLOW_WEBCAM:-0}" != "1" \]' "$A" \
  && _ok "sigue haciendo falta el permiso -V del proceso" \
  || _mal "primera llave (-V)" "se perdio una barrera"
grep -q "_connector_enabled 'local:webcam'" "$A" \
  && _ok "sigue haciendo falta el conector prendido desde la app" \
  || _mal "segunda llave (conector)" "se perdio una barrera"

echo "== simulacion del contador =="
sim() {
  local usos="$1" max="$2"
  if [ "$usos" -ge "$max" ]; then echo "RECHAZA"; else echo "permite"; fi
}
[ "$(sim 0 3)" = "permite" ] && _ok "primer uso: permite"   || _mal "primer uso" "deberia permitir"
[ "$(sim 2 3)" = "permite" ] && _ok "tercer uso: permite"   || _mal "tercer uso" "deberia permitir"
[ "$(sim 3 3)" = "RECHAZA" ] && _ok "cuarto uso: RECHAZA"   || _mal "cuarto uso" "deberia rechazar"
[ "$(sim 99 3)" = "RECHAZA" ] && _ok "y sigue rechazando"    || _mal "usos altos" "deberia rechazar"

echo ""

# --- EJECUTA de verdad, no solo mira el fuente (2026-08-18) --------------------------------------
# Las aserciones de arriba son `grep` sobre nv-agent.sh: comprueban que las lineas esten escritas,
# no que el tope FRENE. Es la capacidad que ya se fue en bucle una vez, asi que aca un test
# declarativo es el que menos alcanza. camara-tope-ejecuta.sh extrae las funciones reales del
# agente y las corre; se verifico que falla si se rompe la comparacion del tope.
if bash "$(dirname "${BASH_SOURCE[0]}")/camara-tope-ejecuta.sh" > /tmp/ct-ejec.$$ 2>&1; then
  _ok "EJECUTADO: el tope frena de verdad ($(grep -o 'casos: [0-9]*' /tmp/ct-ejec.$$))"
else
  _mal "EJECUTADO: el tope NO frena" "$(head -3 /tmp/ct-ejec.$$ | tr '
' ' ')"
fi
rm -f /tmp/ct-ejec.$$

echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
