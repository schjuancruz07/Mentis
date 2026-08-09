#!/usr/bin/env bash
# test-contexto.sh -- que Mentis traiga lo que ya hablaron ANTES, sin que el usuario se lo pida.
#
# EL PROBLEMA (reportado por el usuario, 2026-07-30): "no recuerda otros chats por sí solo". La
# herramienta para buscar en charlas viejas (mentis-recordar.sh) ya existía y el agente ya la
# tenía en su protocolo -- pero dependía de que se le ocurriera usarla, y no se le ocurría.
#
# LA REGLA QUE SE APLICA acá es la misma que el usuario ya había impuesto para los disparadores: lo que
# tiene que pasar SIEMPRE no puede depender de una probabilidad. Por eso la búsqueda la dispara
# una frase, no el criterio del modelo.
#
# Se prueba con un mentis-recordar.sh de mentira: lo que importa es si el bloque llega al prompt,
# no qué tan buena es la búsqueda semántica.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FALLO=0
_ok()  { echo "ok: $1"; PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1"; FALLO=$((FALLO+1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/engine"
cp "$DIR/mentis-chat.sh" "$SB/"
cp "$DIR/engine/nv-lib.sh" "$DIR/engine/nv-classify-lib.sh" "$SB/engine/"
cp "$DIR/mentis-hooks.sh" "$SB/" 2>/dev/null || true

cat > "$SB/engine/nv-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MC_TEST_PROMPT"
echo "listo"
STUB
chmod +x "$SB/engine/nv-agent.sh"

# mentis-recordar de mentira: devuelve algo reconocible para poder buscarlo en el prompt.
cat > "$SB/mentis-recordar.sh" <<'RECSTUB'
#!/usr/bin/env bash
echo "[2026-07-15] el usuario: quedamos en usar KDE Connect ---MARCA-DEL-PASADO---"
RECSTUB
chmod +x "$SB/mentis-recordar.sh"

_prompt_de() {   # _prompt_de "<mensaje>" -> imprime el prompt que recibió el agente
  local marca="$SB/prompt-$RANDOM.txt"
  : > "$marca"
  MC_TEST_PROMPT="$marca" STATEFILE="$SB/state.json" WORKSPACE_DEFAULT="$SB/work" \
  CAPABILITIES_DIR="$SB/nocap" MENTIS_DISPARADORES="$SB/nodisp.json" \
    bash "$SB/mentis-chat.sh" -H "$SB/hist-$RANDOM.jsonl" <<< "$1
salir" >/dev/null 2>&1
  cat "$marca" 2>/dev/null
}

echo "== 0. GUARDIA: el sandbox ejecuta de verdad =="
P="$(_prompt_de "una pregunta cualquiera sobre nada")"
if [ -n "${P// }" ]; then
  _ok "el chat armó el prompt y llamó al agente"
else
  _bad "el chat no llegó a llamar al agente -- lo de abajo no significa nada"
  echo; echo "RESULTADO: $PASS ok, $FALLO fallos."; exit 1
fi

echo "== 1. un mensaje que da por sabido algo TRAE el pasado =="
for frase in \
  "seguimos con lo que hablamos ayer" \
  "acordate de lo que te dije sobre el firewall" \
  "como quedamos la otra vez, arranca vos" \
  "el proyecto ese que te conte, en que quedo" \
  "me dijiste que era mejor la otra opcion"; do
  P="$(_prompt_de "$frase")"
  case "$P" in
    *"---MARCA-DEL-PASADO---"*) _ok "\"$frase\" -> buscó en las charlas viejas" ;;
    *) _bad "\"$frase\" -> NO buscó: sigue dependiendo de que al modelo se le ocurra" ;;
  esac
done

echo "== 2. el bloque llega con una etiqueta que explica qué es =="
P="$(_prompt_de "seguimos con lo que hablamos ayer")"
case "$P" in
  *"LO QUE YA HABLARON ANTES SOBRE ESTO"*) _ok "el prompt rotula de dónde salió ese texto" ;;
  *) _bad "el pasado llega sin etiqueta: el modelo no sabe que son charlas reales con fecha" ;;
esac

echo "== 3. un mensaje normal NO gasta una búsqueda =="
for frase in \
  "implementame una funcion en python que ordene una lista" \
  "que hora es" \
  "gracias mentis" \
  "generame una imagen de un perro"; do
  P="$(_prompt_de "$frase")"
  case "$P" in
    *"---MARCA-DEL-PASADO---"*) _bad "\"$frase\" -> buscó en el pasado sin motivo (gasta tiempo en cada mensaje)" ;;
    *) _ok "\"$frase\" -> no buscó, como corresponde" ;;
  esac
done

echo "== 4. se ve como paso, para saber que lo hizo =="
# La línea va con el formato de los pasos del motor, así aparece en el panel de la app y en la
# página del celular: si busca en tus charlas viejas, tenés que poder verlo.
SALIDA="$(MC_TEST_PROMPT="$SB/p.txt" STATEFILE="$SB/state.json" WORKSPACE_DEFAULT="$SB/work" \
  CAPABILITIES_DIR="$SB/nocap" MENTIS_DISPARADORES="$SB/nodisp.json" \
  bash "$SB/mentis-chat.sh" -H "$SB/hist-paso.jsonl" <<< "seguimos con lo que hablamos ayer
salir" 2>&1 >/dev/null)"
case "$SALIDA" in
  *"iter 0: recordar"*) _ok "el paso 'recordar' se emite y se va a ver en pantalla" ;;
  *) _bad "no se emite el paso: la búsqueda pasaría invisible" ;;
esac

echo "== 5. si la búsqueda falla, el turno sigue igual =="
cat > "$SB/mentis-recordar.sh" <<'ROTO'
#!/usr/bin/env bash
echo "explotó" >&2
exit 1
ROTO
chmod +x "$SB/mentis-recordar.sh"
P="$(_prompt_de "seguimos con lo que hablamos ayer")"
if [ -n "${P// }" ]; then
  _ok "con la búsqueda rota, el turno se arma igual (no puede dejarlo mudo)"
else
  _bad "una búsqueda fallida rompió el turno entero"
fi
case "$P" in
  *"LO QUE YA HABLARON ANTES SOBRE ESTO"*) _bad "metió la sección vacía en el prompt" ;;
  *) _ok "y no ensucia el prompt con una sección vacía" ;;
esac

# --- perfil + memorias: un solo python en vez de tres (2026-08-03) ------------------------------
# _mc_load_profile, _mc_load_user_memory y _mc_load_self_memory leen el MISMO archivo, y cada
# arranque de interprete cuesta ~0,33 s en esta maquina. _mc_load_settings_bloques los devuelve
# juntos, separados por 0x1f.
#
# Lo que se prueba no es que "ande", sino que devuelva EXACTAMENTE lo mismo que los tres de
# antes. Una optimizacion de contexto que cambia el contexto no es una optimizacion: es un
# cambio de comportamiento disfrazado de mejora de velocidad, y del tipo que nadie nota hasta
# que Mentis se olvida de como se llama el usuario.
# Se sourcea la copia del sandbox en un SUBSHELL: este test corre mentis-chat.sh como
# subproceso, no lo tiene sourceado, y sourcearlo en el shell principal pisaria variables del
# propio test (ERR-110: HISTFILE es una variable de bash y mentis-chat.sh la reasigna).
# Archivo de perfil PROPIO del test, no el real del usuario: asi el resultado no depende de que el
# tenga cargado en la app, y el test dice lo mismo en cualquier maquina.
#
# VA EN "$SB/mentis-settings.json" Y NO EN UNA RUTA A ELECCION, Y NO ES UN DETALLE: sourcear
# mentis-chat.sh REASIGNA MENTIS_SETTINGS_FILE a "$MENTIS_ENV_DIR/mentis-settings.json", asi que
# cualquier valor que le ponga el llamador antes del source se pierde en silencio. Es ERR-110
# otra vez, ahora con otra variable: la primera version de este chequeo exportaba la ruta del
# fixture y el test leia el archivo equivocado -- o sea ninguno -- y reportaba que la funcion
# estaba rota cuando andaba perfecto.
cat > "$SB/mentis-settings.json" <<'FIXT'
{"profile":{"fullName":"el usuario Cruz","nickname":"Sr.","customRole":"programar",
"instructions":"responder en espanol","userMemory":"le gusta el mate",
"selfMemory":"soy Mentis, corro en la máquina del usuario"}}
FIXT

_bloques_de() {
  bash -c '
    source "$1" >/dev/null 2>&1
    declare -F _mc_load_settings_bloques >/dev/null || exit 1
    B="$(_mc_load_settings_bloques)" || exit 1
    printf "%s\x1e%s\x1e%s\x1e%s" "$B" "$(_mc_load_profile)" "$(_mc_load_user_memory)" "$(_mc_load_self_memory)"
  ' _ "$SB/mentis-chat.sh" 2>/dev/null
}
TODO="$(_bloques_de)"
BLOQUES="${TODO%%$'\x1e'*}"
_T1="${TODO#*$'\x1e'}"; V_PERFIL="${_T1%%$'\x1e'*}"
_T2="${_T1#*$'\x1e'}";  V_USUARIO="${_T2%%$'\x1e'*}"
V_PROPIA="${_T2#*$'\x1e'}"
if [ -n "$BLOQUES" ]; then
  N_PERFIL="${BLOQUES%%$'\x1f'*}"
  N_RESTO="${BLOQUES#*$'\x1f'}"
  N_USUARIO="${N_RESTO%%$'\x1f'*}"
  N_PROPIA="${N_RESTO#*$'\x1f'}"
  [ "$N_PERFIL" = "$V_PERFIL" ] \
    && _ok "el perfil sale identico al del camino viejo" \
    || _bad "el perfil cambio: nuevo='${N_PERFIL:0:40}' viejo='${V_PERFIL:0:40}'"
  [ "$N_USUARIO" = "$V_USUARIO" ] \
    && _ok "la memoria sobre el usuario sale identica" \
    || _bad "la memoria sobre el usuario cambio"
  [ "$N_PROPIA" = "$V_PROPIA" ] \
    && _ok "la memoria sobre Mentis sale identica" \
    || _bad "la memoria sobre Mentis cambio"
else
  _bad "_mc_load_settings_bloques no devolvio nada (el turno caeria al camino lento siempre)"
fi

# Y que el separador no aparezca dentro del contenido: si algun dia un perfil trajera un 0x1f,
# el corte partiria mal y el perfil se comeria la memoria.
case "$BLOQUES" in
  *$'\x1f'*$'\x1f'*$'\x1f'*) _bad "hay mas de dos separadores: algun bloque trae 0x1f adentro" ;;
  *$'\x1f'*$'\x1f'*)         _ok "exactamente dos separadores (los tres bloques se cortan bien)" ;;
  *)                         _bad "faltan separadores en la salida" ;;
esac

echo
echo "RESULTADO: $PASS ok, $FALLO fallos."
[ "$FALLO" -eq 0 ] || exit 1
