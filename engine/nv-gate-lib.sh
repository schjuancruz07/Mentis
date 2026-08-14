#!/usr/bin/env bash
# nv-gate-lib.sh -- GATE DE COMPLETITUD (2026-08-14, idea 2 de docs/godmode-que-sirve.md).
#
# UNA sola regla, deliberadamente: si un turno afirma que algo FUNCIONA / QUEDO PROBADO, tiene
# que haber en ese mismo turno la salida fresca de un comando que lo respalde. Sin eso, el turno
# no se aprueba solo: primero se le pide la prueba, y si insiste se corrige el texto.
#
# POR QUE VIVE EN UNA LIBRERIA Y NO ADENTRO DE nv-agent.sh:
#   Las otras dos guardas del cierre (HAD_REAL_ACTION y HAD_DOC) estan escritas inline y por eso
#   NO se pueden medir sin correr un turno entero contra un modelo. Esta se puede: la deteccion
#   es una funcion pura de texto, asi que se prueba con casos etiquetados y se corre sobre las
#   conversaciones REALES del usuario para contar falsos positivos (tests/test-gate-completitud.sh y
#   eval/gate-completitud/medir.sh). La regla del proyecto es que nada entra sin medirse.
#
# APAGADO: MENTIS_GATE_OFF=1 (mismo patron que INMUNE_OFF/GUARDIAN_OFF en Claude Code).

# nv_gate_afirma_listo <texto>
#   exit 0  -> el texto AFIRMA que algo quedo funcionando/probado/verificado (hay que exigir prueba)
#   exit 1  -> no lo afirma
#
# Dos pasadas, y el orden importa:
#   1) NEUTRALIZAR lo que parece una afirmacion y no lo es. "no funciona", "para que funcione",
#      "deberia andar", "si pasa los tests" son lo contrario de una afirmacion de completitud:
#      son honestos o condicionales. Se reemplazan por un simbolo que no puede matchear despues.
#      Sin esta pasada el gate se dispara justo con los turnos MAS honestos, que es el peor
#      falso positivo posible -- castigaria exactamente la conducta que quiere fomentar.
#   2) BUSCAR la afirmacion en lo que quedo.
#
# No se usa 'tr' para bajar tildes: en MSYS/Windows tr es byte a byte y parte los caracteres
# multibyte por la mitad (ver lecciones de entorno). Las variantes con y sin tilde van escritas
# a mano en el patron, que es feo pero es lo unico que se comporta igual en las dos plataformas.
nv_gate_afirma_listo() {
  local t="${1:-}"
  [ -n "${t// }" ] || return 1
  t="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"

  # 1) neutralizacion (§ no aparece en texto normal y no esta en ningun patron de abajo)
  t="$(printf '%s' "$t" | sed -E '
    s/\b(no|no lo|nunca lo|todavia no|todavía no|aun no|aún no|sin|si|cuando|para que|hasta que|antes de que|deberia|debería|deberian|deberían|habria que|habría que|hay que|falta|faltaria|faltaría|tendria que|tendría que|tenes que|tenés que|proba|probá|probalo|probalo vos|espero que|ojala|ojalá|asumo que|supongo que|en teoria|en teoría|deberias|deberías)[[:space:]]+(que[[:space:]]+)?(lo[[:space:]]+|la[[:space:]]+|se[[:space:]]+)?(funcion|and[aeo]|corr[aei]|pas[aeo]|verific|verifiq|comprob|confirm|prob|test)[a-záéíóúñ]*/§/g
  ')"

  # 2) afirmacion de completitud propiamente dicha
  printf '%s' "$t" | grep -qE \
    '\b(funciona|anda)\b|(quedo|quedó|esta|está)[[:space:]]+(funcionando|andando|probado|verificado|testeado|corriendo bien)|lo[[:space:]]+(probe|probé|testee|testeé|verifique|verifiqué|corri|corrí)([^a-z]|$)|(pasa|pasan|pasaron|paso|pasó)[[:space:]]+(el|los|todos los)[[:space:]]+tests?|tests?[[:space:]]+(en verde|pasan|pasaron|ok\b)|todo[[:space:]]+(en verde|ok\b)|sin[[:space:]]+errores|(esta|está)[[:space:]]+verificado|(comprobe|comprobé|confirme|confirmé)[[:space:]]+que|it[[:space:]]+works\b|works[[:space:]]+as[[:space:]]+(intended|expected)|(tested|verified)[[:space:]]+it\b|tests?[[:space:]]+(pass|passed)\b|working[[:space:]]+correctly'
}

# nv_gate_texto_corregido <texto_original>
#   Prefijo honesto que se le antepone a la respuesta cuando el modelo insiste con la afirmacion.
#   NO se rechaza el turno una segunda vez: rechazar en bucle quema el presupuesto entero y deja
#   al usuario sin nada (medido en la guarda de documento: un turno se comio 10 minutos asi). Se deja
#   pasar la respuesta y se corrige lo unico inaceptable, que es la afirmacion sin prueba.
nv_gate_texto_corregido() {
  printf 'Ojo: no llegué a comprobarlo. En este turno no corrí ningún comando que lo pruebe, así que tomá lo de abajo como NO verificado.\n\n%s' "${1:-}"
}

# nv_gate_observacion_rechazo
#   Lo que se le devuelve al modelo la PRIMERA vez. Tiene que decirle como conseguir la prueba,
#   no solo que le falta: un rechazo sin salida es el camino directo al corta-bucles.
nv_gate_observacion_rechazo() {
  cat <<'EOF'
ERROR: tu respuesta afirma que algo funciona, anda, pasa los tests o quedó verificado, pero en este turno no corriste NINGÚN comando que lo pruebe (no hubo ningún 'exec' con exit 0, ni una verificación independiente que pasara). Escribir el código no es probarlo.

Hacé una de estas dos cosas:
1. Probalo de verdad ahora: {"tool":"exec","code":"<el comando que lo ejercita: correr el test, llamar al script, imprimir el resultado>"} y recién después terminá, contando lo que devolvió.
2. Si no lo podés probar (falta una dependencia, hace falta la app abierta, depende de algo del usuario), decilo así en tu respuesta final: qué escribiste, qué NO pudiste comprobar y con qué comando lo comprobaría él.

Lo que no podés hacer es afirmar que funciona sin haberlo corrido.
EOF
}
