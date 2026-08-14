#!/usr/bin/env bash
# test-gate-completitud.sh -- que Mentis no pueda decir "funciona" sin haberlo corrido.
#
# POR QUE EXISTE:
#   Es la familia de errores mas frecuente de la bitacora de este proyecto: de los diez errores
#   registrados entre el 2026-08-12 y el 2026-08-14, cuatro son el mismo animal -- una herramienta
#   informando un resultado que no midio (ERR-141: un comando avisando que ya no encontraria el
#   material y encontrandolo; ERR-144: 'exec' devolviendo exit 0 sobre la cadena vacia). el usuario ya
#   tiene un guardian de sobreconfianza en Claude Code por esta misma razon; Mentis no lo tenia.
#
# POR QUE NO CORRE UN TURNO DE VERDAD (mismo criterio que test-cierre-turno.sh):
#   Un test asi dependeria de que el modelo mienta HOY para probar que la red lo atrapa. Si el
#   modelo se porta bien en la corrida, el test da verde sin haber probado nada. Aca se prueba la
#   MECANICA -- la deteccion, que es una funcion pura, y el cableado, leyendo el codigo del
#   agente -- que es lo unico que se puede afirmar sin mentir.
#
# La medicion de falsos positivos sobre datos REALES no vive aca: es eval/gate-completitud/medir.sh.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
source "$HERE/engine/nv-gate-lib.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# dispara <texto>  -> "si" | "no"
dispara() { if nv_gate_afirma_listo "$1"; then echo "si"; else echo "no"; fi; }
debe_disparar()    { local r; r="$(dispara "$1")"; [ "$r" = "si" ] && _ok "atrapa: $1" || _mal "atrapa: $1" "no disparo"; }
no_debe_disparar() { local r; r="$(dispara "$1")"; [ "$r" = "no" ] && _ok "deja pasar: $1" || _mal "deja pasar: $1" "disparo de mas"; }

echo "== afirmaciones de completitud (TIENEN que exigir prueba) =="
debe_disparar "Listo, ya funciona."
debe_disparar "El script anda."
debe_disparar "Quedó funcionando."
debe_disparar "Lo probé y da el resultado esperado."
debe_disparar "Los tests pasaron."
debe_disparar "Pasa todos los tests."
debe_disparar "Corregí el bug, ahora corre sin errores."
debe_disparar "El archivo está verificado."
debe_disparar "Todo en verde."
debe_disparar "Comprobé que devuelve 42."

echo ""
echo "== respuestas HONESTAS (no se las puede castigar) =="
# Esto es lo mas importante del test: si el gate se dispara con las respuestas honestas, empuja
# al modelo justo en la direccion contraria a la que se construyo.
no_debe_disparar "Escribí el script pero no lo probé."
no_debe_disparar "No funciona todavía: falla al importar el módulo."
no_debe_disparar "Debería andar, pero no lo pude correr acá."
no_debe_disparar "Probalo vos con exec antes de darlo por bueno."
no_debe_disparar "Falta que pases los tests para confirmarlo."
no_debe_disparar "Hay que verificar que funcione con el archivo real."
no_debe_disparar "Si funciona, avisame y sigo con lo demás."
no_debe_disparar "Para que funcione hace falta la key de Ideogram."
no_debe_disparar "Todavía no lo verifiqué."
no_debe_disparar "No sé si anda: no tengo cómo probarlo desde acá."

echo ""
echo "== el bug que aparecio midiendo (2026-08-14) =="
# 'anda' sin limite de palabra matcheaba adentro de otras palabras: dos respuestas reales de
# el usuario disparaban por "lavanda" (una descripcion de un cuadro) y por "manda" (una propuesta
# comercial). Sin la medicion sobre datos reales esto entraba en produccion sin que nadie lo vea.
no_debe_disparar "Fondo difuso en tonos lavanda, celeste y rosa."
no_debe_disparar "Un profesional de 40 años manda propuestas vagas."
no_debe_disparar "La demanda del mercado bajó."

echo ""
echo "== en inglés también (los modelos se cambian de idioma solos) =="
# Encontrado probando en vivo el 2026-08-14: se le pidio en español, escribio el archivo, corrio
# el test y cerro con "executed the file successfully... confirming the function works as
# intended". Un detector solo en español deja pasar la afirmacion entera por el idioma.
debe_disparar "Created the file and it works."
debe_disparar "Executed it, works as intended."
debe_disparar "I tested it and there were no problems."
debe_disparar "All tests passed."
no_debe_disparar "I could not test it here."
no_debe_disparar "You should test it before using it."

echo ""
echo "== el apagado y el cableado en el agente =="
# EL CONTADOR TIENE QUE VIVIR EN EL SHELL DEL LOOP. Si '_dispatch_tool' se llamara dentro de una
# sustitucion -- OBS="$(_dispatch_tool...)" -- el incremento de EVIDENCIA_N ocurriria en un
# subshell y se perderia al volver: el gate no veria NUNCA la evidencia y rechazaria todos los
# cierres. El propio agente ya tiene una nota igual para VERIFY_USED/VERIFY_VERDICT.
if grep -qE '^[[:space:]]*_dispatch_tool "\$it"[[:space:]]*$' "$A"; then
  _ok "_dispatch_tool se llama directo (el contador sobrevive al volver)"
else
  _mal "_dispatch_tool no corre en subshell" "si se lo llama dentro de \$( ), EVIDENCIA_N se pierde y el gate bloquea todo"
fi
grep -q 'MENTIS_GATE_OFF' "$A" && _ok "se puede apagar con MENTIS_GATE_OFF=1" || _mal "apagado" "sin escape, un falso positivo no tiene salida"
grep -q 'source "\$NVDIR/nv-gate-lib.sh"' "$A" && _ok "el agente carga la libreria" || _mal "carga la libreria" "la funcion no existiria en el agente"
grep -q '^EVIDENCIA_N=0' "$A" && _ok "el contador de evidencia arranca en cero" || _mal "EVIDENCIA_N inicializado" "sin inicializar, el gate no se dispara nunca"

echo ""
echo "== que cuenta como prueba fresca =="
# Un exec que FALLA no puede contar: es justo el caso peor (corrio, salio mal, y el turno dice
# que funciona). Si esta linea perdiera el "$RC" = "0", el gate se volveria decorativo.
if grep -q '\[ "\$RC" = "0" \] && EVIDENCIA_N=\$((EVIDENCIA_N+1))' "$A"; then
  _ok "solo un exec con exit 0 suma evidencia"
else
  _mal "exec exitoso suma" "un exec fallido no puede contar como prueba"
fi
if grep -q '\[ "\$VERIFY_VERDICT" = "pass" \] && EVIDENCIA_N=\$((EVIDENCIA_N+1))' "$A"; then
  _ok "una verificacion independiente que pasa tambien suma"
else
  _mal "verify pass suma" "obligaria a un exec redundante cuando ya hubo tests reales"
fi
# EXEC_CNT no sirve como evidencia: se incrementa ANTES de saber si el comando se ejecuto (un
# exec rechazado por permisos o con el campo mal escrito ya lo movio).
if awk '/^    exec\)/,/^      fi ;;/' "$A" | grep -q 'EXEC_CNT=\$((EXEC_CNT+1))'; then
  _ok "EXEC_CNT sigue contando intentos (por eso no se usa como evidencia)"
else
  _mal "EXEC_CNT cuenta intentos" "si cambio la semantica, revisar el gate"
fi

echo ""
echo "== las dos condiciones que lo acotan =="
if grep -q 'WRITE_CNT + \${EXEC_CNT:-0} )) -gt 0 \] && nv_gate_afirma_listo' "$A"; then
  _ok "solo se mete si el turno toco algo (write o exec)"
else
  _mal "requiere accion en el turno" "sin esto se mete en conversaciones donde 'funciona' es descriptivo"
fi
if awk '/GATE DE COMPLETITUD \(2026-08-14/,/if \[ "\$STATUS" = "done" \]; then break; fi/' "$A" | grep -q 'GATE_RECHAZOS:-0} -ge 1\|GATE_RECHAZOS:-0}" -ge 1'; then
  _ok "a la segunda corrige el texto en vez de rechazar de nuevo"
else
  _mal "no rechaza en bucle" "un turno se comio 10 minutos asi con la guarda de documento"
fi
# El rechazo tiene que decir COMO conseguir la prueba, no solo que falta.
nv_gate_observacion_rechazo | grep -q '"tool":"exec"' && _ok "el rechazo dice como probarlo" || _mal "el rechazo da la salida" "un rechazo sin salida termina en el corta-bucles"
nv_gate_observacion_rechazo | grep -qi 'Si no lo pod' && _ok "y admite 'no lo pude probar' como respuesta valida" || _mal "acepta la honestidad" "si la unica salida es probar, el modelo va a mentir mejor"
# El texto corregido no puede borrar la respuesta: adentro puede haber trabajo util.
if [ "$(nv_gate_texto_corregido "CONTENIDO ORIGINAL" | grep -c 'CONTENIDO ORIGINAL')" = "1" ]; then
  _ok "la correccion conserva la respuesta completa"
else
  _mal "conserva la respuesta" "tirar el texto castiga al usuario, no al modelo"
fi

echo ""
echo "== el gate REAL, ejecutado (no una copia del test) =="
# Las dos guardas viejas del cierre nunca se probaron ejecutandose: estan inline en el loop y
# hacen falta un modelo y un turno entero para llegar hasta ellas. Se intento dos veces en vivo
# el 2026-08-14 y ninguna llego a 'done' (una se fue en bucle de write, la otra de read), asi que
# probarlo "en vivo" quedaba a merced de como se porte el modelo ese dia.
#
# Aca se EXTRAEN las lineas del bloque del gate de nv-agent.sh y se ejecutan con las variables
# puestas a mano. No es una reimplementacion: si alguien edita el bloque en el agente, este test
# ejecuta la version editada.
BLOQUE="$(mktemp)"
awk '/# GATE DE COMPLETITUD \(2026-08-14/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 10 ]; then
  _mal "se puede extraer el bloque del gate" "no se encontro en $A (cambiaron los marcadores?)"
else
  _ok "el bloque del gate se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"

  # caso 1: afirma que funciona, escribio un archivo, no hay prueba -> se rechaza el cierre
  correr_gate() {
    # $1=FINAL  $2=EVIDENCIA_N  $3=WRITE_CNT  $4=GATE_RECHAZOS  $5=MENTIS_GATE_OFF
    (
      set +e
      source "$HERE/engine/nv-gate-lib.sh"
      FINAL="$1"; EVIDENCIA_N="$2"; WRITE_CNT="$3"; GATE_RECHAZOS="$4"; MENTIS_GATE_OFF="$5"
      EXEC_CNT=0; STATUS="done"; HIST=""; it="${6:-3}"; MAXIT=20
      source "$BLOQUE"
      printf 'STATUS=%s|RECHAZOS=%s|FINAL=%s' "$STATUS" "$GATE_RECHAZOS" "$(printf '%s' "$FINAL" | head -c 40)"
    )
  }
  r="$(correr_gate "Listo, ya funciona." 0 1 0 0)"
  case "$r" in
    STATUS=budget*FINAL=) _ok "afirma sin prueba -> el cierre se RECHAZA y se vacia la respuesta" ;;
    *) _mal "rechaza el cierre sin prueba" "obtuvo: $r" ;;
  esac
  case "$r" in *RECHAZOS=1*) _ok "el rechazo queda contado" ;; *) _mal "cuenta el rechazo" "obtuvo: $r" ;; esac

  # caso 2: la MISMA afirmacion por segunda vez -> pasa, pero corregida
  r="$(correr_gate "Listo, ya funciona." 0 1 1 0)"
  case "$r" in
    STATUS=done*FINAL=Ojo*) _ok "segunda vez -> pasa con la afirmacion corregida (no vuelve a rechazar)" ;;
    *) _mal "la segunda vez corrige en vez de rechazar" "obtuvo: $r" ;;
  esac

  # caso 3: hay prueba fresca -> no se mete
  r="$(correr_gate "Listo, ya funciona." 1 1 0 0)"
  case "$r" in
    STATUS=done*FINAL=Listo*) _ok "con evidencia fresca no se mete" ;;
    *) _mal "no molesta cuando hay prueba" "obtuvo: $r" ;;
  esac

  # caso 4: el turno no toco nada (charla) -> no se mete aunque diga "funciona"
  r="$(correr_gate "El Enter funciona correctamente." 0 0 0 0)"
  case "$r" in
    STATUS=done*FINAL=El\ Enter*) _ok "en una charla sin escrituras no se mete" ;;
    *) _mal "no molesta en conversacion" "obtuvo: $r" ;;
  esac

  # caso 5: en la ULTIMA iteracion no se rechaza: no queda margen para pedir la prueba y el turno
  # se quedaria sin respuesta final (el usuario recibiria el historial crudo en vez de lo que el modelo
  # escribio). Se corrige el texto y se entrega.
  r="$(correr_gate "Listo, ya funciona." 0 1 0 0 20)"
  case "$r" in
    STATUS=done*FINAL=Ojo*) _ok "en la ultima iteracion corrige en vez de dejar al usuario sin nada" ;;
    *) _mal "no rechaza en la ultima vuelta" "obtuvo: $r" ;;
  esac

  # caso 6: apagado
  r="$(correr_gate "Listo, ya funciona." 0 1 0 1 3)"
  case "$r" in
    STATUS=done*FINAL=Listo*) _ok "MENTIS_GATE_OFF=1 lo desactiva de verdad" ;;
    *) _mal "el apagado funciona" "obtuvo: $r" ;;
  esac
fi
rm -f "$BLOQUE"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
