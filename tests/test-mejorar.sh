#!/usr/bin/env bash
# test-mejorar.sh -- los dos primeros escalones de auto-mejora (F1 y F2, 2026-08-03).
#
# QUE ES: el usuario pidió que Mentis "solo me necesite a mí para saber cuándo, y a él para mejorarse".
#   actualizar (F1) -- revisa el catálogo, examina los candidatos, PROPONE.
#   reparar    (F2) -- mira sus propias señales de falla y PROPONE el diagnóstico.
#
# LO QUE ESTE TEST PROTEGE NO ES QUE FUNCIONE, ES QUE NO SE PASE DE LA RAYA. Un sistema que se
# modifica solo tiene un modo de falla que ninguno de los otros tiene: hacer un cambio correcto en
# el momento equivocado, o uno incorrecto con total confianza. Los chequeos de abajo son casi
# todos sobre los frenos:
#   - que NUNCA aplique nada solo (decisión explícita del usuario);
#   - que valide cada modelo con una llamada REAL antes de proponerlo (el catálogo miente, ERR-003);
#   - que el que mide no sea el que opina;
#   - que 'reparar' NO lea la bitácora de Claude Code, que mezcla errores ajenos;
#   - que toda propuesta diga qué NO se midió.
set -uo pipefail
TM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_ROOT="$(cd "$TM_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TM_OK=0; TM_MAL=0
_ok()  { TM_OK=$((TM_OK+1));  echo "  OK   $1"; }
_mal() { TM_MAL=$((TM_MAL+1)); echo "  MAL  $1  ($2)"; }

S="$TM_ROOT/mentis-mejorar.sh"
[ -f "$S" ] || { echo "ABORTA: no existe $S" >&2; exit 1; }

TM_TMP="$(mktemp -d)"
case "$TM_TMP" in "$TM_ROOT"|"$TM_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TM_TMP"' EXIT

echo "== auto-mejora: escalones 1 y 2 =="
echo "-- A. los frenos"

bash -n "$S" && _ok "A1 compila" || _mal "A1 compila" "error de sintaxis"

# A2: EL FRENO PRINCIPAL. 'actualizar' y 'reparar' no pueden escribir el override; solo el
# subcomando 'aplicar', que corre el usuario a mano.
if awk '/^if \[ "\$1" = "actualizar" \]/,/^fi$/' "$S" | grep -q "modelos-override.json"; then
  _mal "A2 actualizar no aplica solo" "el escalon 1 escribe el override directamente"
else
  _ok "A2 'actualizar' NO toca el override: solo escribe una propuesta"
fi
# A3 buscaba la sola MENCION de "modelos-override.json" en todo el texto desde 'reparar' hasta el
# final del archivo. Daba MAL desde el 2026-08-04, cuando 'reparar' empezo a LEER el override para
# contar telemetria (mentis-mejorar.sh:295, que le pasa la ruta a un python que solo la lee y
# escribe a stdout). O sea: el freno nunca se rompio, el test se volvio ciego a la diferencia
# entre leer y escribir. Y un test de seguridad que da alarma falsa todos los dias deja de
# proteger, porque el dia que la alarma sea de verdad ya nadie la mira.
# Ahora se busca ESCRITURA sobre el archivo -- redireccion, mv, cp o tee -- que es lo que el freno
# de verdad prohibe. Leerlo esta bien y siempre lo estuvo.
if awk '/^if \[ "\$1" = "reparar" \]/,0' "$S" \
   | grep -qE '(>|>>)[[:space:]]*"?[^"|]*modelos-override\.json|(mv|cp|tee)[[:space:]][^|]*modelos-override\.json'; then
  _mal "A3 reparar no aplica solo" "el escalon 2 ESCRIBE el override"
else
  _ok "A3 'reparar' tampoco aplica nada: solo diagnostica (leer el override esta permitido)"
fi

# A4: el catalogo MIENTE (ERR-003). Cada candidato se prueba con una llamada real.
grep -q "nv_respuesta_modelo" "$S" && grep -qi "catalogo lista modelos que no existen" "$S" \
  && _ok "A4 valida cada candidato con una llamada real antes de examinarlo" \
  || _mal "A4 valida contra la API" "confiaria en /v1/models, que lista modelos inexistentes"

# A5: y esa libreria tiene que estar SOURCEADA. Bug real de hoy: sin sourcear nv-modelos-lib.sh la
# funcion no existe, cada prueba devuelve vacio, y el script concluye "ninguno de los 76
# candidatos contesto" -- un error de carga con forma de medicion.
grep -q "source \"\$HERE/engine/nv-modelos-lib.sh\"" "$S" \
  && _ok "A5 sourcea nv-modelos-lib.sh (sin eso 'nadie contesta' y parece una medicion)" \
  || _mal "A5 sourcea la libreria" "nv_respuesta_modelo no existiria y todo daria vacio"

# A6: rondas acotadas. Sin tope, examinar 76 candidatos son cientos de llamadas.
grep -q "MENTIS_MEJORAR_MAX" "$S" \
  && _ok "A6 tope de candidatos por corrida" \
  || _mal "A6 rondas acotadas" "una corrida podria gastar la cuota entera"

# A7: no usa el modo sin frenos.
grep -qE '\-x\b|ALLOW_DANGEROUS' "$S" \
  && _mal "A7 sin modo sin frenos" "el mejorador no necesita permisos destructivos" \
  || _ok "A7 no usa el modo sin frenos"

echo "-- B. quien mide y quien opina"

# B1: el veredicto sale de un examen con respuestas verificables, no de otro modelo opinando.
# Es mas fuerte que un juez independiente: no hay opinion en el medio.
grep -q "nv_puntaje_modelo" "$S" \
  && _ok "B1 el veredicto sale de fixtures verificables, no de la opinion de un modelo" \
  || _mal "B1 medicion objetiva" "un modelo juzgando a otro es el sesgo autor=verificador"

# B2: empatar en calidad y ser un poquito mas rapido NO alcanza para mover algo que costo medir.
grep -q "lt 80" "$S" \
  && _ok "B2 exige mas aciertos, o empate con 20% menos de latencia" \
  || _mal "B2 umbral de mejora" "cambiaria por ruido de medicion"

# B3: toda propuesta declara lo que NO se midio.
grep -q '"no_medido"' "$S" \
  && _ok "B3 cada propuesta dice que NO se midio" \
  || _mal "B3 honestidad" "prometeria mas de lo que probo"

echo "-- C. las fuentes de 'reparar'"

# C1: LA CORRECCION QUE SALIO DE LA AUTOCRITICA DEL PLAN. La bitacora de errores es de Claude
# Code y mezcla sus errores con los de Mentis; leerla la pondria a perseguir equivocaciones ajenas.
# Se miran SOLO las lineas de codigo: el comentario nombra la bitacora a proposito, porque explica
# por que NO se la lee. Es la tercera vez hoy que un chequeo estructural falla por leer prosa --
# ya paso en test-modelos-override y en test-drive. Un test que grita en falso entrena a quien lo
# lee a ignorarlo, que es peor que no tenerlo.
if grep -vE '^\s*#' "$S" | grep -q "bitacora-errores"; then
  _mal "C1 no lee la bitacora ajena" "leeria los errores de Claude Code como si fueran suyos"
else
  _ok "C1 NO lee la bitacora de Claude Code (mezcla errores ajenos)"
fi

grep -q "NV_LOGFILE" "$S" \
  && _ok "C2 usa su propia telemetria" \
  || _mal "C2 telemetria propia" "sin datos propios no puede diagnosticarse"

grep -q "tests/\$t.sh" "$S" \
  && _ok "C3 corre sus propias suites" \
  || _mal "C3 suites propias" "no se enteraria de una regresion"

# C4: solo las suites RAPIDAS. Las que llaman a modelos tardan minutos, y esto tiene que poder
# correr programado sin comerse la cuota.
grep -q "Solo las RAPIDAS" "$S" \
  && _ok "C4 solo corre las suites que no gastan llamadas" \
  || _mal "C4 suites rapidas" "una corrida programada gastaria cuota"

grep -q "nv_stt_server" "$S" \
  && _ok "C5 chequea servidores duplicados (ERR-111, 1,6 GB cada uno)" \
  || _mal "C5 duplicados" "no detectaria la fuga que costo 3,2 GB"

echo "-- D. el ciclo de propuestas, probado de verdad"

# D1: 'propuestas' no puede romperse cuando no hay ninguna.
timeout 60 bash "$S" propuestas >/dev/null 2>&1 \
  && _ok "D1 'propuestas' anda aunque no haya ninguna" \
  || _mal "D1 listar propuestas" "falla con la lista vacia"

# D2: aplicar algo inexistente falla claro, no en silencio.
timeout 60 bash "$S" aplicar no-existe-nada >/dev/null 2>&1
[ $? -ne 0 ] && _ok "D2 aplicar una propuesta inexistente da error" \
             || _mal "D2 propuesta inexistente" "no aviso"

# D3: un diagnostico NO se puede 'aplicar' -- no es un cambio, es algo para leer.
mkdir -p "$TM_ROOT/propuestas"
FAKE="$TM_ROOT/propuestas/zzz-test-diag.json"
cat > "$FAKE" <<'JSON'
{"tipo":"diagnostico","titulo":"prueba","resumen":"prueba","no_medido":"prueba"}
JSON
timeout 60 bash "$S" aplicar zzz-test-diag >/dev/null 2>&1
[ $? -ne 0 ] && _ok "D3 un diagnostico no se puede 'aplicar' (no es un cambio)" \
             || _mal "D3 diagnostico no aplicable" "lo trato como si fuera un cambio de modelo"
rm -f "$FAKE"

# D4: aplicar una propuesta de modelo guarda el 'anterior', o revertir seria adivinar.
grep -q '"anterior"' "$S" \
  && _ok "D4 al aplicar, guarda el valor anterior (se puede revertir)" \
  || _mal "D4 reversibilidad" "no habria como volver atras"

# D5: y limpia la memoria corta, o el cambio no se sentiria hasta que venza el TTL.
grep -q "nv_memo_limpiar" "$S" \
  && _ok "D5 al aplicar, invalida la memoria corta (el cambio se siente YA)" \
  || _mal "D5 invalida el memo" "el cambio tardaria minutos en notarse"

echo "-- E. 'reparar' corriendo de verdad (no gasta llamadas)"
SAL="$(timeout 500 bash "$S" reparar 2>&1)"
if printf '%s' "$SAL" | grep -q "Buscando fallas propias"; then
  _ok "E1 'reparar' corre de punta a punta"
  printf '%s' "$SAL" | grep -qE "telemetria|suites|duplicados" \
    && _ok "E2 revisa las tres fuentes (telemetria, suites, procesos)" \
    || _mal "E2 tres fuentes" "falto alguna"
else
  _mal "E1 'reparar' corre" "$(printf '%s' "$SAL" | head -c 100)"
fi
# Limpieza: este test no puede dejarle propuestas de prueba al usuario.
for f in "$TM_ROOT/propuestas"/*-diagnostico.json; do
  [ -e "$f" ] || continue
  # Solo las de los ultimos 2 minutos, que son las que genero este test.
  if [ -n "$(find "$f" -mmin -2 2>/dev/null)" ]; then rm -f "$f"; fi
done

echo
echo "== $TM_OK OK, $TM_MAL MAL =="
[ "$TM_MAL" -eq 0 ]
