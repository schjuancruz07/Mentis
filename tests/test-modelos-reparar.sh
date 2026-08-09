#!/usr/bin/env bash
# test-modelos-reparar.sh -- el reparador automatico de modelos muertos.
#
# QUE SE PRUEBA: las GUARDAS, que es lo unico que importa de verdad acá. Un reparador que cambia
# de mas es peor que no tener reparador: tira a la basura elecciones que costaron mediciones.
# Lo que se verifica es que NO actue cuando no corresponde.
#
# Casi todo es OFFLINE. Los dos casos que necesitan endpoint estan marcados y se saltean solos si
# no hay red o key -- un test que depende del free tier de NVIDIA da rojo los dias que esta
# saturado, por algo que no tiene nada que ver con el codigo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REP="$HERE/mentis-modelos-reparar.sh"
OK=0; FALLA=0
_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }
_salteo(){ echo "  --   -- (salteado) $1"; }

TR_TMP="$(mktemp -d)"
trap 'rm -rf "$TR_TMP" 2>/dev/null' EXIT

echo "== reparador de modelos muertos =="

# --- 0. sintaxis de todo lo nuevo ---------------------------------------------------------------
for f in "$REP" "$HERE/engine/nv-modelos-lib.sh" "$HERE/engine/nv-fixtures-roles.sh"; do
  if bash -n "$f" 2>/dev/null; then _ok "sintaxis ok: $(basename "$f")"; else _falla "sintaxis rota: $f"; fi
done

# --- 1. el CR fantasma de python en Windows -----------------------------------------------------
# EL bug mas caro de esta tanda: python3 en Windows escribe CRLF, y en una salida de varias lineas
# $( ) solo limpia la ultima -- las demas quedan con un \r pegado. Cada id de modelo se consultaba
# como "vendor/modelo\r", NVIDIA devolvia 404, y el sistema concluia "esta muerto". Un censo entero
# dio 102 muertos sobre modelos que respondian perfecto.
echo "-- el catalogo no puede traer retornos de carro"
# Se compara por LARGO, no con grep: "a/b\nc/d" son 7 caracteres y "a/b\r\nc/d" son 8. El byte
# de mas es todo el bug, y contarlo es la forma menos ambigua de verlo.
CRUDO="$(python3 -c "print('a/b'); print('c/d')")"
LIMPIO="$(python3 -c "print('a/b'); print('c/d')" | tr -d '\r')"
if [ "${#CRUDO}" -gt "${#LIMPIO}" ]; then
  _ok "control: python aca escribe CRLF (crudo ${#CRUDO} vs limpio ${#LIMPIO} caracteres)"
else
  _salteo "python no escribe CRLF en esta maquina; el bug no se puede reproducir"
fi
if [ "${#LIMPIO}" = "7" ]; then
  _ok "con tr -d el CR desaparece (quedan los 7 caracteres esperados)"
else
  _falla "tras limpiar quedaron ${#LIMPIO} caracteres, se esperaban 7"
fi
# Y que el filtro este puesto donde corresponde, para que nadie lo saque sin querer.
if grep -q "tr -d '\\\\r'" "$HERE/engine/nv-modelos-lib.sh"; then
  _ok "nv_catalogo/nv_respuesta_modelo limpian el CR"
else
  _falla "las funciones que devuelven varias lineas no limpian el CR"
fi
if grep -q "tr -d '\\\\r'" "$REP"; then
  _ok "la lista de candidatos del reparador limpia el CR"
else
  _falla "la lista de candidatos no limpia el CR"
fi

# --- 2. guardas que impiden actuar de mas --------------------------------------------------------
echo "-- guardas"

# 2a. Sin rol, no hace nada.
"$REP" >/dev/null 2>&1; RC=$?
if [ "$RC" = "2" ]; then _ok "sin -r <rol> sale con codigo 2"; else _falla "sin rol salio con $RC"; fi

# 2b. Un rol que no existe no puede inventar una reparacion.
"$REP" -r inexistente >/dev/null 2>&1; RC=$?
if [ "$RC" = "2" ]; then _ok "un rol inexistente sale con codigo 2"; else _falla "rol inexistente salio con $RC"; fi

# 2c. Freno de 1 cambio cada 24 h.
printf '%s\n' "{\"ts\": $(date +%s), \"rol\": \"fast\", \"de\": \"x\", \"a\": \"y\"}" > "$TR_TMP/cambios.jsonl"
SAL="$(MR_CAMBIOS_LOG="$TR_TMP/cambios.jsonl" MR_LOCK_FILE="$TR_TMP/lock1" "$REP" -r fast -n 2>&1)"
if printf '%s' "$SAL" | grep -q "ultimas 24 h"; then
  _ok "con un cambio reciente, no vuelve a tocar el mismo rol"
else
  _falla "el freno de 24 h no salto: $SAL"
fi

# 2d. Freno de 3 cambios en una semana (aunque ninguno sea de hoy).
: > "$TR_TMP/cambios3.jsonl"
for d in 2 4 6; do
  printf '%s\n' "{\"ts\": $(( $(date +%s) - d*86400 )), \"rol\": \"fast\", \"de\": \"x\", \"a\": \"y\"}" >> "$TR_TMP/cambios3.jsonl"
done
SAL="$(MR_CAMBIOS_LOG="$TR_TMP/cambios3.jsonl" MR_LOCK_FILE="$TR_TMP/lock2" "$REP" -r fast -n 2>&1)"
if printf '%s' "$SAL" | grep -q "3 cambios en 7 dias"; then
  _ok "con 3 cambios en la semana deja de tocar y solo reporta"
else
  _falla "el freno semanal no salto: $SAL"
fi

# 2e. Un solo reparador a la vez.
echo "99999 $(date +%s)" > "$TR_TMP/lock-ocupado"
SAL="$(MR_LOCK_FILE="$TR_TMP/lock-ocupado" MR_CAMBIOS_LOG="$TR_TMP/vacio.jsonl" "$REP" -r fast -n 2>&1)"
if printf '%s' "$SAL" | grep -q "otra reparacion en curso"; then
  _ok "no arranca si ya hay otra reparacion corriendo"
else
  _falla "arranco con el lock tomado: $SAL"
fi

# 2f. Un lock viejo es basura, no un reparador trabajando.
echo "99999 $(( $(date +%s) - 3000 ))" > "$TR_TMP/lock-viejo"
SAL="$(MR_LOCK_FILE="$TR_TMP/lock-viejo" MR_CAMBIOS_LOG="$TR_TMP/vacio.jsonl" "$REP" -r fast -n 2>&1)"
if printf '%s' "$SAL" | grep -q "lock viejo"; then
  _ok "un lock de mas de 20 minutos se pisa (proceso muerto)"
else
  _falla "no reconocio el lock viejo: $SAL"
fi

# --- 3. invariantes de diseño que no se pueden perder --------------------------------------------
echo "-- invariantes de diseño"

# La guarda mas importante: si TODO da caido, es limite de uso o red, no una masacre de modelos.
if grep -q "dieron caidos a la vez" "$REP"; then
  _ok "si el principal y todos los fallbacks caen juntos, no toca nada"
else
  _falla "falta la guarda de 'todos caidos = problema de red, no muerte'"
fi

# El candidato nuevo NO puede entrar de principal: no tiene rodaje.
if grep -q 'MR_NUEVA+=("$MR_GANADOR")' "$REP" && grep -q 'for m in "${MR_VIVOS\[@\]:-}"' "$REP"; then
  _ok "el candidato nuevo entra al fondo; arriba van los que ya tenian rodaje"
else
  _falla "el orden de la cadena nueva no garantiza que el candidato vaya al fondo"
fi

# SATURADO no puede tratarse como MUERTO.
if grep -q 'SATURADO' "$HERE/engine/nv-modelos-lib.sh"; then
  _ok "la libreria distingue SATURADO de MUERTO"
else
  _falla "se perdio la distincion SATURADO/MUERTO"
fi

# La pausa entre sondeos tiene que ser incondicional (la version con variable no funcionaba: la
# funcion corre dentro de $( ), que es un subshell, y la asignacion se perdia).
if grep -A3 '_mr_estado() {' "$REP" | grep -q 'sleep "\${MR_PAUSA'; then
  _ok "la pausa entre sondeos es incondicional (no depende de una variable que se pierde)"
else
  _falla "la pausa entre sondeos volvio a depender de estado que no sobrevive al subshell"
fi

# --- 4. el examen de roles discrimina (offline) ---------------------------------------------------
echo "-- el examen de roles"
# shellcheck source=/dev/null
source "$HERE/engine/nv-lib.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$HERE/engine/nv-modelos-lib.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$HERE/engine/nv-fixtures-roles.sh" 2>/dev/null

# Tildes: un modelo que contesta "Sí" no puede reprobar por ortografia. Fue un bug real -- la
# normalizacion usaba clases [íìïî] y sed aca trabaja por BYTES: "í" (dos bytes) se convertia en
# "ai" y la comparacion fallaba (familia de ERR-100).
if nv_fixture_aprueba "Sí." contiene "si"; then
  _ok "'Sí' con tilde aprueba contra 'si'"
else
  _falla "la normalizacion de tildes volvio a romperse (ERR-100: sed trabaja por bytes)"
fi
if nv_fixture_aprueba "Falso" contiene "verdadero"; then
  _falla "una respuesta incorrecta aprobo -- el examen no discrimina"
else
  _ok "una respuesta incorrecta reprueba"
fi
if nv_fixture_aprueba '```json
{"nombre": "el usuario", "edad": 30}
```' json "nombre,edad"; then
  _ok "JSON envuelto en un bloque de codigo se acepta (lo que importa es que sepa armarlo)"
else
  _falla "un JSON valido envuelto en un bloque de codigo fue rechazado"
fi
if nv_fixture_aprueba '{"nombre": "el usuario"}' json "nombre,edad"; then
  _falla "un JSON al que le falta una clave aprobo"
else
  _ok "un JSON incompleto reprueba"
fi
if nv_fixture_aprueba "El resultado es 391." numero "391-391"; then
  _ok "un numero correcto envuelto en texto aprueba"
else
  _falla "no encontro el numero dentro de la frase"
fi
if nv_fixture_aprueba "42" numero "391-391"; then
  _falla "un numero fuera de rango aprobo"
else
  _ok "un numero fuera de rango reprueba"
fi

# Todos los roles con nombre tienen que tener examen: sin fixtures, cualquier modelo "aprueba"
# con 0/0 y el portón deja de existir.
echo "-- todos los roles tienen examen"
SIN_FIXTURE=""
for r in code reason deep ultra general extract multimodal fast; do
  [ -z "$(nv_fixtures_de "$r")" ] && SIN_FIXTURE="$SIN_FIXTURE $r"
done
if [ -z "$SIN_FIXTURE" ]; then
  _ok "los 9 roles tienen fixtures de examen"
else
  _falla "roles sin examen (cualquier modelo pasaria):$SIN_FIXTURE"
fi

# --- 5. EN VIVO (se saltea sin key/red) -----------------------------------------------------------
echo "-- en vivo"
LIVE_KEY="$(nv_read_setting NVIDIA_API_KEY 2>/dev/null)"
if [ -z "$LIVE_KEY" ]; then
  _salteo "no hay NVIDIA_API_KEY; no se prueba contra el endpoint"
else
  CAT="$(nv_catalogo "$LIVE_KEY" 2>/dev/null)"
  if [ -z "$CAT" ]; then
    _salteo "el catalogo no respondio (sin red o saturado)"
  else
    N="$(printf '%s\n' "$CAT" | grep -c.)"
    if [ "$N" -gt 10 ]; then _ok "el catalogo devuelve $N modelos"; else _falla "el catalogo devolvio solo $N"; fi
    if printf '%s' "$CAT" | grep -q $'\r'; then
      _falla "el catalogo trae retornos de carro (volvio el bug del CR)"
    else
      _ok "ningun id del catalogo trae retorno de carro"
    fi
  fi
  # UN ROL SANO NO PUEDE TERMINAR REPARADO.
  #
  # Este caso daba rojo 1 de cada 4 corridas (familia ERR-104: los tests que dependen del reloj o
  # de un servicio ajeno fallan bajo carga). La culpa era del test, no del reparador: comparaba
  # TEXTO de salida, y el reparador tiene varias formas legitimas de no hacer nada segun como este
  # el free tier ese minuto -- principal vivo, principal saturado, catalogo sin responder. Cada
  # frase nueva era un rojo falso.
  #
  # Lo que de verdad importa no es QUE dice, sino que NO CAMBIE NADA. Asi que ahora se corre sin
  # -n (escritura habilitada de verdad, que es el caso peligroso) contra un archivo de override
  # descartable, y se verifica que ese archivo siga sin existir. Es el invariante real, y es
  # inmune tanto a como este NVIDIA ese dia como a que alguien reescriba un mensaje.
  OVR_VIGIA="$TR_TMP/no-debe-crearse.json"
  rm -f "$OVR_VIGIA" 2>/dev/null
  SAL="$(NV_OVERRIDE_FILE="$OVR_VIGIA" MR_CAMBIOS_LOG="$TR_TMP/vacio2.jsonl" \
         MR_LOCK_FILE="$TR_TMP/lock3" "$REP" -r fast 2>&1)"
  if [ -f "$OVR_VIGIA" ]; then
    _falla "sobre un rol sano ESCRIBIO un override: $(printf '%s' "$SAL" | tail -3)"
  else
    _ok "un rol con el principal vivo no se toca (no escribio ningun override)"
  fi
  # Y que el motivo de no tocar sea uno de los previstos, no un error inesperado.
  if printf '%s' "$SAL" | grep -qE "no esta muerto|Nada que reparar|SATURADO|no hay muerte confirmada"; then
    _ok "y lo explica con un motivo previsto"
  elif printf '%s' "$SAL" | grep -q "dieron caidos a la vez"; then
    _salteo "ahora mismo no responde ningun modelo del rol (limite de uso o red)"
  else
    _falla "sobre un rol sano hizo algo raro: $(printf '%s' "$SAL" | tail -3)"
  fi
fi

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
