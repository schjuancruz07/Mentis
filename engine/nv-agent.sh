#!/usr/bin/env bash
# nv-agent.sh — loop agéntico para los modelos de apoyo NVIDIA (minado de hermes, liviano).
#
# El modelo de apoyo razona en un loop turno→herramienta→observación hasta producir una
# respuesta final, explorando un directorio en modo SOLO-LECTURA (enjaulado) y opcionalmente
# corriendo cómputo en el sandbox descartable de nv-lib. Reusa ask-nvidia.sh (fallback entre
# modelos, telemetría y guard de privacidad nv_redact ya incluidos).
#
# Uso:  nv-agent.sh [-d <dir_raiz>] [-m <rol>] [-i <max_iter>] [-w] "<tarea>"
#   -d  directorio raíz al que se enjaula la exploración (default: cwd). read/search no pueden salir.
#   -m  rol/modelo de ask-nvidia: reason|deep|code|general|ultra (default: reason).
#   -i  presupuesto de iteraciones (default 12).
#   -w  habilita escritura/ejecución real (write/exec). SIN este flag, el agente es 100%
#       solo-lectura (comportamiento idéntico a antes de v2). NUNCA pasar -w desde una
#       invocación automática (ej. fable5v2j-core.sh no la pasa y no debe pasarla).
#
# Protocolo de acción (JSON, sin function-calling — anda con cualquier modelo de chat):
#   {"tool":"read","path":"rel"} | {"tool":"search","query":"regex","path":"rel?"}
#   {"tool":"run","code":"bash"} (sandbox aislado, NO ve el repo) | {"tool":"done","answer":"..."}
#   {"tool":"write","path":"rel","content":"..."} | {"tool":"exec","code":"bash"} — solo con -w.
#   {"tool":"edit","path":"rel","old":"texto exacto","new":"reemplazo"} — cambia UN pedazo de un
#     archivo sin reescribirlo entero. Solo con -w. 'old' tiene que aparecer UNA sola vez.
#   OJO asimetría: "write" está enjaulado a la raíz (mismo mecanismo que "read"), pero "exec"
#   solo corre con cwd=raíz — un comando puede acceder fuera de la raíz vía rutas relativas
#   (ej. "cat../../algo"). "exec" es deliberadamente más potente que "write", no comparte su jaula.
set -euo pipefail
export PYTHONIOENCODING=utf-8   # sin esto, print() con emojis/no-ASCII (ej. 📄 de Drive real) revienta
                                 # con UnicodeEncodeError bajo el cp1252 default de Windows y aborta
                                 # el script entero (OBS queda vacío, set -e corta todo).
NVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MENTIS_ROOT: raiz de Mentis (un nivel arriba de engine/). Reemplaza el viejo "mentis-env/"
# relativo a NVDIR, que asumia el motor un nivel ARRIBA de mentis-env -- ahora es al reves,
# engine/ (donde vive este script) es hijo de la raiz de Mentis.
MENTIS_ROOT="$(cd "$NVDIR/.." && pwd)"
# Exportada para que los comandos de 'exec' puedan llamar a las capabilities de Mentis. El exec
# corre con el CWD en la carpeta de TRABAJO del turno, no en la raiz de Mentis, asi que un
# `bash capabilities/estructura.sh` falla con 127 y el modelo se queda buscando la carpeta
# (2026-08-12: paso exactamente eso en el primer turno del 3D de Science). Con esto, la forma
# correcta es `bash "$MENTIS_ROOT/capabilities/<lo que sea>.sh"` y funciona desde cualquier lado.
export MENTIS_ROOT
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"
# GATE DE COMPLETITUD: deteccion de "afirma que funciona" (funcion pura, medible sin correr
# turnos -- ver eval/gate-completitud/medir.sh). Se apaga con MENTIS_GATE_OFF=1.
# shellcheck source=/dev/null
source "$NVDIR/nv-gate-lib.sh"
# LOS TEXTOS QUE LEE EL MODELO viven en engine/textos/ y no adentro de este archivo (2026-08-15).
# Motivo medido: escritos como strings de bash hay que escapar cada comilla del JSON de ejemplo, y
# al editarlos los backslashes se colapsan -- ERR-159, cuatro parches rotos y uno que paso EN
# SILENCIO (el motor arrancaba y el modelo leia un protocolo mal formado). Ver nv-textos-lib.sh.
# shellcheck source=/dev/null
source "$NVDIR/nv-textos-lib.sh"

# Carpeta OBLIGATORIA de creaciones (pedido del usuario, 2026-07-12): todo lo que "gen" produce
# (imagen/3D/documento) va SIEMPRE acá, no a la raiz de trabajo efimera (ROOT) -- asi el usuario la
# encuentra organizada en su propia carpeta de Documentos sin tener que buscar en
# ~/Mentis/workspace-app. ROOT/write() no se tocan: siguen siendo el area de
# trabajo de la tarea en curso, no "creaciones" finales.
# El override por entorno existe SOLO para que los tests puedan ejercitar 'gen' de verdad sin
# ensuciar la carpeta real del usuario con archivos de prueba. En uso normal nadie define la variable
# y el valor es el de siempre (app/main.js:1348 asume esta misma ruta fija).
MENTIS_CREATIONS_DIR="${MENTIS_CREATIONS_DIR:-$HOME/Documents/Mentis}"

# Conectores: switch real persistido desde la app (pedido del usuario, 2026-07-14) -- lee
# connectorsEnabled[id] de mentis-settings.json (mismo archivo/mismo default "habilitado si
# nunca se toco" que mentis-app/lib/settings-store.js) para gatear exec/vscode/gen ademas de
# los flags -w/-e/-g de linea de comandos. Se lee via stdin (nunca python open() sobre una ruta
# MSYS, ver bitacora ERR-006).
MENTIS_SETTINGS_FILE="$MENTIS_ROOT/mentis-settings.json"
_connector_enabled() {
  local id="$1"
  [ -f "$MENTIS_SETTINGS_FILE" ] && CONN_ID="$id" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
    # La camara y el telefono arrancan APAGADOS: su default es False, no True. El resto sigue
    # habilitado mientras nadie lo apague. (Antes la camara caia en el default general y estaba
    # encendida sin que nadie la hubiera prendido -- ver settings-store.js.)
    apagados = ("local:webcam", "local:telefono")
    cid = os.environ["CONN_ID"]
    v = (data.get("connectorsEnabled") or {}).get(cid, cid not in apagados)
    print(1 if v else 0)
except Exception:
    print(0 if os.environ["CONN_ID"] in ("local:webcam", "local:telefono") else 1)
' < "$MENTIS_SETTINGS_FILE" || echo 1
}

# Computer-use en vivo (pedido del usuario, 2026-07-16): captura + describe, reusada por 'screen' Y
# 'control' -- antes 'control' no veia el resultado de sus propias acciones (tenia que pedir
# 'screen' de nuevo a mano en la siguiente iteracion). Ademas de describir para el modelo, copia
# la captura a una ruta FIJA (se pisa cada vez) para que la UI de Mentis la muestre en vivo
# mientras dura el turno -- ver main.js (parseo del marker de stderr "-> $LIVE_PREVIEW").
LIVE_PREVIEW="$MENTIS_ROOT/workspace/computer-use-live.jpg"
# Lo mismo para la camara: lo ultimo que vio, para poder mostrarlo mientras lo mira.
WEBCAM_PREVIEW="$MENTIS_ROOT/workspace/webcam-live.jpg"

# TOPE DURO DE CAMARA POR TURNO (2026-08-08, despues de un bucle real).
#
# QUE PASO: Mentis se quedo sacando fotos con la webcam una y otra vez. el usuario apreto el boton de
# frenar y no paso nada; recien paro cuando cerro la aplicacion entera.
#
# POR QUE NO ALCANZABA LO QUE YA HABIA: la unica proteccion contra repetir una herramienta era
# SAME_TOOL_STREAK, que (a) solo CUENTA repeticiones consecutivas -- basta intercalar otra
# herramienta para reiniciar la cuenta, algo que ya paso y esta documentado mas abajo en este
# mismo archivo -- y (b) no corta nada: le manda una NOTA al modelo pidiendole por favor que
# cambie de estrategia. Una proteccion que depende de que el modelo obedezca no es una proteccion.
#
# ESTO ES DISTINTO: es un numero, lo cuenta bash, y el modelo no puede discutirlo. Tres fotos
# alcanzan de sobra para cualquier uso legitimo ("mira", "y ahora?", "mira de nuevo"); a partir de
# ahi la camara se niega por el resto del turno, con un mensaje que el modelo entiende.
#
# El tope es POR TURNO y no por conversacion a proposito: cada mensaje nuevo del usuario es una
# intencion nueva, y no queremos que la camara quede inutilizada porque hace media hora hubo un
# bucle. Se puede subir con MENTIS_WEBCAM_MAX si algun dia hace falta de verdad.
#
# 2026-08-10: EL MISMO TOPE, AHORA PARA LAS CINCO INVASIVAS. Cuando se cerro el agujero de la
# camara quedo escrito que faltaba hacer lo mismo con `screen`, `control`, `telefono` y `arduino`:
# todas tenian permiso de encendido y ninguna tenia limite de uso. La regla que salio de aquello
# es la que se aplica aca: **un permiso responde "¿puede?"; hace falta responder "¿cuantas veces?"**.
#
# DE DONDE SALEN LOS NUMEROS: no son raciones, son cortacircuitos. Estan puestos bien por encima
# de lo que necesita un uso legitimo y bien por debajo de lo que gasta un bucle. Por eso `control`
# tiene 25 y la camara 3: llenar un formulario son veinte clicks razonables, mirar la habitacion
# veinte veces no es razonable nunca. Si alguno molesta en uso real, se sube por variable de
# entorno -- pero antes de subirlo conviene mirar POR QUE se llego al tope.
declare -A TOPE_MAX=(
  [webcam]="${MENTIS_WEBCAM_MAX:-3}"
  [screen]="${MENTIS_SCREEN_MAX:-6}"
  [control]="${MENTIS_CONTROL_MAX:-25}"
  [telefono]="${MENTIS_TELEFONO_MAX:-8}"
  [arduino]="${MENTIS_ARDUINO_MAX:-15}"
)
declare -A TOPE_USOS=()

# ¿Ya se paso del tope esta herramienta? Devuelve 0 (verdadero en bash) si YA NO puede usarse.
_tope_alcanzado() {
  local t="$1" max="${TOPE_MAX[$1]:-0}"
  [ "$max" -gt 0 ] || return 1          # sin tope declarado = sin limite
  [ "${TOPE_USOS[$t]:-0}" -ge "$max" ]
}

# Se suma SIEMPRE antes de ejecutar, nunca despues. Si se contara al terminar, un fallo a mitad de
# camino dejaria el contador quieto y el bucle podria seguir eternamente a base de intentos
# fallidos -- que es exactamente como se comporta un bucle.
_tope_sumar() {
  local t="$1"
  TOPE_USOS[$t]=$(( ${TOPE_USOS[$t]:-0} + 1 ))
}

# El mensaje de rechazo le dice al modelo que NO INSISTA y que cierre con lo que tenga. Sin esa
# ultima parte un modelo obstinado gasta el resto del presupuesto reintentando contra una puerta
# cerrada, y el turno termina sin respuesta igual.
_tope_mensaje() {
  local t="$1"
  printf 'ERROR: ya usaste "%s" %s veces en este turno, que es el maximo. No la pidas de nuevo: cerra con '"'"'done'"'"' explicando lo que conseguiste hasta aca, o segui con otra herramienta.' \
    "$t" "${TOPE_USOS[$t]:-0}"
}

# Se dejan los dos nombres viejos porque el bloque de la camara ya los usaba y son mas legibles
# ahi. Apuntan al mismo lugar que el resto.
WEBCAM_MAX="${TOPE_MAX[webcam]}"
# Los ojos de Mentis (2026-07-28). Saca UNA foto con la webcam y se la manda al modelo multimodal
# con el prompt que corresponda al uso. La cámara se prende y se apaga en el acto -- no hay ningún
# proceso mirando de fondo, y la luz de la webcam queda como la señal honesta de que se usó.
_webcam_mirar() {
  local proposito="$1" foto desc wc_prompt aviso
  foto="$(mktemp -u).jpg"
  aviso="$(bash "$MENTIS_ROOT/mentis-webcam.sh" -o "$foto" 2>&1 >/dev/null)"
  [ -f "$foto" ] || { printf 'ERROR: no pude usar la camara: %s' "$aviso"; return 1; }
  # Copia para que el usuario VEA lo que la camara vio (pedido suyo, 2026-07-30). Hasta ahora la foto
  # se describia y se borraba: el unico rastro era la descripcion que hacia un modelo, y no habia
  # forma de contrastarla con la imagen real. Es el mismo mecanismo que ya usa la pantalla
  # (LIVE_PREVIEW), archivo fijo que se pisa en cada uso -- no se acumulan fotos de la habitacion.
  mkdir -p "$(dirname "$WEBCAM_PREVIEW")" 2>/dev/null || true
  cp -f "$foto" "$WEBCAM_PREVIEW" 2>/dev/null || true
  case "$proposito" in
    leer)      wc_prompt="Leé y transcribí en español TODO el texto que se vea en esta foto (un papel, una pantalla, un envase, una etiqueta). Si hay una tabla o una lista, respetá su estructura. Si no llegás a leer algo con seguridad, decí explícitamente qué parte no se lee en vez de adivinarla." ;;
    presencia) wc_prompt="Mirá esta foto tomada por la webcam de una computadora de escritorio y respondé SOLO una de estas tres opciones, sin agregar nada: 'HAY ALGUIEN' si se ve una persona frente a la pantalla, 'NO HAY NADIE' si el asiento está vacío o no se ve gente, o 'NO SE DISTINGUE' si está muy oscuro o borroso para saberlo." ;;
    *)         wc_prompt="Describí en español, con detalle, qué se ve en esta foto tomada con la webcam. Si hay una persona, describí qué está haciendo y su expresión general, sin especular sobre su estado de ánimo. Si hay objetos o texto, nombralos. Si la imagen está muy oscura o no se distingue nada, DECILO en vez de inventar." ;;
  esac
  desc="$(bash "$NVDIR/ask-nvidia.sh" -r -I "$foto" multimodal "$wc_prompt" 2>/dev/null || true)"
  rm -f "$foto"
  [ -z "$desc" ] && { printf 'ERROR: la camara sacó la foto pero el modelo no la pudo describir.'; return 1; }
  # El aviso de "foto casi negra" viaja junto con la descripción: sin él, el modelo describe una
  # imagen negra como si hubiera visto algo, y eso llega como un hecho.
  if printf '%s' "$aviso" | grep -q "casi negra"; then
    printf '%s\n\n(OJO: %s -- si la descripcion de arriba afirma ver cosas, desconfiá.)' "$desc" "$(printf '%s' "$aviso" | sed 's/^AVISO: //')"
  else
    printf '%s' "$desc"
  fi
  return 0
}

_computer_use_snapshot() {
  local sshot desc
  sshot="$(mktemp -u).jpg"
  if bash "$MENTIS_ROOT/mentis-screen-capture.sh" -o "$sshot" >/dev/null 2>&1 && [ -f "$sshot" ]; then
    mkdir -p "$(dirname "$LIVE_PREVIEW")"
    cp -f "$sshot" "$LIVE_PREVIEW" 2>/dev/null || true
    desc="$(bash "$NVDIR/ask-nvidia.sh" -r -I "$sshot" multimodal "Describi en detalle y en español que se ve en esta captura de pantalla de escritorio: que ventanas/aplicaciones estan abiertas, que contenido o texto relevante se puede leer, y cualquier cosa que parezca importante para responder sobre el estado actual de la pantalla." 2>/dev/null || true)"
    rm -f "$sshot"
    [ -z "$desc" ] && desc="(no se pudo describir la captura)"
    printf '%s' "$desc"
    return 0
  else
    rm -f "$sshot"
    return 1
  fi
}

# --- jaula de rutas: resuelve rel contra ROOT y rechaza escapes (.., absolutas fuera) ---
_caged() {
  local req="$1" abs
  abs="$(realpath -m -- "$ROOT/$req" 2>/dev/null || true)"
  [ -z "$abs" ] && return 1
  case "$abs/" in
    "$ROOT"/*) printf '%s' "$abs"; return 0 ;;
    *) return 1 ;;
  esac
}

# Igual que _caged pero para el CORPUS DE ESTUDIO (modo Study), que vive fuera de la carpeta de
# trabajo. Devuelve la ruta solo si cae adentro del corpus: misma jaula, otro patio.
#
# POR QUE SE PERMITE LEERLO (2026-08-12): el corpus es material que el usuario cargo a proposito con
# '/estudiar sumar' para que Mentis lo estudie, y el prompt se lo cita como 'materia/archivo.md'.
# Al principio esto se rechazaba y se le explicaba al modelo que el contenido ya lo tenia en el
# prompt. No alcanzo: insistia con 'read' hasta que saltaba el detector de bucles y el turno se
# perdia entero (ERR-143). Y tenia razon en insistir -- el bloque del prompt trae los fragmentos
# mas parecidos a la pregunta, no el documento completo, asi que para resumir un apunte entero
# necesita abrirlo. Pelearle a un modelo que quiere hacer lo correcto es perder dos veces.
#
# NO ES UN AGUJERO: solo resuelve dentro de MENTIS_CORPUS_DIR, que solo esta seteada en un modo
# con corpus declarado, y cuyo contenido lo puso el usuario explicitamente para que se lea. El realpath
# es el que corta los '..' -- sin esa comprobacion, 'x/../../../etc/passwd' saldria del corpus.
_caged_corpus() {
  local req="$1" abs raiz
  [ -n "${MENTIS_CORPUS_DIR:-}" ] || return 1
  raiz="$(realpath -m -- "$MENTIS_CORPUS_DIR" 2>/dev/null || true)"
  [ -n "$raiz" ] || return 1
  abs="$(realpath -m -- "$raiz/$req" 2>/dev/null || true)"
  [ -z "$abs" ] && return 1
  case "$abs/" in
    "$raiz"/*) printf '%s' "$abs"; return 0 ;;
    *) return 1 ;;
  esac
}

# La ruta que 'read' va a abrir: primero la carpeta de trabajo y, si ahi no esta, el corpus de
# estudio. En ese orden, para que un archivo del turno nunca quede tapado por uno del corpus.
_ruta_leible() {
  local req="$1" abs
  if abs="$(_caged "$req")" && [ -e "$abs" ]; then printf '%s' "$abs"; return 0; fi
  if abs="$(_caged_corpus "$req")" && [ -e "$abs" ]; then printf '%s' "$abs"; return 0; fi
  # Nada existe: se devuelve la de la jaula igual, para que los mensajes de error de mas abajo
  # sigan hablando de la carpeta de trabajo, que es lo correcto cuando no hay corpus de por medio.
  _caged "$req"
}

# ¿La ruta que pidió el modelo es ABSOLUTA, en cualquiera de las formas que conviven en esta
# máquina? (bug real 2026-07-30). La detección vieja era un regex `^[A-Za-z]:\\` que sólo veía
# la forma con backslash: 'C:/Users/...' (la que imprime el generador de documentos) y
# '/c/Users/...' (la forma MSYS de la MISMA ruta) caían al error genérico "ruta inválida", que no
# explicaba nada -- así que el modelo reintentaba con la otra forma y perdía un paso más.
# Un `case` y no un regex: escapar backslashes dentro de [[ =~ ]] en MSYS es una fuente de bugs
# silenciosos, y acá lo único que se necesita son prefijos.
_es_ruta_absoluta() {
  case "$1" in
    /*|~*|[A-Za-z]:/*|[A-Za-z]:\\*|\\\\*) return 0 ;;
    *) return 1 ;;
  esac
}

# OBSERVACIONES: lo que no entra en el prompt se GUARDA, no se tira (2026-07-27).
#
# Antes esto era `head -c 2000` a secas: si Mentis leía un archivo de 8 KB, veía los primeros
# 2000 caracteres y los otros 6000 DESAPARECÍAN. Si después los necesitaba, tenía que volver a
# leer el archivo -- otra iteración, otra llamada al modelo, y el mismo recorte otra vez.
#
# Medido en esta máquina antes del cambio: el prompt pasaba de 3.780 caracteres en la iteración
# 1 a 10.458 en la 6, sumando ~2.059 por lectura y sin resumirse nunca. Proyectado al presupuesto
# real de 25 iteraciones: ~53.000 caracteres. Casi exactamente el overhead de Hermes (59 KB) que
# se usó para descartarlo como motor: Mentis arranca 20 veces más liviano y termina igual.
#
# La idea es de LangChain Deep Agents: descargar la salida a disco y pasarle al modelo una
# referencia. El archivo se escribe DENTRO de la raíz del agente a propósito -- ahí puede
# abrirlo con 'read', que está enjaulado a esa raíz. Fuera de ella no le serviría de nada.
OBSDIR_REL="${NV_AGENT_OBSDIR:-.mentis-obs}"
OBS_PREVIEW="${NV_AGENT_OBS_PREVIEW:-700}"
_obs_seq=0

_trunc() {
  local tmpf tam archivo_rel
  tmpf="$(mktemp 2>/dev/null || echo "/tmp/obs-$$-$_obs_seq")"
  cat > "$tmpf" 2>/dev/null || true
  tam="$(wc -c < "$tmpf" 2>/dev/null || echo 0)"

  # Lo que entra, entra: mismo comportamiento de siempre, sin archivos de más.
  if [ "$tam" -le "$OBSMAX" ]; then
    cat "$tmpf"; rm -f "$tmpf"; return 0
  fi

  _obs_seq=$((_obs_seq + 1))
  archivo_rel="$OBSDIR_REL/obs-${it:-0}-${_obs_seq}.txt"
  if mkdir -p "$ROOT/$OBSDIR_REL" 2>/dev/null && mv "$tmpf" "$ROOT/$archivo_rel" 2>/dev/null; then
    head -c "$OBS_PREVIEW" "$ROOT/$archivo_rel"
    printf '\n\n[...quedan %s caracteres. La salida COMPLETA está guardada en %s -- para seguir leyendo DESDE DONDE SE CORTÓ: {"tool":"read","path":"%s","value":"%s"}. Ese archivo se entrega por tramos y cada tramo te dice cómo pedir el siguiente. No repitas la acción que generó esta salida.]' \
      "$((tam - OBS_PREVIEW))" "$archivo_rel" "$archivo_rel" "$OBS_PREVIEW"
  else
    # Si no se pudo guardar (disco lleno, permisos), se cae al recorte de siempre: perder cola
    # es malo, pero quedarse sin observación es peor.
    head -c "$OBSMAX" "$tmpf" 2>/dev/null || true
    rm -f "$tmpf"
  fi
}

# El ARTIFACT marker de "gen" lleva una ruta ABSOLUTA (fuera de ROOT, en MENTIS_CREATIONS_DIR).
# nv-agent.sh corre bajo MSYS bash, asi que $GOUT es estilo /c/Users/... -- pero quien lo lee
# despues (main.js/Electron en Windows) necesita C:\Users\... para sus funciones de path.
# Node NO traduce ambos formatos igual (path.resolve('/c/...') NO da 'C:\...').
_win_path() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

# Blindaje contra falsos positivos de 'gen' (bug real 2026-07-18: mentis-doc-gen.sh devolvio
# exito -- sin 'ERROR:' -- pero el.docx nunca aparecio en disco; causa puntual no reproducida,
# pero esta verificacion lo blinda pase lo que pase). Ademas de que el script no haya devuelto
# ERROR, confirma que el archivo realmente haya quedado escrito con contenido (-s: existe y > 0
# bytes).
# ¿Que puede hacer Mentis con esta skill por su cuenta? -> libre | recibo | no
# El registro lo maneja el usuario (skills-autonomas.json). Lo que NO este listado es "no": una skill
# nueva no se vuelve autonoma sola por aparecer en la carpeta.
_skill_permiso() {
  local nombre="$1" reg="$MENTIS_ROOT/skills-autonomas.json"
  [ -f "$reg" ] || { printf 'no'; return 0; }
  SK_NOMBRE="$nombre" python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    v = d.get(os.environ["SK_NOMBRE"], "no")
    print(v if v in ("libre", "recibo") else "no")
except Exception:
    print("no")
' "$(_win_path "$reg")" 2>/dev/null || printf 'no'
}

_gen_verify() { [[ "$1" != ERROR:* ]] && [ -s "$2" ]; }

# Observación de un 'gen' exitoso (bug real 2026-07-30, visto en la app por el usuario: un PDF que salió
# bien costó 4 pasos en vez de 1). mentis-doc-gen.sh imprime la ruta pelada y NADA MÁS, así que la
# observación que le llegaba al modelo era literalmente "C:/Users/.../gen-123.pdf". Sin contexto,
# el modelo hace lo obvio -- intentar leerla -- y quema iteraciones rebotando contra 'read', que
# jamás va a poder abrirla: el archivo vive FUERA de la jaula (MENTIS_CREATIONS_DIR) y encima es
# binario. La ruta sola no era una respuesta, era una invitación. Acá se le dice explícitamente
# que el trabajo terminó y que el usuario ya lo tiene (la app muestra la tarjeta del archivo con el
# marcador ARTIFACT de stderr, que sigue igual: esto NO cambia lo que ve el usuario, sólo lo que
# entiende el modelo).
_gen_ok_obs() { # $1=tipo legible  $2=ruta absoluta (estilo MSYS)
  printf 'LISTO: %s creado en %s\nEl archivo ya está guardado y el usuario lo tiene a la vista. NO hace falta abrirlo ni verificarlo: no está dentro de tu carpeta de trabajo y "read" no puede leerlo. Contale en una frase qué generaste y terminá el turno con "done".' "$1" "$(_win_path "$2")"
}

# === ESCALERA DE VERIFICACION SOBRE ARTEFACTOS REALES ==========================================
# (pedido del usuario, 2026-07-25.) nv-verify.sh tiene construida la escalera
# autor -> tester INDEPENDIENTE -> sandbox real, con dos invariantes fuertes:
#   (a) el que escribe los tests NUNCA es el que escribio el codigo, y
#   (b) la aprobacion es OBJETIVA (exit code de un harness ejecutado), no opinion de un modelo.
# Pero solo se usaba para pulir el TEXTO final del chat (mentis-chat.sh la llama sobre $TASK):
# los archivos que el agente escribe en disco con 'write' NUNCA pasaban por ella. Un archivo
# podia quedar escrito, el agente decir "listo", y nadie haber ejecutado una sola linea.
# Esto aplica la misma escalera sobre el artefacto real, en el momento en que se escribe.
#
# PRESUPUESTO PROPIO (pendiente 2): antes, la unica señal de calidad de codigo era 'exec'
# fallando, que gasta iteraciones del loop principal (MAXIT) -- la exploracion y la
# verificacion competian por el mismo presupuesto. Estas llamadas se gobiernan con su propio
# tope (VERIFY_USED/NV_AGENT_VERIFY_MAX) y no consumen ni una iteracion del agente.
NV_AGENT_VERIFY_MAX="${NV_AGENT_VERIFY_MAX:-3}"     # cuantos artefactos se verifican por turno
# APAGADA POR DEFECTO (2026-07-26), con los numeros que lo justifican. Medido tres veces sobre
# la misma tarea (escribir un validador de CUIT):
#     sin verificacion            25 s   3 iteraciones
#     verificando en cada write  373 s   8 iteraciones   (15x)
#     verificando solo al cierre 500 s  13 iteraciones   (agoto el presupuesto)
# El costo no es solo la llamada al tester: cuando rechaza, el agente vuelve a trabajar. Y el
# rechazo no es confiable -- en la comparativa contra Hermes, un verificador EXTERNO y
# determinista aprobo el mismo codigo que este tester rechazo dos veces. Un tester que produce
# falsos negativos manda a corregir lo que ya funcionaba: cuesta plata y empeora el resultado.
# Se deja disponible (NV_AGENT_VERIFY=1) porque la idea es correcta y el andamiaje quedo hecho;
# lo que falta es que el tester sea confiable, no el mecanismo que lo invoca.
NV_AGENT_VERIFY="${NV_AGENT_VERIFY:-0}"
NV_AGENT_VERIFY_OFF="${NV_AGENT_VERIFY_OFF:-$([ "$NV_AGENT_VERIFY" = "1" ] && echo 0 || echo 1)}"
NV_AGENT_VERIFY_MINBYTES="${NV_AGENT_VERIFY_MINBYTES:-80}"  # archivos triviales no valen una llamada
VERIFY_USED=0
VERIFY_VERDICT="skip"
# El resultado se deja en VERIFY_OBS (global) en vez de imprimirse: capturarlo con $(...)
# meteria la funcion en un subshell y VERIFY_USED/VERIFY_VERDICT se perderian al volver
# (el presupuesto nunca bajaria y el veredicto siempre seria "skip").
VERIFY_OBS=""

# tester != autor (invariante (a) de nv-verify.sh). Primer candidato distinto del rol que
# viene escribiendo el codigo en este turno.
_verify_tester_role() {
  local author="$1" cand
  for cand in general reason deep; do
    [ "$cand" != "$author" ] && { printf '%s' "$cand"; return 0; }
  done
  printf '%s' "general"
}

# Un fallo por dependencias que el sandbox aislado no tiene (imports del propio repo, paquetes
# de terceros) NO es codigo roto -- es codigo que no se puede probar fuera de su contexto.
# Reportarlo como fallo mandaria al agente a "arreglar" algo que no esta mal, que es peor que
# no verificar. Se marca no-verificable y se le dice que lo pruebe con 'exec' en el repo real.
_verify_is_dependency_error() {
  printf '%s' "$1" | grep -qiE "ModuleNotFoundError|ImportError|No module named|Cannot find module|MODULE_NOT_FOUND|command not found|source:.*No such file"
}

# _verify_code_artifact <rel> <abs> <lang> -> imprime el bloque para la observacion del agente.
# Deja el resultado en VERIFY_VERDICT: pass | fail | unverifiable | skip.
_verify_code_artifact() {
  local rel="$1" abs="$2" lang="$3"
  local author tester code testcode combined onlytest out mout rc mrc tprompt THINT
  VERIFY_VERDICT="skip"; VERIFY_OBS=""
  [ "$NV_AGENT_VERIFY_OFF" = "1" ] && return 0
  case "$lang" in python|node|bash) : ;; *) return 0 ;; esac
  [ -s "$abs" ] || return 0
  if [ "$(wc -c < "$abs" 2>/dev/null || echo 0)" -lt "$NV_AGENT_VERIFY_MINBYTES" ]; then return 0; fi
  if [ "$VERIFY_USED" -ge "$NV_AGENT_VERIFY_MAX" ]; then
    VERIFY_OBS="$(printf '\n[verificacion independiente: presupuesto agotado (%s de %s usados en este turno); este archivo NO fue verificado -- probalo vos con "exec" antes de darlo por bueno.]' \
      "$VERIFY_USED" "$NV_AGENT_VERIFY_MAX")"
    return 0
  fi
  VERIFY_USED=$((VERIFY_USED+1))

  author="${ITER_ROLE:-$ROLE}"
  tester="$(_verify_tester_role "$author")"
  code="$(head -c 20000 -- "$abs")"
  case "$lang" in
    python) THINT='Escribi asserts de Python. Una falla debe lanzar AssertionError (corta con exit != 0).' ;;
    node)   THINT='Escribi tests en Node usando require("assert") o process.exit(1) si falla.' ;;
    bash)   THINT='Escribi checks de bash: cada verificacion que falle debe "exit 1".' ;;
  esac
  tprompt="Este es el contenido del archivo '$rel' ($lang) que otro modelo acaba de escribir:
$code

Escribi SOLO un bloque de tests que verifique que ese codigo hace lo que promete. $THINT
Los tests DEBEN invocar las funciones/clases/comandos reales definidos arriba (asumilos YA
definidos en el mismo archivo, NO los repitas) y comparar su salida con lo esperado.
Sin markdown, sin explicaciones, sin redefinir el codigo del autor."
  testcode="$(printf '%s' "$tprompt" | bash "$NVDIR/ask-nvidia.sh" -r "$tester" 2>/dev/null)" || testcode=""
  if [ -z "${testcode// }" ]; then
    VERIFY_VERDICT="unverifiable"
    VERIFY_OBS="$(printf '\n[verificacion independiente: el modelo tester (%s) no respondio; el archivo NO quedo verificado.]' "$tester")"
    return 0
  fi

  combined="$(mktemp)"; { printf '%s\n\n' "$code"; printf '%s\n' "$testcode"; } > "$combined"
  if out="$(nv_sandbox_run "$lang" "$combined" 2>&1)"; then rc=0; else rc=$?; fi
  rm -f "$combined"

  if [ "$rc" = "0" ]; then
    # MUTATION CHECK (heredado de nv-verify.sh): el harness SIN la implementacion tiene que
    # fallar. Si pasa igual, los tests no ejercitan nada y el "VERIFICADO" seria falso.
    onlytest="$(mktemp)"; printf '%s\n' "$testcode" > "$onlytest"
    if mout="$(nv_sandbox_run "$lang" "$onlytest" 2>&1)"; then mrc=0; else mrc=$?; fi
    rm -f "$onlytest"
    if [ "$mrc" = "0" ]; then
      VERIFY_VERDICT="unverifiable"
      nv_log rol="verify-artifact" modelo="$author+$tester" latencia_ms=0 exit=0 fallback=false intentos="$VERIFY_USED" veredicto=fail-mutation
      VERIFY_OBS="$(printf '\n[verificacion independiente (%s escribio los tests): NO CONCLUYENTE -- los tests pasaban tambien sin tu implementacion, asi que no probaron nada. El archivo sigue SIN verificar.]' "$tester")"
      return 0
    fi
    VERIFY_VERDICT="pass"
    nv_record_quality "$author" "$lang" 1
    nv_log rol="verify-artifact" modelo="$author+$tester" latencia_ms=0 exit=0 fallback=false intentos="$VERIFY_USED" veredicto=pass
    VERIFY_OBS="$(printf '\n[VERIFICADO: un modelo independiente (%s) escribio tests contra este archivo y PASARON en sandbox %s.]' "$tester" "$lang")"
    return 0
  fi

  if _verify_is_dependency_error "$out"; then
    VERIFY_VERDICT="unverifiable"
    nv_log rol="verify-artifact" modelo="$author+$tester" latencia_ms=0 exit="$rc" fallback=false intentos="$VERIFY_USED" veredicto=no-verificable
    VERIFY_OBS="$(printf '\n[verificacion independiente: NO CONCLUYENTE -- el archivo depende de modulos/comandos que el sandbox aislado no tiene, asi que no se pudo probar fuera de su repo. Esto NO significa que este mal. Verificalo vos con "exec" corriendo su test real en la raiz de trabajo.]')"
    return 0
  fi

  VERIFY_VERDICT="fail"
  nv_record_quality "$author" "$lang" 0
  nv_log rol="verify-artifact" modelo="$author+$tester" latencia_ms=0 exit="$rc" fallback=false intentos="$VERIFY_USED" veredicto=fail
  VERIFY_OBS="$(printf '\n[FALLO DE VERIFICACION: un modelo independiente (%s) escribio tests contra este archivo y NO pasaron (exit=%s). Salida real:
%s

Corregi el archivo antes de seguir. NO digas que quedo listo hasta que esto pase.]' \
    "$tester" "$rc" "$(printf '%s' "$out" | head -c 1200)")"
}

# --- extractor de acción JSON: stdin = respuesta del modelo -> KEY=val en stdout ---
# Escanea el primer objeto {...} balanceado (respetando strings) que contenga "tool".
_extract_action() {
  # OJO: 'python3 - <<PY' hace que Python lea el PROGRAMA desde stdin (el heredoc);
  # por eso los datos NO pueden ir por stdin (se perderían). La respuesta va por env.
  NVA_RESP="$1" python3 - <<'PY'
import sys, os, json
raw = os.environ.get("NVA_RESP", "")
def objs(s):
    i = 0; n = len(s)
    while i < n:
        if s[i] == '{':
            depth = 0; instr = False; esc = False; start = i
            while i < n:
                c = s[i]
                if instr:
                    if esc: esc = False
                    elif c == '\\': esc = True
                    elif c == '"': instr = False
                else:
                    if c == '"': instr = True
                    elif c == '{': depth += 1
                    elif c == '}':
                        depth -= 1
                        if depth == 0:
                            yield s[start:i+1]; break
                i += 1
        i += 1
for cand in objs(raw):
    try: d = json.loads(cand)
    except Exception: continue
    if isinstance(d, dict) and "tool" in d:
        t = str(d.get("tool", "")).strip()
        print("TOOL=" + t)
        # 'old' y 'new' son de la herramienta 'edit' (2026-08-02). Si un campo nuevo no se agrega
        # ACA, la herramienta lo recibe vacio y falla sin explicacion: es el ERR-028, el protocolo
        # de dos lados desincronizado, que ya paso dos veces en este mismo archivo.
        for k in ("path", "query", "code", "content", "answer", "action", "url", "target", "value", "server", "name", "prompt", "format", "x", "y", "provider", "subject", "description", "status", "id", "old", "new"):
            if k in d and d[k] is not None:
                # emitir por env-safe: base64 para evitar romper el parseo en bash
                import base64
                print(k.upper() + "_B64=" + base64.b64encode(str(d[k]).encode("utf-8")).decode("ascii"))
        if "args" in d and d["args"] is not None:
            import base64, json as _json
            print("ARGS_B64=" + base64.b64encode(_json.dumps(d["args"]).encode("utf-8")).decode("ascii"))
        sys.exit(0)
sys.exit(3)
PY
}

_b64d() { printf '%s' "$1" | python3 -c "import sys,base64;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))"; }

# --- daemon de navegador (browser-server/): puerto dinamico, archivo de estado global ---
# ¿Lo que devolvio la pagina es un desafio anti-bot y no un resultado? Se usa para DOS cosas:
# avisarle al modelo, y decidir si conviene probar con otro buscador (ver la cadena de abajo).
_es_rechazo() {
  printf '%s' "$1" | grep -qiE 'resuelve el desaf|(solve|complete) the (following )?challenge|verify you are human|unusual traffic|automated queries|403 - forbidden|are you a robot|un.ltimo paso|recaptcha|hcaptcha|enable javascript|activa javascript|bots use duckduckgo'
}

# BUSCADORES, EN ORDEN (2026-07-31). Hasta hoy habia UNO solo -- Bing -- y Bing challenguea a
# cualquier navegador automatizado: el usuario lo vio como "Mentis se rindio con entrar a buscar a la
# web". Reproducido: dos iteraciones seguidas con "CAPTCHA detectado" y el presupuesto quemado.
#
# La salida NO es pelearle al CAPTCHA (eso es saltarse una barrera puesta a proposito, y no se
# hace): es usar buscadores que SI permiten un cliente sin JavaScript. DuckDuckGo publica dos
# versiones pensadas justamente para eso, y Wikipedia queda como ultimo recurso para preguntas de
# conocimiento, donde suele ser mejor fuente que un buscador.
#
# Si el primero rechaza, se pasa al siguiente EN LA MISMA ITERACION: antes cada rechazo costaba
# una vuelta entera del agente.
_urls_de_busqueda() {
  local q="$1" enc
  enc="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$q" 2>/dev/null)" || enc="$q"
  # EL ORDEN SALE DE PROBARLOS, no de la fama de cada uno (2026-07-31, desde la red del usuario):
  #   Bing................. CAPTCHA
  #   DuckDuckGo html/lite. CAPTCHA ("elegi los cuadrados con un pato")
  #   Mojeek............... 403 "your network appears to be sending automated queries"
  #   Marginalia........... FUNCIONA (indice independiente, permite clientes automaticos)
  #
  # DOMINIO ACTUALIZADO 2026-08-06: Marginalia se mudo de search.marginalia.nu a
  # marginalia-search.com. El viejo todavia redirige (302), asi que esto no estaba roto -- pero es
  # el PRIMER buscador que se prueba, la redireccion cuesta un viaje de mas, y el dia que dejen de
  # redirigir se cae la busqueda entera sin que nadie entienda por que. Medido: el dominio nuevo
  # contesta 200 directo.
  #   Wikipedia............ FUNCIONA
  # Los dos de DuckDuckGo quedan al final igual: no cuestan nada y pueden andar desde otra red.
  printf 'https://marginalia-search.com/search?query=%s
' "$enc"
  printf 'https://es.wikipedia.org/w/index.php?search=%s
' "$enc"
  printf 'https://html.duckduckgo.com/html/?q=%s
' "$enc"
  printf 'https://lite.duckduckgo.com/lite/?q=%s
' "$enc"
}

_browser_state_file() { printf '%s' "$MENTIS_ROOT/browser-daemon-state.json"; }

_browser_daemon_alive() {
  local statefile port
  statefile="$(_browser_state_file)"
  [ -f "$statefile" ] || return 1
  port="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("port",""), end="")
except Exception:
    print("", end="")
' "$statefile" 2>/dev/null)"
  [ -n "$port" ] || return 1
  if curl -s -m 2 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q '"ok":true'; then
    printf '%s' "$port"; return 0
  fi
  return 1
}

_ensure_browser_daemon() {
  local port statefile serverjs logfile waited win_serverjs win_logfile win_errlog win_cwd
  port="$(_browser_daemon_alive)" && { printf '%s' "$port"; return 0; }
  statefile="$(_browser_state_file)"
  rm -f "$statefile"
  serverjs="$MENTIS_ROOT/browser-server/server.js"
  logfile="$MENTIS_ROOT/browser-server/server.log"
  win_serverjs="$(cygpath -w "$serverjs" 2>/dev/null)" || return 1
  win_logfile="$(cygpath -w "$logfile" 2>/dev/null)" || return 1
  win_errlog="$(cygpath -w "$logfile.err" 2>/dev/null)" || return 1
  win_cwd="$(cygpath -w "$MENTIS_ROOT/browser-server" 2>/dev/null)" || return 1
  powershell.exe -NoProfile -NonInteractive -Command \
    "Start-Process -FilePath node -ArgumentList '$win_serverjs' -WorkingDirectory '$win_cwd' -WindowStyle Hidden -RedirectStandardOutput '$win_logfile' -RedirectStandardError '$win_errlog'" \
    >/dev/null 2>&1
  waited=0
  while [ "$waited" -lt 300 ]; do
    port="$(_browser_daemon_alive)" && { printf '%s' "$port"; return 0; }
    sleep 0.1
    waited=$((waited+1))
  done
  return 1
}

# --- puente MCP (mcp-bridge/): mismo patron que el daemon de navegador ---
_mcp_bridge_state_file() { printf '%s' "$MENTIS_ROOT/mcp-bridge-state.json"; }

# Token de auth del bridge (hardening 2026-07-14, ver server.js) -- vive en el mismo STATE_FILE
# que ya comparte el puerto, se lee por separado porque _mcp_bridge_alive() solo hace falta el
# puerto (para /health, que sigue sin exigir token).
_mcp_bridge_token() {
  local statefile
  statefile="$(_mcp_bridge_state_file)"
  [ -f "$statefile" ] || return 1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("token",""), end="")
except Exception:
    print("", end="")
' "$statefile" 2>/dev/null
}

_mcp_bridge_alive() {
  local statefile port
  statefile="$(_mcp_bridge_state_file)"
  [ -f "$statefile" ] || return 1
  port="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("port",""), end="")
except Exception:
    print("", end="")
' "$statefile" 2>/dev/null)"
  [ -n "$port" ] || return 1
  if curl -s -m 2 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q '"ok":true'; then
    printf '%s' "$port"; return 0
  fi
  return 1
}

_ensure_mcp_bridge() {
  local port statefile serverjs logfile waited win_serverjs win_logfile win_errlog win_cwd
  port="$(_mcp_bridge_alive)" && { printf '%s' "$port"; return 0; }
  statefile="$(_mcp_bridge_state_file)"
  rm -f "$statefile"
  serverjs="$MENTIS_ROOT/mcp-bridge/server.js"
  logfile="$MENTIS_ROOT/mcp-bridge/server.log"
  win_serverjs="$(cygpath -w "$serverjs" 2>/dev/null)" || return 1
  win_logfile="$(cygpath -w "$logfile" 2>/dev/null)" || return 1
  win_errlog="$(cygpath -w "$logfile.err" 2>/dev/null)" || return 1
  win_cwd="$(cygpath -w "$MENTIS_ROOT/mcp-bridge" 2>/dev/null)" || return 1
  powershell.exe -NoProfile -NonInteractive -Command \
    "Start-Process -FilePath node -ArgumentList '$win_serverjs' -WorkingDirectory '$win_cwd' -WindowStyle Hidden -RedirectStandardOutput '$win_logfile' -RedirectStandardError '$win_errlog'" \
    >/dev/null 2>&1
  waited=0
  while [ "$waited" -lt 300 ]; do
    port="$(_mcp_bridge_alive)" && { printf '%s' "$port"; return 0; }
    sleep 0.1
    waited=$((waited+1))
  done
  return 1
}

# === APROBACION POR ACCION (2026-07-28) =====================================================
# Hasta ahora esto era todo-o-nada: o la blocklist rechazaba el comando sin más, o el usuario prendía
# el "modo sin frenos" (-x) y entonces pasaba CUALQUIER cosa, incluida la que él nunca hubiera
# aprobado. Las dos puntas están mal: la primera lo obliga a hacer a mano lo que pidió que se
# hiciera, y la segunda lo deja sin frenos justo cuando más falta hacen.
# Ahora hay un punto medio: se le pregunta por ESE comando concreto, y se espera.
#
# El canal es de archivos a propósito, no un puerto: nv-agent.sh corre como hijo de bash dentro
# de la app, ya escribe su progreso por stderr línea por línea (que la app reenvía a la interfaz),
# y un archivo no necesita que nadie esté escuchando en un socket para funcionar.
#   1. se escribe el pedido en $MENTIS_APROBACION_DIR/<id>.pedido
#   2. se avisa por stderr con una línea marcada, que la app detecta al vuelo
#   3. la app le pregunta al usuario y escribe <id>.respuesta con "si" o "no"
#   4. acá se espera esa respuesta, con tope de tiempo
#
# Si NO hay quien conteste (uso desde consola, o la app cerrada) el pedido vence y se rechaza:
# ante la duda, no ejecutar. Un permiso que se auto-concede por silencio no es un permiso.
NV_APROB_TIMEOUT="${NV_APROB_TIMEOUT:-120}"
_pedir_aprobacion() {
  local accion="$1" detalle="$2" id f_pedido f_resp esperado i resp
  [ -n "${MENTIS_APROBACION_DIR:-}" ] || return 1     # sin canal, no hay a quién preguntar
  mkdir -p "$MENTIS_APROBACION_DIR" 2>/dev/null || return 1
  id="ap-$$-$(date +%s)-$RANDOM"
  f_pedido="$MENTIS_APROBACION_DIR/$id.pedido"
  f_resp="$MENTIS_APROBACION_DIR/$id.respuesta"
  # El detalle va al archivo COMPLETO (un comando puede tener saltos de línea) y a la línea de
  # stderr recortado a una sola línea, porque ese canal es línea por línea.
  { printf 'accion: %s\n' "$accion"; printf '%s\n' "$detalle"; } > "$f_pedido" 2>/dev/null || return 1
  echo "[nv-agent] APROBACION $id :: $accion :: $(printf '%s' "$detalle" | tr '\n' ' ' | cut -c1-300)" >&2
  esperado=$(( NV_APROB_TIMEOUT * 4 ))
  for (( i=0; i<esperado; i++ )); do
    if [ -f "$f_resp" ]; then
      resp="$(tr -d '[:space:]' < "$f_resp" 2>/dev/null)"
      rm -f "$f_pedido" "$f_resp" 2>/dev/null
      [ "$resp" = "si" ] && { echo "[nv-agent] aprobacion $id: el usuario dijo QUE SI" >&2; return 0; }
      echo "[nv-agent] aprobacion $id: el usuario dijo que NO" >&2
      return 1
    fi
    sleep 0.25
  done
  rm -f "$f_pedido" 2>/dev/null
  echo "[nv-agent] aprobacion $id: se vencio el tiempo (${NV_APROB_TIMEOUT}s) sin respuesta -- no se ejecuta" >&2
  return 1
}

_blocked_cmd() {
  local cmd="$1" p
  local pats=(
    'rm[[:space:]]+-[a-zA-Z]*rf' 'rm[[:space:]]+-[a-zA-Z]*fr'
    'git[[:space:]]+push'
    'git[[:space:]]+reset[[:space:]]+--hard'
    'git[[:space:]]+clean[[:space:]]+-f'
    'mkfs'
    'dd[[:space:]]+if='
    '>[[:space:]]*/dev/sd'
    'format[[:space:]]'
    'del[[:space:]]+/s'
    'rmdir[[:space:]]+/s'
  )
  for p in "${pats[@]}"; do
    if printf '%s' "$cmd" | grep -Eqi -- "$p"; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# Asume seteadas por el caller: ROOT, OBSMAX, ALLOW_WRITE, TOOL, PATH_B64, QUERY_B64,
# CODE_B64, CONTENT_B64, ANSWER_B64, OLD_B64, NEW_B64. Bajo `set -u`, sourcear este archivo y llamar
# _dispatch_tool sin setear estas variables falla con un error críptico de variable no ligada.
_dispatch_tool() {
  local it="$1"
  # SEGUNDA CAPA del apagado por modo (-n). La primera es sacar la herramienta del protocolo, que
  # evita el 99% de los casos porque el modelo no sabe que existe. Esta es para el 1%: un modelo
  # que la recuerda de su entrenamiento, o una respuesta copiada de un turno anterior donde si
  # estaba. La leccion de la camara (ERR-133) es exactamente esta: una defensa que vive solo en el
  # texto del prompt es una sugerencia, no una defensa.
  # 'done' nunca se puede apagar: sin ella el turno no tiene forma de terminar.
  # El `:-` no es decorativo: SIN_TOOLS se asigna en el bloque de arranque, que solo corre cuando
  # este archivo se EJECUTA. Otros scripts lo SOURCEAN para reusar sus funciones (ver la guarda
  # BASH_SOURCE mas abajo) y ahi la variable no existe -- con `set -u` eso mata al que sourcea, en
  # una linea que no tiene nada que ver con lo que estaba haciendo.
  _sin="${SIN_TOOLS:-}"
  if [ -n "${_sin// }" ] && [ "$TOOL" != "done" ] && [[ ",${_sin// /}," == *",$TOOL,"* ]]; then
    # CON UN CORPUS ACTIVO (modo Study), 'gen' tiene un reemplazo concreto y hay que nombrarlo.
    # Sin esto el modelo pedia 'gen' tres veces seguidas -- queria armarle las tarjetas al usuario, que
    # es lo correcto -- y el turno moria en el corta-bucles. Negar sin ofrecer la alternativa es lo
    # mismo que ya paso con el corpus (ERR-143): el modelo insiste porque tiene razon en querer.
    if [ "$TOOL" = "gen" ] && [ -n "${MENTIS_CORPUS_DIR:-}" ]; then
      OBS="La herramienta 'gen' esta apagada en este modo, pero lo que queres hacer SI se puede: el material de estudio se convierte a audio, video, presentacion, informe, tabla, mapa mental, tarjetas, cuestionario o infografia con '/material <formato> <tema>'. Eso lo escribe USUARIO, no vos. Terminá ahora con 'done' diciendole que le conviene y pasandole la linea exacta -- por ejemplo '/material tarjetas fotosintesis'."
    else
    OBS="ERROR: la herramienta '$TOOL' no esta disponible en este modo de Mentis. No la vuelvas a pedir. Resolvé con las que tenés, o si de verdad hace falta, terminá con 'done' avisando que esto necesita otro modo."
    fi
    echo "[nv-agent] iter $it: $TOOL RECHAZADO (apagada en este modo)" >&2
    return 0
  fi

  case "$TOOL" in
    done)
      # Bandera en vez de `continue` (2026-07-29): el `continue` que había acá estaba DENTRO de
      # esta función y el loop de iteraciones vive afuera, así que bash lo rechazaba en voz alta
      # ("continue: only meaningful in a for/while/until loop") y seguía de largo. El corte real
      # lo hacía igual el STATUS="budget" de más abajo -- pero el `echo done` posterior se
      # ejecutaba lo mismo, así que el log decía "done" en el mismo turno en que el 'done' había
      # sido RECHAZADO. Un registro que se contradice a sí mismo es peor que no tenerlo.
      local verify_rechazo=0
      FINAL="$(_b64d "$ANSWER_B64")"; STATUS="done"
      # Verificacion independiente del codigo, AL CIERRE (2026-07-26). Antes corria en cada
      # 'write' y eso salio carisimo: medido contra la misma tarea, 373 s con verificacion contra
      # 25 s sin ella -- 15x. No era solo el costo de las llamadas al tester: cada fallo le
      # devolvia "corregi esto" y disparaba mas iteraciones (8 contra 3), y un archivo reescrito
      # cuatro veces se verificaba cuatro veces.
      # Aca se hace UNA sola vez y en el momento que importa: cuando el agente AFIRMA que
      # termino. Si los tests no pasan, se rechaza el 'done' y vuelve a trabajar con el error
      # real en la mano -- mismo patron que la guardia HAD_REAL_ACTION contra las afirmaciones
      # infundadas.
      if [ "${ALLOW_WRITE:-0}" = "1" ] && [ "${NV_AGENT_VERIFY_OFF:-1}" != "1" ] \
         && [ -n "${VERIFY_PENDIENTE_REL:-}" ] && [ "$VERIFY_YA_HECHA" != "1" ]; then
        VERIFY_YA_HECHA=1
        _verify_code_artifact "$VERIFY_PENDIENTE_REL" "$VERIFY_PENDIENTE_ABS" "$VERIFY_PENDIENTE_LANG" || true
        echo "[nv-agent] iter $it: verificacion final de '$VERIFY_PENDIENTE_REL' -> $VERIFY_VERDICT" >&2
        # Una verificacion independiente que PASO es prueba fresca tan buena como un exec: otro
        # modelo escribio tests contra el archivo y corrieron en sandbox. 'fail' y 'unverifiable'
        # no suman -- no verificar no es lo mismo que verificar bien.
        [ "$VERIFY_VERDICT" = "pass" ] && EVIDENCIA_N=$((EVIDENCIA_N+1))
        # El resultado se loguea SIEMPRE, no solo cuando falla: si pasa, o si no fue concluyente,
        # tiene que quedar rastro de que se verifico y con que resultado. Sin esto, un "pass"
        # era indistinguible de no haber verificado nunca.
        [ -n "$VERIFY_OBS" ] && printf '[nv-agent] %s\n' "$(printf '%s' "$VERIFY_OBS" | tr '\n' ' ')" >&2
        if [ "$VERIFY_VERDICT" = "fail" ]; then
          OBS="$VERIFY_OBS"
          FINAL=""; STATUS="budget"
          echo "[nv-agent] iter $it: 'done' RECHAZADO -- el codigo no pasa los tests independientes" >&2
          HIST="$HIST
[iter $it] done (rechazado por la verificacion)
$OBS"
          verify_rechazo=1
        fi
      fi
      [ "$verify_rechazo" = "1" ] || echo "[nv-agent] iter $it: done" >&2 ;;
    drive)
      if [ "${ALLOW_WRITE:-0}" != "1" ]; then
        OBS="No puedo subir a Drive en este turno: subir es una accion de escritura y este turno no las tiene habilitadas (pasa en el modo remoto, desde la pagina del celular). Decile al usuario que lo pida desde la app."
        echo "[nv-agent] iter $it: drive rechazado (sin permiso de escritura)" >&2
      elif [ ! -f "$MENTIS_ROOT/mentis-drive.sh" ]; then
        OBS="ERROR: falta mentis-drive.sh. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
        echo "[nv-agent] iter $it: drive rechazado (falta mentis-drive.sh)" >&2
      else
        DACC="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"; [ -n "$DACC" ] || DACC="estado"
        DPATH="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
        DCUENTA="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        # ARGS_B64 y no ARGS_JSON: el extractor emite el campo 'args' en base64 (ver linea ~417).
        # La primera version de esto leia una variable que no existe -- misma familia de bug que
        # ya rompio dos veces en este archivo, donde el protocolo nombraba un campo que el
        # extractor no producia y la tool fallaba en silencio.
        DCARPETA="$(_b64d "${ARGS_B64:-}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
sys.stdout.write(str((d or {}).get("carpeta") or ""))
' 2>/dev/null || true)"
        case "$DACC" in
          estado|cuentas)
            OBS="$(timeout 90 bash "$MENTIS_ROOT/mentis-drive.sh" "$DACC" 2>&1)" ;;
          subir)
            if [ -z "$DPATH" ]; then
              OBS="Te falto decir QUE archivo subir, en el campo 'path'."
            else
              # La ruta puede venir relativa a la carpeta de trabajo o absoluta (por ejemplo la
              # que devolvio 'gen', que guarda en Documents/Mentis y NO esta bajo la raiz).
              DABS="$DPATH"
              [ -f "$DABS" ] || DABS="$ROOT/$DPATH"
              if [ ! -f "$DABS" ]; then
                OBS="No existe el archivo '$DPATH' (ni relativo a tu carpeta de trabajo ni como ruta absoluta)."
              else
                OBS="$(timeout 300 bash "$MENTIS_ROOT/mentis-drive.sh" subir "$DABS" "$DCUENTA" "$DCARPETA" 2>&1)" || true
                DRC=$?
                # HAD_REAL_ACTION solo si SUBIO de verdad. exit 3 = "hay varias cuentas y nadie
                # dijo cual", que no es un fallo sino una pregunta -- pero tampoco es una subida,
                # y marcarlo como accion real dejaria pasar un "ya lo subi" que seria mentira.
                #
                # `if` Y NO `[ cond ] && accion`: este archivo corre con `set -euo pipefail`, y
                # una lista AND cuya condicion es falsa devuelve 1. Como ultimo comando de la
                # rama, eso ABORTA el script entero sin imprimir nada. Costo un turno que
                # terminaba con la respuesta vacia y sin un solo mensaje de error en el log.
                if [ "$DRC" -eq 0 ]; then
                  HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
                  # Cierre EXPLICITO. Sin esto el modelo subia el archivo y volvia a subirlo: la
                  # observacion decia "Subido a Drive (...)" y el la leia como un dato, no como
                  # un final. Medido en la prueba real: tres llamadas identicas antes del 'done'.
                  # Es el mismo remedio que ya usa 'gen' mas arriba -- decirle que termino y que
                  # no hay nada mas que verificar.
                  OBS="LISTO: $OBS
El archivo YA ESTA en Drive. No vuelvas a llamar a 'drive' para este archivo y no intentes
verificarlo con 'read': la unidad de Drive esta fuera de tu carpeta de trabajo. Contale al usuario en
una frase que quedo subido y en que cuenta, y termina el turno con 'done'."
                fi
              fi
            fi ;;
          *) OBS="No conozco la accion '$DACC' de drive. Son: estado, cuentas, subir." ;;
        esac
        echo "[nv-agent] iter $it: drive $DACC" >&2
      fi ;;
    # 'capacity'/'capability' son alias en ingles. No es cortesia: los modelos escriben en ingles
    # los nombres de herramientas mas seguido de lo que uno espera, y en la primera prueba real
    # se perdieron DOS iteraciones enteras con "tool desconocida: capacity" antes de que acertara.
    # Aceptar el alias cuesta una linea; no aceptarlo cuesta dos llamadas al modelo por turno.
    capacidad|capacity|capability)
      # Entrega la ficha completa de una capacidad que en el protocolo solo aparece como una
      # linea de indice (ver A5, 2026-08-03). Reusa el campo 'action' a proposito: agregar un
      # campo nuevo al protocolo ya rompio dos veces (el extractor no lo reconocia y la tool
      # fallaba en silencio), asi que se usa uno que el extractor ya sabe leer.
      CAPNOM="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
      CAPNOM="$(printf '%s' "$CAPNOM" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')"
      CAPVAR="NVA_FICHA_$(printf '%s' "$CAPNOM" | tr '[:lower:]' '[:upper:]')"
      CAPTXT="${!CAPVAR:-}"
      if [ -n "$CAPNOM" ] && [ -n "$CAPTXT" ]; then
        OBS="Estas son las instrucciones completas de '$CAPNOM'. Ya podes usarla:
$CAPTXT"
        echo "[nv-agent] iter $it: capacidad '$CAPNOM' (ficha entregada)" >&2
      elif [ -n "$CAPNOM" ]; then
        # Que NO quede como "no existe": la capacidad puede estar apagada por una llave del usuario
        # (la camara y el telefono tienen dos), y el modelo tiene que saber la diferencia entre
        # "no lo tengo" y "esta apagado", o va a decirle al usuario que no puede cuando si podria.
        OBS="La capacidad '$CAPNOM' no esta disponible en este turno. Puede ser que no exista con ese nombre o que el usuario la tenga apagada desde los conectores. Capacidades que SI podes pedir ahora:${NVA_INDICE:-  (ninguna)}"
        echo "[nv-agent] iter $it: capacidad '$CAPNOM' NO disponible" >&2
      else
        OBS="Te falto decir cual. Usa {\"tool\":\"capacidad\",\"action\":\"<nombre>\"} con uno de estos:${NVA_INDICE:-  (ninguna)}"
      fi ;;
    read)
      REL="$(_b64d "$PATH_B64")"
      # ¿ESTE MISMO TURNO LO ESCRIBIO Y SIGUE IGUAL? Se resuelve antes de leer, comparando la
      # huella guardada al escribir contra la del archivo tal como esta ahora.
      RELEE_PROPIO=0
      # El guard de "$REL" no vacio va PRIMERO y no es cosmetico: bajo `set -u`, indexar un array
      # asociativo con un subscript vacio aborta el turno entero con "bad array subscript". Paso en
      # vivo el 2026-08-15 -- un 'read' sin path mato la corrida a la mitad y el duelo la anoto
      # como 7/11 en 74 segundos, que parecia "rapido pero peor" cuando en realidad estaba roto.
      if [ -n "${REL:-}" ] && [ -n "${ESCRITO_HUELLA["$REL"]:-}" ]; then
        _RP_ABS="$(_ruta_leible "$REL" 2>/dev/null || true)"
        if [ -n "$_RP_ABS" ] && [ -f "$_RP_ABS" ]; then
          _RP_H="$(cksum < "$_RP_ABS" 2>/dev/null | cut -d' ' -f1)"
          [ -n "${_RP_H:-}" ] && [ "$_RP_H" = "${ESCRITO_HUELLA["$REL"]}" ] && RELEE_PROPIO=1
        fi
      fi
      if ABS="$(_ruta_leible "$REL")" && [ -f "$ABS" ]; then
        # Bug real (2026-07-14): leer un binario (imagen/audio/video/etc) con cat metía sus bytes
        # crudos en la observación, y esa basura rompía el JSON de la respuesta del modelo en el
        # turno siguiente ("el modelo no devolvió JSON válido"). Si ya está adjunto de verdad via
        # -I, el modelo no necesita (ni debe) leerlo como texto -- se corta antes con un error claro.
        # DOCUMENTOS CON IMAGENES ADENTRO (2026-08-03, B1 del plan).
        #
        # Hasta hoy esto se rechazaba: un.docx ES binario, asi que Mentis no podia leer un Word
        # en absoluto -- ni su texto. Y cuando el usuario le pasaba un informe con graficos, las
        # imagenes simplemente no existian para ella: contestaba sobre el texto como si el
        # documento no tuviera nada mas.
        #
        # Ahora se extrae el texto EN ORDEN y, donde habia una imagen, se la describe con el rol
        # multimodal y se deja la descripcion en su lugar. Asi cualquier cerebro "ve" el
        # documento entero, no solo su texto, sin tener que adjuntar binarios.
        case "$(printf '%s' "$REL" | tr '[:upper:]' '[:lower:]')" in
          *.docx|*.pptx|*.xlsx|*.pdf) _ES_DOC=1 ;;
          *) _ES_DOC=0 ;;
        esac
        if [ "$_ES_DOC" = "1" ] && [ -f "$NVDIR/doc_extract.py" ]; then
          _DOCDIR="$ROOT/$OBSDIR_REL/medios"
          mkdir -p "$_DOCDIR" 2>/dev/null || true
          # cygpath para los dos lados: python en esta maquina no abre rutas /c/... (ERR-006).
          _DOCJSON="$(python3 "$NVDIR/doc_extract.py" "$(_win_path "$ABS")" \
                        --imgdir "$(_win_path "$_DOCDIR")" --max-img 4 --json 2>/dev/null || true)"
          if [ -z "$_DOCJSON" ]; then
            OBS="ERROR: no pude leer '$REL' como documento. Puede estar dañado o protegido con contraseña."
            echo "[nv-agent] iter $it: read documento FALLO: $REL" >&2
          else
            _DOCTXT="$(printf '%s' "$_DOCJSON" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("texto",""))' 2>/dev/null)"
            _DOCIMGS="$(printf '%s' "$_DOCJSON" | python3 -c 'import json,sys; sys.stdout.write("\n".join(json.load(sys.stdin).get("imagenes",[])))' 2>/dev/null)"
            _NIMG=0
            if [ -n "$_DOCIMGS" ]; then
              while IFS= read -r _IMG; do
                [ -n "$_IMG" ] || continue
                _NIMG=$((_NIMG+1))
                _IMG_MSYS="$(cygpath -u "$_IMG" 2>/dev/null || printf '%s' "$_IMG")"
                _DESC="$(bash "$NVDIR/ask-nvidia.sh" -r -I "$_IMG_MSYS" multimodal \
                          "Describi en español y en detalle que muestra esta imagen sacada de un documento: si es un grafico deci que datos representa y que valores se leen; si es una foto o un diagrama, que se ve. Se concreto, sin preambulo." 2>/dev/null || true)"
                if [ -n "${_DESC// }" ]; then
                  _DOCTXT="${_DOCTXT//\[\[IMAGEN $_NIMG: $_IMG\]\]/[IMAGEN $_NIMG -- $(printf '%s' "$_DESC" | tr '\n' ' ')]}"
                else
                  # Que quede dicho que HAY una imagen aunque no se haya podido describir: borrar
                  # la marca haria creer que el documento no tenia nada ahi.
                  _DOCTXT="${_DOCTXT//\[\[IMAGEN $_NIMG: $_IMG\]\]/[IMAGEN $_NIMG -- no se pudo describir; el archivo esta en $_IMG_MSYS]}"
                fi
              done <<< "$_DOCIMGS"
            fi
            OBS="$(_trunc <<< "$_DOCTXT")"
            echo "[nv-agent] iter $it: read documento: $REL ($_NIMG imagen(es) descrita(s))" >&2
          fi
        elif [ "$(file --brief --mime-encoding -- "$ABS" 2>/dev/null)" = "binary" ]; then
          OBS="ERROR: '$REL' es un archivo binario (imagen/audio/video/etc), no se puede leer como texto con esta herramienta. Si ya está adjunto como imagen real (rol multimodal), analizalo directamente en vez de leerlo."
          echo "[nv-agent] iter $it: read RECHAZADO (binario): $REL" >&2
        else
          # Un archivo de.mentis-obs NO se vuelve a descargar (bug real 2026-07-27, encontrado
          # probándolo): la salida guardada también supera el tope, así que leerla generaba OTRO
          # archivo de descarga, que al leerse generaba otro más. El agente entraba en un bucle
          # -- obs-1-1 -> obs-2-1 -> obs-3-1 -- y nunca alcanzaba el final del contenido.
          # Acá se entrega por TRAMOS: cada lectura sigue donde terminó la anterior.
          case "$REL" in
            "$OBSDIR_REL"/*)
              R_TOTAL="$(wc -c < "$ABS" 2>/dev/null || echo 0)"
              R_DESDE="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
              case "$R_DESDE" in ''|*[!0-9]*) R_DESDE=0 ;; esac
              OBS="$(tail -c "+$((R_DESDE + 1))" -- "$ABS" 2>/dev/null | head -c "$OBSMAX")"
              R_HASTA=$((R_DESDE + ${#OBS}))
              if [ "$R_HASTA" -lt "$R_TOTAL" ]; then
                OBS="$OBS
[...tramo $R_DESDE-$R_HASTA de $R_TOTAL. Para seguir desde donde quedaste: {\"tool\":\"read\",\"path\":\"$REL\",\"value\":\"$R_HASTA\"}]"
              else
                OBS="$OBS
[fin del archivo: leíste hasta el final de $R_TOTAL caracteres.]"
              fi
              echo "[nv-agent] iter $it: read $REL (tramo desde $R_DESDE)" >&2
              ;;
            *)
              OBS="$(cat -- "$ABS" | _trunc)"
              echo "[nv-agent] iter $it: read $REL" >&2
              ;;
          esac
        fi
      elif [[ "$REL" =~ \.(exe|app|lnk)$ ]]; then
        # Bug real (2026-07-18, verificacion supervisada en vivo): el modelo intento "leer"
        # Calculadora.exe con esta herramienta -- confundio abrir una app con leer un archivo de
        # su carpeta de trabajo. El error generico no lo sacaba del loop; este mensaje apunta
        # directo a la herramienta correcta.
        OBS="ERROR: '$REL' parece el nombre de una aplicación, no un archivo dentro de tu raíz de trabajo -- esta herramienta ('read') NO sirve para abrir programas. Si necesitás abrir una aplicación real en el escritorio, usá {\"tool\":\"control\",\"action\":\"launch\",\"value\":\"$REL\"} (requiere modo de control activo)."
        echo "[nv-agent] iter $it: read RECHAZADO (parece app): $REL" >&2
      elif _es_ruta_absoluta "$REL"; then
        # Un mensaje que no dice POR QUÉ falló no saca al modelo del loop: lo manda a probar la
        # misma ruta escrita distinto. Acá se separan los dos casos reales, y los dos terminan en
        # una instrucción concreta.
        R_LOW="$(printf '%s' "$REL" | tr 'A-Z\\' 'a-z/')"
        if [[ "$R_LOW" == *documents/mentis/* ]]; then
          OBS="ERROR: '$REL' es una creación tuya que YA quedó entregada (documento, imagen, video o modelo 3D). Vive fuera de tu carpeta de trabajo, el usuario ya la tiene a la vista, y 'read' no la puede abrir. No hace falta verificarla: contale en una frase qué generaste y terminá el turno con 'done'."
        else
          OBS="ERROR: '$REL' es una ruta ABSOLUTA. 'read' abre archivos SOLO dentro de tu carpeta de trabajo, y la ruta va relativa a ella (por ejemplo 'notas/pendientes.txt', no 'C:/Users/...' ni '/c/Users/...'). Escribirla de otra forma va a fallar igual. Si no sabés dónde está el archivo, buscalo con {\"tool\":\"search\",\"query\":\"...\"}."
        fi
        echo "[nv-agent] iter $it: read RECHAZADO (ruta absoluta): $REL" >&2
      elif ABS="$(_ruta_leible "$REL")" && [ -d "$ABS" ]; then
        # Existe, está en la jaula, pero es un DIRECTORIO: el `[ -f ]` de arriba lo dejaba pasar al
        # error genérico. Es exactamente lo que pasó con '.mentis-obs' (2026-07-30).
        if [ "${REL%/}" = "$OBSDIR_REL" ]; then
          OBS="ERROR: '$REL' es la CARPETA donde se guardan las observaciones largas, no un archivo. Tenés que leer el archivo puntual que te indiqué (con el formato '$OBSDIR_REL/obs-<iteracion>-<n>.txt'). Los que hay ahora son:
$(ls -1 -- "$ABS" 2>/dev/null | head -10 || true)"
        else
          OBS="ERROR: '$REL' es un directorio, no un archivo. Para saber qué hay adentro usá {\"tool\":\"search\",\"query\":\"...\"}; para leer, nombrá el archivo concreto."
        fi
        echo "[nv-agent] iter $it: read RECHAZADO (es un directorio): $REL" >&2
      else
        # Con un corpus de estudio activo, el archivo pudo no existir en NINGUNO de los dos lados
        # (ver _ruta_leible). Decirle solo "no esta en tu carpeta de trabajo" lo manda a buscarlo
        # ahi para siempre, cuando el material que le interesa esta en el otro patio.
        if [ -n "${MENTIS_CORPUS_DIR:-}" ]; then
          OBS="ERROR: no existe '$REL' ni en tu carpeta de trabajo ni en el material de estudio. Las rutas del material van como te las cita el bloque 'TUS FUENTES DE ESTUDIO' ('materia/archivo.md'), sin la parte del numero de linea. No lo intentes con otra escritura de la misma ruta: si el dato que buscas no aparece en ese bloque, es que no esta en el material -- y eso es lo que hay que responder."
        else
          OBS="ERROR: no existe el archivo '$REL' dentro de tu carpeta de trabajo (las rutas van relativas a ella). No lo intentes con otra escritura de la misma ruta: si no sabés el nombre exacto, buscalo con {\"tool\":\"search\",\"query\":\"...\"}."
        fi
        echo "[nv-agent] iter $it: read RECHAZADO: $REL" >&2
      fi ;;
    recordar)
      # Memoria de lo CONVERSADO (2026-07-27). Distinto de 'search', que mira archivos del
      # directorio de trabajo: esto busca en las charlas anteriores con el usuario, por significado y
      # no por palabra exacta, y devuelve cada pasaje con su fecha.
      RQ="$(_b64d "$QUERY_B64")"
      if [ -z "${RQ// }" ]; then
        OBS="ERROR: 'recordar' necesita una consulta (query) no vacía."
      else
        echo "[nv-agent] iter $it: recordar '$RQ'" >&2
        # Timeout propio: si el indice esta frio la primera busqueda tiene que armarlo, y un
        # turno de conversacion no puede quedarse colgado esperando eso para siempre.
        OBS="$(timeout 120 bash "$MENTIS_ROOT/mentis-recordar.sh" "$RQ" 2>/dev/null | _trunc || true)"
        # `if` y no `[ -z... ] && OBS=...`: este script corre con `set -e`, y esa forma corta
        # devuelve estado 1 cuando la condición es FALSA -- o sea, justo cuando la búsqueda SÍ
        # encontró algo. El agente moría en silencio (exit 1, sin un solo mensaje) exactamente
        # en el caso exitoso. Funciona en otras herramientas sólo porque allá no es la última
        # sentencia del bloque.
        if [ -z "${OBS// }" ]; then
          OBS="(no encontré nada sobre eso en las conversaciones anteriores)"
        fi
      fi
      ;;
    search)
      Q="$(_b64d "$QUERY_B64")"; SREL="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
      SBASE="$ROOT"; [ -n "$SREL" ] && SBASE="$(_ruta_leible "$SREL" || echo "")"
      if [ -n "$SBASE" ] && [ -e "$SBASE" ]; then
        if command -v rg >/dev/null 2>&1; then
          OBS="$(rg -n --no-heading -m 20 -- "$Q" "$SBASE" 2>/dev/null | _trunc || true)"
        else
          OBS="$(grep -rn -m 20 -- "$Q" "$SBASE" 2>/dev/null | _trunc || true)"
        fi
        # CON UN CORPUS ACTIVO, 'search' TAMBIEN LO MIRA (2026-08-12). Buscar en el material es
        # exactamente lo que el modo Study existe para hacer: dejarlo afuera obligaba al modelo a
        # pelear contra la herramienta hasta quemar el turno, que es el mismo error que ya se
        # cometio con 'read' (ERR-143). El corpus se agrega como SEGUNDA carpeta, sin reemplazar
        # la de trabajo: un archivo que el usuario dejo en el turno sigue apareciendo primero.
        if [ -n "${MENTIS_CORPUS_DIR:-}" ] && [ -d "$MENTIS_CORPUS_DIR" ] && [ -z "$SREL" ]; then
          if command -v rg >/dev/null 2>&1; then
            OBS_C="$(rg -n --no-heading -m 20 -- "$Q" "$MENTIS_CORPUS_DIR" 2>/dev/null | _trunc || true)"
          else
            OBS_C="$(grep -rn -m 20 -- "$Q" "$MENTIS_CORPUS_DIR" 2>/dev/null | _trunc || true)"
          fi
          if [ -n "${OBS_C// }" ]; then
            OBS="${OBS:+$OBS
}--- en tu material de estudio ---
$OBS_C"
          fi
        fi
        [ -z "$OBS" ] && OBS="(sin coincidencias para: $Q)"
        echo "[nv-agent] iter $it: search '$Q'" >&2
      else
        OBS="ERROR: ruta de búsqueda inválida o fuera de la raíz."
        echo "[nv-agent] iter $it: search RECHAZADO" >&2
      fi ;;
    run)
      CODE="$(_b64d "$CODE_B64")"; NVA_TMP="$(mktemp)"; printf '%s' "$CODE" > "$NVA_TMP"
      if OUT="$(nv_sandbox_run bash "$NVA_TMP" 2>&1)"; then RC=0; else RC=$?; fi
      rm -f "$NVA_TMP"
      OBS="$(printf 'exit=%s\n%s' "$RC" "$OUT" | _trunc)"
      echo "[nv-agent] iter $it: run (exit $RC)" >&2 ;;
    write)
      WRITE_CNT="${WRITE_CNT:-0}"
      WRITE_CNT=$((WRITE_CNT+1))
      REL="$(_b64d "$PATH_B64")"
      if [ "${ALLOW_WRITE:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -w para habilitar escritura/ejecución)."
        echo "[nv-agent] iter $it: write RECHAZADO (sin -w): $REL" >&2
      elif ABS="$(_caged "$REL")"; then
        # Foto ANTES de escribir: si esto pisa algo que importaba, se puede volver.
        _foto_antes_de_tocar
        mkdir -p -- "$(dirname "$ABS")"
        CONTENT="$(_b64d "$CONTENT_B64")"
        printf '%s' "$CONTENT" > "$ABS"
        OBS="OK: archivo escrito ($(printf '%s' "$CONTENT" | wc -c) bytes): $REL"
        # Huella del contenido recien escrito (cksum: un proceso corto y sin dependencias).
        ESCRITO_HUELLA["$REL"]="$(printf '%s' "$CONTENT" | cksum | cut -d' ' -f1)"
        echo "[nv-agent] iter $it: write $REL" >&2
        WLANG=""
        case "$REL" in
          *.py) CODE_LANG_GUESS="python"; WLANG="python" ;;
          *.js|*.mjs|*.cjs) CODE_LANG_GUESS="node"; WLANG="node" ;;
          *.sh|*.bash) CODE_LANG_GUESS="bash"; WLANG="bash" ;;
        esac
        HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
        echo "[nv-agent] ARTIFACT: $REL" >&2
        # Escalera de verificacion sobre el artefacto real (ver _verify_code_artifact): un
        # modelo INDEPENDIENTE escribe tests contra este archivo y se ejecutan de verdad.
        # Corre con presupuesto propio: no gasta iteraciones del loop.
        # El archivo se ANOTA para verificarlo al cierre, no se verifica ahora. Verificar en
        # cada write costaba una llamada al modelo por escritura (y el agente reescribe el mismo
        # archivo varias veces): medido, 373 s contra 25 s en la misma tarea. Se guarda el ULTIMO
        # artefacto de codigo escrito, que es el que representa el trabajo terminado.
        if [ -n "$WLANG" ]; then
          VERIFY_PENDIENTE_REL="$REL"
          VERIFY_PENDIENTE_ABS="$ABS"
          VERIFY_PENDIENTE_LANG="$WLANG"
          VERIFY_YA_HECHA=0
        fi
      else
        OBS="ERROR: ruta inválida o fuera de la raíz: $REL"
        echo "[nv-agent] iter $it: write RECHAZADO (fuera de jaula): $REL" >&2
      fi ;;
    # 'edit' (2026-08-02, revision total): cambiar UN pedazo sin reescribir el archivo entero.
    #
    # POR QUE HACIA FALTA: hasta hoy la unica forma de tocar un archivo era 'write', que lo
    # reemplaza completo. Para cambiar una linea de un archivo de 2000, el modelo tenia que
    # reemitir las 2000. El problema no es el costo: es que si se queda sin max_tokens a mitad,
    # el archivo queda TRUNCADO. O sea que el modo de falla no era "no hizo el cambio", era
    # "rompio el archivo". Con 'edit' un cambio chico cuesta lo que mide el cambio.
    #
    # POR QUE 'old' TIENE QUE SER UNICO: si aparece dos veces, cual de las dos queria cambiar?
    # Adivinar es peor que fallar. Se le devuelve cuantas veces aparecio y se le pide que agregue
    # contexto alrededor -- que es lo que un editor humano hace naturalmente.
    edit)
      WRITE_CNT="${WRITE_CNT:-0}"
      WRITE_CNT=$((WRITE_CNT+1))
      REL="$(_b64d "${PATH_B64:-}")"
      if [ "${ALLOW_WRITE:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -w para habilitar escritura/ejecución)."
        echo "[nv-agent] iter $it: edit RECHAZADO (sin -w): $REL" >&2
      elif [ -z "${OLD_B64:-}" ]; then
        OBS="ERROR: 'edit' necesita el campo old con el texto EXACTO a reemplazar. Si querés crear el archivo o reescribirlo entero, usá write."
        echo "[nv-agent] iter $it: edit RECHAZADO (sin old): $REL" >&2
      elif ABS="$(_caged "$REL")"; then
        if [ ! -f "$ABS" ]; then
          OBS="ERROR: no existe el archivo: $REL. Para crearlo, usá write."
          echo "[nv-agent] iter $it: edit RECHAZADO (no existe): $REL" >&2
        else
          _foto_antes_de_tocar
          # El reemplazo va en python y es LITERAL (str.replace), no una expresion regular: el
          # texto viene de un modelo y puede traer parentesis, puntos, barras y llaves. Con sed
          # cualquiera de esos cambiaria el significado del patron en silencio.
          # OJO: EDIT_TMP se crea ANTES de la cadena de asignaciones de entorno. Si se cuela en el
          # medio de las continuaciones con "\", bash deja de leerlas como prefijo de entorno de
          # python y las trata como una asignación suelta: python arranca SIN las variables y
          # muere con KeyError. Pasó al escribir esto y el síntoma era mudo (2>/dev/null se
          # comía el error y set -e cortaba el turno sin decir por qué).
          EDIT_TMP="$(mktemp)"
          NVA_ABS="$(nv_winpath "$ABS" 2>/dev/null || printf '%s' "$ABS")" \
          NVA_OLD="$(_b64d "$OLD_B64")" NVA_NEW="$(_b64d "${NEW_B64:-}")" \
          python3 - <<'PY' > "$EDIT_TMP" 2>/dev/null
import os, sys
ruta = os.environ["NVA_ABS"]
viejo = os.environ["NVA_OLD"]
nuevo = os.environ["NVA_NEW"]
with open(ruta, encoding="utf-8", errors="replace") as f:
    t = f.read()
n = t.count(viejo)
if n == 0:
    print("NOENCONTRADO")
elif n > 1:
    print("AMBIGUO %d" % n)
else:
    with open(ruta, "w", encoding="utf-8", newline="") as f:
        f.write(t.replace(viejo, nuevo, 1))
    print("OK %d %d" % (len(viejo), len(nuevo)))
PY
          EDIT_R="$(tr -d '\r' < "$EDIT_TMP" 2>/dev/null | head -1)"
          rm -f "$EDIT_TMP" 2>/dev/null || true
          case "$EDIT_R" in
            OK\ *)
              OBS="OK: editado $REL (se reemplazaron ${EDIT_R#OK } bytes: viejo nuevo)"
              echo "[nv-agent] iter $it: edit $REL" >&2
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
              echo "[nv-agent] ARTIFACT: $REL" >&2
              case "$REL" in
                *.py) CODE_LANG_GUESS="python"; VERIFY_PENDIENTE_LANG="python" ;;
                *.js|*.mjs|*.cjs) CODE_LANG_GUESS="node"; VERIFY_PENDIENTE_LANG="node" ;;
                *.sh|*.bash) CODE_LANG_GUESS="bash"; VERIFY_PENDIENTE_LANG="bash" ;;
                *) VERIFY_PENDIENTE_LANG="" ;;
              esac
              if [ -n "${VERIFY_PENDIENTE_LANG:-}" ]; then
                VERIFY_PENDIENTE_REL="$REL"; VERIFY_PENDIENTE_ABS="$ABS"; VERIFY_YA_HECHA=0
              fi ;;
            AMBIGUO\ *)
              OBS="ERROR: el texto de 'old' aparece ${EDIT_R#AMBIGUO } veces en $REL. Agregá líneas de contexto alrededor para que sea único, o usá write si querés reemplazar todo."
              echo "[nv-agent] iter $it: edit RECHAZADO (ambiguo): $REL" >&2 ;;
            NOENCONTRADO)
              OBS="ERROR: el texto de 'old' no aparece en $REL. Leé el archivo primero y copiá el fragmento tal cual, con su indentación."
              echo "[nv-agent] iter $it: edit RECHAZADO (no encontrado): $REL" >&2 ;;
            *)
              OBS="ERROR: no se pudo editar $REL."
              echo "[nv-agent] iter $it: edit FALLO: $REL" >&2 ;;
          esac
        fi
      else
        OBS="ERROR: ruta inválida o fuera de la raíz: $REL"
        echo "[nv-agent] iter $it: edit RECHAZADO (fuera de jaula): $REL" >&2
      fi ;;
    # 'lsp' (2026-08-02, revision total): preguntas sobre el CODIGO, no sobre el texto.
    #
    # POR QUE EXISTE: 'search' es texto plano. Buscar "def procesar" encuentra la definicion y
    # tambien cada comentario que menciona la palabra, y no encuentra nada si la funcion se llama
    # distinto de como el modelo supuso. Con esto se puede preguntar donde se DEFINE un simbolo y
    # QUIEN lo usa -- que es lo que uno quiere saber antes de cambiar algo.
    #
    # NO NECESITA -w: no modifica nada, solo pregunta. Igual que 'git'.
    #
    # DEGRADA A PROPOSITO: si no hay servidor de lenguaje instalado para ese archivo, devuelve el
    # comando exacto para instalarlo en vez de un error. Hoy en esta maquina no hay ninguno, asi
    # que ese es el camino que se va a recorrer siempre hasta que el usuario instale uno -- por eso el
    # mensaje importa tanto como la funcionalidad.
    lsp)
      LSP_ACC="$(_b64d "${ACTION_B64:-}")"
      LSP_REL="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
      LSP_LIN="$(_b64d "${X_B64:-}" 2>/dev/null || true)"
      LSP_COL="$(_b64d "${Y_B64:-}" 2>/dev/null || true)"
      case "$LSP_ACC" in
        definicion|referencias|simbolos|diagnosticos|servidores) : ;;
        "") OBS="ERROR: 'lsp' necesita el campo action: definicion, referencias, simbolos, diagnosticos o servidores."
            echo "[nv-agent] iter $it: lsp RECHAZADO (sin action)" >&2; LSP_ACC="" ;;
        *)  OBS="ERROR: 'lsp $LSP_ACC' no existe. Disponibles: definicion, referencias, simbolos, diagnosticos, servidores."
            echo "[nv-agent] iter $it: lsp RECHAZADO (accion desconocida: $LSP_ACC)" >&2; LSP_ACC="" ;;
      esac
      if [ "$LSP_ACC" = "servidores" ]; then
        # El "|| true" NO es opcional (ERR-009): lsp_client.py sale 3 o 4 cuando falta un servidor,
        # y eso es una observacion util, no un error del turno. Bajo `set -e`, una asignacion desde
        # un comando que sale distinto de cero ABORTA la conversacion entera. Encontrado probando:
        # pedir 'lsp definicion' sin servidor instalado mataba el turno con exit 4.
        OBS="$(python3 "$NVDIR/lsp_client.py" servidores 2>&1 | tr -d '\r' | _trunc || true)"
        echo "[nv-agent] iter $it: lsp servidores" >&2
      elif [ -n "$LSP_ACC" ]; then
        if [ -z "$LSP_REL" ]; then
          OBS="ERROR: 'lsp $LSP_ACC' necesita el campo path con el archivo."
          echo "[nv-agent] iter $it: lsp RECHAZADO (sin path)" >&2
        elif LSP_ABS="$(_caged "$LSP_REL")"; then
          LSP_OUT="$(python3 "$NVDIR/lsp_client.py" "$LSP_ACC" \
                       --archivo "$(nv_winpath "$LSP_ABS" 2>/dev/null || printf '%s' "$LSP_ABS")" \
                       --raiz "$(nv_winpath "$ROOT" 2>/dev/null || printf '%s' "$ROOT")" \
                       --linea "${LSP_LIN:-1}" --columna "${LSP_COL:-1}" 2>&1 || true)"
          OBS="$(printf '%s' "$LSP_OUT" | tr -d '\r' | _trunc)"
          [ -n "${OBS// }" ] || OBS="OK: 'lsp $LSP_ACC' no devolvio resultados para $LSP_REL."
          echo "[nv-agent] iter $it: lsp $LSP_ACC $LSP_REL" >&2
        else
          OBS="ERROR: ruta invalida o fuera de la raiz: $LSP_REL"
          echo "[nv-agent] iter $it: lsp RECHAZADO (fuera de jaula): $LSP_REL" >&2
        fi
      fi ;;
    # 'git' (2026-08-02, revision total): ver el estado de un repo, SOLO LECTURA.
    #
    # POR QUE EXISTE: era uno de los huecos del inventario. Sin esto, cuando el usuario pregunta "¿que
    # cambiaste?" o "¿que quedo sin commitear?", Mentis no tenia forma de saberlo salvo pidiendole
    # a 'exec' que corriera git a mano -- que funciona, pero exige -w (permiso de ESCRIBIR y
    # EJECUTAR) para una pregunta que no modifica nada. Con esta tool, mirar un repo no cuesta
    # darle permiso de escritura.
    #
    # POR QUE NO ESCRIBE, Y NO ES PEREZA:
    #   - 'commit', 'checkout', 'reset', 'push' y compania cambian el historial del usuario, y el
    #     historial es justo lo que la gente usa para recuperarse de un error. Una herramienta que
    #     puede romper el mecanismo de recuperacion no puede ser la primera que se agrega.
    #   - Mentis YA tiene deshacer propio (mentis-deshacer.sh) con un repo SOMBRA, hecho asi a
    #     proposito porque el 2026-07-26 se creo un repo que el usuario no habia pedido. Meterle ahora
    #     escritura sobre el git REAL va en contra de esa decision, que fue suya.
    #   - Si algun dia hace falta commitear, que sea un pedido explícito del usuario y una pasada
    #     aparte, con su propia bandera y su propia confirmacion. No de arrastre.
    # Los verbos que escriben se rechazan con un mensaje que dice como hacerlo a mano.
    git)
      GIT_ACC="$(_b64d "${ACTION_B64:-}")"
      GIT_REL="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
      case "$GIT_ACC" in
        status|diff|log|show|branch|remote|blame) : ;;
        "")
          OBS="ERROR: 'git' necesita el campo action. Disponibles (solo lectura): status, diff, log, show, branch, remote, blame."
          echo "[nv-agent] iter $it: git RECHAZADO (sin action)" >&2; GIT_ACC="" ;;
        *)
          OBS="ERROR: 'git $GIT_ACC' no esta disponible: esta herramienta es de SOLO LECTURA y no toca el historial del usuario. Disponibles: status, diff, log, show, branch, remote, blame. Si de verdad hace falta escribir en el repo, pediselo al usuario y que lo haga el."
          echo "[nv-agent] iter $it: git RECHAZADO (verbo de escritura: $GIT_ACC)" >&2; GIT_ACC="" ;;
      esac
      if [ -n "$GIT_ACC" ]; then
        if GIT_ABS="$(_caged "${GIT_REL:-.}")"; then
          if [ ! -d "$GIT_ABS" ]; then
            OBS="ERROR: no es un directorio: ${GIT_REL:-.}"
          elif ! git -C "$GIT_ABS" rev-parse --git-dir >/dev/null 2>&1; then
            OBS="ERROR: ${GIT_REL:-.} no esta dentro de un repositorio git."
            echo "[nv-agent] iter $it: git: no hay repo en ${GIT_REL:-.}" >&2
          else
            # --no-pager es obligatorio: sin el, git abre 'less' y el proceso queda esperando una
            # tecla que nunca llega. Los limites (-20, --stat) evitan volcar un diff de 5000 lineas
            # que se coma la observacion entera; si el modelo necesita mas, pide un path concreto.
            case "$GIT_ACC" in
              status) GIT_OUT="$(git -C "$GIT_ABS" --no-pager status --short --branch 2>&1 || true)" ;;
              diff)   GIT_OUT="$( { git -C "$GIT_ABS" --no-pager diff --stat 2>&1; echo '--- detalle ---'; git -C "$GIT_ABS" --no-pager diff 2>&1; } || true)" ;;
              log)    GIT_OUT="$(git -C "$GIT_ABS" --no-pager log --oneline -20 2>&1 || true)" ;;
              show)   GIT_OUT="$(git -C "$GIT_ABS" --no-pager show --stat HEAD 2>&1 || true)" ;;
              branch) GIT_OUT="$(git -C "$GIT_ABS" --no-pager branch -a 2>&1 || true)" ;;
              remote) GIT_OUT="$(git -C "$GIT_ABS" --no-pager remote -v 2>&1 || true)" ;;
              blame)  GIT_OUT="$(git -C "$GIT_ABS" --no-pager blame -L 1,40 -- "${GIT_REL:-.}" 2>&1 || true)" ;;
            esac
            # _trunc lee de STDIN, no de un argumento -- pasarselo como parametro devuelve vacio
            # y la observacion se pierde entera, en silencio. Costo tres casos del test.
            OBS="$(printf '%s' "$GIT_OUT" | _trunc)"
            [ -n "${OBS// }" ] || OBS="OK: 'git $GIT_ACC' no devolvio nada (por ejemplo: sin cambios sin commitear)."
            echo "[nv-agent] iter $it: git $GIT_ACC ${GIT_REL:-.}" >&2
          fi
        else
          OBS="ERROR: ruta invalida o fuera de la raiz: $GIT_REL"
          echo "[nv-agent] iter $it: git RECHAZADO (fuera de jaula): $GIT_REL" >&2
        fi
      fi ;;
    exec)
      EXEC_CNT="${EXEC_CNT:-0}"
      EXEC_CNT=$((EXEC_CNT+1))
      CODE="$(_b64d "$CODE_B64")"
      # Un comando real puede tocar cualquier cosa de la carpeta, así que también merece su foto.
      [ "${ALLOW_WRITE:-0}" = "1" ] && _foto_antes_de_tocar
      if [ "${ALLOW_WRITE:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -w para habilitar escritura/ejecución)."
        echo "[nv-agent] iter $it: exec RECHAZADO (sin -w)" >&2
      elif [ "$(_connector_enabled 'local:terminal')" != "1" ]; then
        OBS="ERROR: conector Terminal desactivado (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: exec RECHAZADO (conector desactivado)" >&2
      elif [ "${ALLOW_DANGEROUS:-0}" != "1" ] && MATCH="$(_blocked_cmd "$CODE")" && \
           ! _pedir_aprobacion "ejecutar un comando que la blocklist marca como peligroso ($MATCH)" "$CODE"; then
        # Se rechaza sólo si el usuario dijo que no, o si no había forma de preguntarle. Antes se
        # rechazaba siempre, y la única alternativa era prenderle el modo sin frenos a TODO.
        OBS="ERROR: comando rechazado (el usuario no lo aprobó): $MATCH"
        echo "[nv-agent] iter $it: exec BLOQUEADO: $MATCH" >&2
      elif [ -z "${CODE//[[:space:]]/}" ]; then
        # 'exec' sin nada que ejecutar. Antes esto corria `bash -c ""`, que devuelve exit 0 sin
        # salida: un EXITO FALSO, el peor resultado posible. El modelo lo leia como "corri el
        # comando y no imprimio nada", volvia a intentar igual, y la traza mostraba doce
        # 'exec (exit 0)' sin una sola linea de salida (2026-08-12). Pasa cuando erra el nombre
        # del campo -- 'command' en vez de 'code' -- asi que el mensaje tiene que decir cual es.
        OBS="ERROR: llamaste a 'exec' sin codigo. El campo se llama 'code': {\"tool\":\"exec\",\"code\":\"python3 -c 'print(2+2)'\"}. Si usaste otro nombre ('command', 'cmd', 'script'), el comando llego vacio y no se ejecuto nada -- no es que el comando no haya impreso."
        echo "[nv-agent] iter $it: exec RECHAZADO (sin codigo: reviso que el campo se llame 'code')" >&2
      else
        if OUT="$(cd "$ROOT" && timeout "${NV_AGENT_EXEC_TIMEOUT:-120}" bash -c "$CODE" 2>&1)"; then RC=0; else RC=$?; fi
        OBS="$(printf 'exit=%s\n%s' "$RC" "$OUT" | _trunc)"
        # QUE se ejecuto, no solo como salio (2026-08-12). Con solo el exit, una tanda de doce
        # 'exec (exit 0)' que no imprimian nada era indiagnosticable desde la traza: no habia
        # forma de saber si el comando estaba mal armado o si de verdad no tenia salida. La
        # traza es la fuente de verdad de este motor -- si no dice que corrio, no alcanza.
        _EXEC_LOG="$(printf '%s' "$CODE" | tr '\n' ' ' | cut -c1-120)"
        echo "[nv-agent] iter $it: exec (exit $RC, ${#OUT} bytes) :: $_EXEC_LOG" >&2
        # Escalera de verificacion (pedido del usuario, 2026-07-18: cerrar la brecha de calidad de
        # codigo -- ver nv-verify.sh, que YA escala autor cuando el sandbox rechaza el intento).
        # 'exec' es como Mentis verifica que un fix de codigo realmente funciona (correr el
        # test real) -- si falla 2 veces seguidas con el rol base, subimos el CEREBRO (no solo
        # reintentamos con el mismo) para las proximas iteraciones, igual que la escalera
        # autor->tester->sandbox de nv-verify.sh pero sobre el repo real (no un snippet aislado).
        # PRUEBA FRESCA para el gate de completitud: un comando que corrio de verdad y salio bien.
        # Un exec que FALLA no cuenta como evidencia a proposito -- si el comando fallo y el turno
        # igual afirma que funciona, es justo el caso que el gate tiene que agarrar.
        [ "$RC" = "0" ] && EVIDENCIA_N=$((EVIDENCIA_N+1))
        if [ "${ALLOW_WRITE:-0}" = "1" ]; then
          nv_record_quality "$ITER_ROLE" "$CODE_LANG_GUESS" "$([ "$RC" = "0" ] && echo 1 || echo 0)"
          if [ "$RC" = "0" ]; then
            EXEC_FAIL_STREAK=0
          else
            EXEC_FAIL_STREAK=$((EXEC_FAIL_STREAK+1))
            if [ "$EXEC_FAIL_STREAK" -ge 2 ] && [ "$CODE_ESCALA_IDX" -lt "${#CODE_ESCALA_ARR[@]}" ]; then
              CODE_ESCALA_IDX=$((CODE_ESCALA_IDX+1))
              EXEC_FAIL_STREAK=0
              echo "[nv-agent] iter $it: verificacion de codigo fallo 2 veces seguidas -> escalo cerebro a '${CODE_ESCALA_ARR[$((CODE_ESCALA_IDX-1))]}'" >&2
            fi
          fi
        fi
      fi ;;
    browse)
      if [ "${ALLOW_BROWSE:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -b para habilitar navegacion web)."
        echo "[nv-agent] iter $it: browse RECHAZADO (sin -b)" >&2
      else
        BACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        BURL="$(_b64d "${URL_B64:-}" 2>/dev/null || true)"
        BTARGET="$(_b64d "${TARGET_B64:-}" 2>/dev/null || true)"
        BVALUE="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        BQUERY="$(_b64d "${QUERY_B64:-}" 2>/dev/null || true)"
        if BPORT="$(_ensure_browser_daemon)"; then
          case "$BACTION" in
            open)   BJSON="$(python3 -c 'import json,sys;print(json.dumps({"url":sys.argv[1]}))' "$BURL")"; BENDPOINT="open" ;;
            search) BJSON=""; BENDPOINT="buscar-en-cadena" ;;
            click)  BJSON="$(python3 -c 'import json,sys;print(json.dumps({"target":sys.argv[1]}))' "$BTARGET")"; BENDPOINT="click" ;;
            fill)   BJSON="$(python3 -c 'import json,sys;print(json.dumps({"target":sys.argv[1],"value":sys.argv[2]}))' "$BTARGET" "$BVALUE")"; BENDPOINT="fill" ;;
            scroll) BJSON="$(python3 -c 'import json,sys;print(json.dumps({"direction":sys.argv[1]}))' "$BVALUE")"; BENDPOINT="scroll" ;;
            read)   BJSON="{}"; BENDPOINT="read" ;;
            *)      BJSON="{}"; BENDPOINT="" ;;
          esac
          if [ "$BENDPOINT" = "buscar-en-cadena" ]; then
            # Se prueba buscador por buscador hasta que uno conteste algo que no sea un desafio.
            BRESP=""; BUSADO=""
            # TAVILY PRIMERO, SI HAY CLAVE (2026-08-15). Desde esta red, Bing, DuckDuckGo y
            # Mojeek devuelven CAPTCHA (medido, ver _urls_de_busqueda), asi que la busqueda queda
            # reducida a Marginalia -- indice independiente y chico -- y Wikipedia. Eso, y no el
            # modelo, es por que las busquedas salen flojas.
            #
            # Tavily es una API pensada para agentes: uno se identifica con una clave en vez de
            # disimular. Va PRIMERO y la escalera de siempre queda de respaldo. Sin clave no cambia
            # nada: el script devuelve vacio y sigue todo como hasta hoy.
            _TAVILY_KEY="$(grep '^TAVILY_API_KEY=' "$MENTIS_ROOT/.custom-models-secrets.env" 2>/dev/null | cut -d= -f2- | tr -d '
')"
            if [ -n "${_TAVILY_KEY// }" ]; then
              _TV="$(TAVILY_API_KEY="$_TAVILY_KEY" timeout 40 python3 "$(_win_path "$NVDIR/tavily_buscar.py")" "$BQUERY" 2>/dev/null | tr -d '
')"
              if [ -n "${_TV// }" ]; then
                BRESP="$(BT="$_TV" python3 -c 'import json,os;print(json.dumps({"ok":True,"texto":os.environ["BT"]}))' | tr -d '
')"
                echo "[nv-agent] iter $it: browse search (tavily)" >&2
              fi
            fi

            # La escalera de buscadores queda de RESPALDO: si Tavily ya trajo resultados, no se
            # gastan cuatro viajes mas para tirarlos. Sin clave de Tavily, esto corre como siempre.
            if [ -z "${BRESP// }" ]; then
            while IFS= read -r BSURL; do
              [ -n "$BSURL" ] || continue
              BJSON="$(python3 -c 'import json,sys;print(json.dumps({"url":sys.argv[1]}))' "$BSURL")"
              BRESP_TRY="$(curl -s -m 30 -X POST "http://127.0.0.1:$BPORT/open" -H 'Content-Type: application/json' -d "$BJSON" 2>/dev/null)"
              # Con expansion de parametros y NO con sed: la referencia de grupo se rompe al pasar
              # por generadores de codigo (termino como un caracter de control) y el nombre del
              # buscador salia vacio en el log. Esto no tiene escapes que se puedan perder.
              BUSADO="${BSURL#*://}"; BUSADO="${BUSADO%%/*}"
              if [ -n "$BRESP_TRY" ] && ! _es_rechazo "$BRESP_TRY"; then
                BRESP="$BRESP_TRY"
                echo "[nv-agent] iter $it: browse search ($BUSADO)" >&2
                break
              fi
              echo "[nv-agent] iter $it: browse search ($BUSADO rechazo, pruebo el siguiente)" >&2
              BRESP="$BRESP_TRY"
            done <<< "$(_urls_de_busqueda "$BQUERY")"
            fi
            BENDPOINT="open"; BYA_LOGUEADO=1
          elif [ -n "$BENDPOINT" ]; then
            BRESP="$(curl -s -m 30 -X POST "http://127.0.0.1:$BPORT/$BENDPOINT" -H 'Content-Type: application/json' -d "$BJSON" 2>/dev/null)"
          fi
          if [ -n "$BENDPOINT" ]; then
            OBS="$(BFABLE_RESP="$BRESP" python3 -c '
import json, os
raw = os.environ.get("BFABLE_RESP", "")
try:
    d = json.loads(raw)
except Exception:
    print("ERROR: respuesta invalida del servidor de navegador")
    raise SystemExit(0)
if "error" in d:
    print("ERROR: " + str(d["error"]))
else:
    lines = [d.get("text", ""), "", "ELEMENTOS INTERACTIVOS:"]
    for el in d.get("elements", []):
        tsuffix = " (" + el["type"] + ")" if el.get("type") else ""
        lines.append("[" + str(el["n"]) + "] " + el["kind"] + ": \"" + el["label"] + "\"" + tsuffix)
    print("\n".join(lines))
' 2>/dev/null)"
            # Deteccion de CAPTCHA/pagina de verificacion anti-bot (bug real 2026-07-12,
            # protocolo de error pedido por el usuario): sin esto el modelo no distingue una pagina
            # de desafio de un resultado real, y reintenta la MISMA busqueda varias veces sin
            # avanzar. Heuristica sobre frases tipicas de estas paginas (Bing/Google en
            # es/en) -- no es perfecta, pero cubre el caso real observado.
            # Un solo detector para todo (_es_rechazo). Antes esta linea tenia su propia copia del
            # patron, mas vieja: no reconocia el desafio de DuckDuckGo ni el 403 de Mojeek, asi que
            # avisaba de un CAPTCHA en unos casos y en otros no. Dos copias de una regla es una
            # regla que se va a desincronizar.
            if _es_rechazo "$OBS"; then
              OBS="$OBS

[AVISO: esta pagina parece ser un CAPTCHA o verificacion anti-bot, NO un resultado real. No tiene sentido repetir la misma busqueda esperando un resultado distinto. Segui con otra estrategia (una consulta MUY distinta, como MUCHO una vez mas) o andá directo a 'done' con lo que ya sabes, siendo honesto sobre que no pudiste confirmar con una busqueda en vivo.]"
              echo "[nv-agent] iter $it: browse $BACTION (CAPTCHA detectado)" >&2
            elif [ "${BYA_LOGUEADO:-0}" != "1" ]; then
              echo "[nv-agent] iter $it: browse $BACTION" >&2
            fi
            BYA_LOGUEADO=0
          else
            OBS="ERROR: accion de browse desconocida: '$BACTION'. Usá search|open|click|fill|scroll|read."
            echo "[nv-agent] iter $it: browse RECHAZADO (accion desconocida: $BACTION)" >&2
          fi
        else
          OBS="ERROR: no se pudo iniciar/conectar al servidor de navegador (revisar $MENTIS_ROOT/browser-server/server.log)."
          echo "[nv-agent] iter $it: browse FALLO (daemon no disponible)" >&2
        fi
      fi ;;
    mcp)
      if [ "${ALLOW_MCP:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -t para habilitar MCP)."
        echo "[nv-agent] iter $it: mcp RECHAZADO (sin -t)" >&2
      else
        MACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        MSERVER="$(_b64d "${SERVER_B64:-}" 2>/dev/null || true)"
        MNAME="$(_b64d "${NAME_B64:-}" 2>/dev/null || true)"
        MARGS="$(_b64d "${ARGS_B64:-}" 2>/dev/null || echo '{}')"
        [ -z "$MARGS" ] && MARGS='{}'
        if MPORT="$(_ensure_mcp_bridge)"; then
          MTOKEN="$(_mcp_bridge_token)"
          if [ "$MACTION" = "list" ]; then
            MRESP="$(curl -s -m 15 "http://127.0.0.1:$MPORT/tools" -H "X-Mentis-Token: $MTOKEN" 2>/dev/null)"
            OBS="$(MFABLE_RESP="$MRESP" python3 -c '
import json, os
raw = os.environ.get("MFABLE_RESP", "")
try:
    d = json.loads(raw)
except Exception:
    print("ERROR: respuesta invalida del bridge MCP")
    raise SystemExit(0)
lines = ["TOOLS MCP DISPONIBLES:"]
for t in d.get("tools", []):
    schema = t.get("inputSchema", {}) or {}
    props = schema.get("properties", {}) or {}
    required = set(schema.get("required", []) or [])
    if props:
        params = ", ".join((k + "*" if k in required else k) for k in props.keys())
    else:
        params = "(sin parametros)"
    lines.append("- " + t.get("server","") + "." + t.get("name","") + ": " + t.get("description","") + " | params (* = requerido): " + params)
print("\n".join(lines))
' 2>/dev/null | head -c "${NV_AGENT_MCP_LIST_OBSMAX:-16000}")"
            # OJO (bug real encontrado 2026-07-12): "mcp list" usaba el mismo OBSMAX=2000 que
            # read/search (pensado para snippets de archivo), pero el listado de tools de un
            # solo server (google-workspace) ya son ~13000 caracteres con sus 88 tools -- el
            # modelo nunca llegaba a VER "create_google_doc" (cae recien en el caracter 4117),
            # asi que adivinaba "create_text_file" y fallaba por el nombre sin extension.txt/.md.
            # "mcp list" es una lista acotada y de alto valor (no contenido arbitrario de
            # usuario), por eso tiene su propio limite, mucho mas generoso que _trunc/OBSMAX.
            echo "[nv-agent] iter $it: mcp list" >&2
          elif [ "$MACTION" = "call" ]; then
            # $MARGS viaja por stdin, no como argumento de linea de comandos -- bug real
            # encontrado en auditoria 2026-07-14: con args de ~35KB+ (ej. el cuerpo de un mail o
            # documento real via MCP), pasarlo como argv reventaba el limite de CreateProcess de
            # Windows ("Argument list too long"), MJSON quedaba vacio, y el codigo de abajo
            # reportaba el mensaje ENGAÑOSO "args de mcp call no son JSON valido" cuando el JSON
            # en realidad era valido -- el problema era tamaño de argv, no el contenido.
            MJSON="$(MSERVER_ENV="$MSERVER" MNAME_ENV="$MNAME" python3 -c '
import json, os, sys
args_raw = sys.stdin.read()
try:
    args = json.loads(args_raw)
except Exception:
    print("")
    raise SystemExit(0)
print(json.dumps({"server": os.environ["MSERVER_ENV"], "name": os.environ["MNAME_ENV"], "args": args}))
' <<< "$MARGS" 2>/dev/null)"
            if [ -z "$MJSON" ]; then
              OBS="ERROR: args de mcp call no son JSON valido."
              echo "[nv-agent] iter $it: mcp RECHAZADO (args invalidos)" >&2
            else
              MRESP="$(curl -s -m 30 -X POST "http://127.0.0.1:$MPORT/call" -H 'Content-Type: application/json' -H "X-Mentis-Token: $MTOKEN" -d "$MJSON" 2>/dev/null)"
              MRAW="$(MFABLE_RESP="$MRESP" python3 -c '
import json, os
raw = os.environ.get("MFABLE_RESP", "")
try:
    d = json.loads(raw)
except Exception:
    print("ERROR: respuesta invalida del bridge MCP")
    raise SystemExit(0)
if "error" in d:
    print("ERROR: " + str(d["error"]))
else:
    result = d.get("result", {})
    print(json.dumps(result, ensure_ascii=False))
    # heuristica: los resultados de google-workspace-mcp traen el link real del archivo
    # creado/editado bajo alguna de estas claves -- lo marcamos como artefacto abrible.
    def find_link(obj):
        if isinstance(obj, dict):
            for k in ("webViewLink", "htmlLink", "alternateLink", "spreadsheetUrl", "webContentLink"):
                v = obj.get(k)
                if isinstance(v, str) and v.startswith("http"):
                    return v
            for v in obj.values():
                r = find_link(v)
                if r:
                    return r
        elif isinstance(obj, list):
            for v in obj:
                r = find_link(v)
                if r:
                    return r
        return None
    link = find_link(result)
    if link:
        print("__MENTIS_ARTIFACT_URL__:" + link)
' 2>/dev/null)"
              MLINK="$(printf '%s\n' "$MRAW" | grep '^__MENTIS_ARTIFACT_URL__:' | sed 's/^__MENTIS_ARTIFACT_URL__://')"
              OBS="$(printf '%s\n' "$MRAW" | grep -v '^__MENTIS_ARTIFACT_URL__:' | _trunc)"
              # cualquier "mcp call" exitoso cuenta como accion real (no solo cuando devuelve
              # link) -- send_email/create_event tambien son acciones reales, aunque no
              # produzcan un artefacto abrible.
              [[ "$MRAW" != ERROR:* ]] && HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
              [ -n "$MLINK" ] && echo "[nv-agent] ARTIFACT: $MLINK" >&2
              echo "[nv-agent] iter $it: mcp call $MSERVER.$MNAME" >&2
            fi
          else
            OBS="ERROR: accion de mcp desconocida: '$MACTION'. Usá list|call."
            echo "[nv-agent] iter $it: mcp RECHAZADO (accion desconocida: $MACTION)" >&2
          fi
        else
          OBS="ERROR: no se pudo iniciar/conectar al puente MCP (revisar $MENTIS_ROOT/mcp-bridge/server.log)."
          echo "[nv-agent] iter $it: mcp FALLO (bridge no disponible)" >&2
        fi
      fi ;;
    gen)
      if [ "${ALLOW_GEN:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -g para habilitar gen)."
        echo "[nv-agent] iter $it: gen RECHAZADO (sin -g)" >&2
      else
        GKIND="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        GPROMPT="$(_b64d "${PROMPT_B64:-}" 2>/dev/null || true)"
        GPATH_REL="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
        GCONTENT="$(_b64d "${CONTENT_B64:-}" 2>/dev/null || true)"
        GFORMAT="$(_b64d "${FORMAT_B64:-}" 2>/dev/null || true)"
        GOUTNAME="gen-$(date +%s)-$$"
        if [ "$GKIND" = "doc" ]; then
          if [ -z "$GCONTENT" ]; then
            OBS="ERROR: falta 'content' para gen kind=doc. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
          elif [[ ! "$GFORMAT" =~ ^(docx|pdf|pptx|xlsx)$ ]]; then
            OBS="ERROR: 'format' invalido o faltante para gen kind=doc. Usa docx|pdf|pptx|xlsx."
          elif printf '%s' "$GCONTENT" | grep -qiE '^\s*\[ *(imagen|image|foto|grafico|gráfico) *:'; then
            # GUARDA CONTRA EL CARTEL DE IMAGEN (2026-08-03). Bug real y repetido: Mentis generaba
            # una imagen y despues escribia en el documento un renglon '[IMAGEN: archivo.jpg]'.
            # Eso no inserta nada -- es un cartel que le avisa al usuario que el documento le quedo
            # sin la imagen -- y encima el turno terminaba diciendo "la foto va integrada en el
            # medio del texto", que era falso.
            #
            # Se rechaza con codigo y no con una instruccion mas en el prompt: ya se le explico
            # dos veces en la ficha y siguio haciendolo. Un rechazo con la correccion en la mano
            # es el mismo patron que la guarda HAD_REAL_ACTION contra las afirmaciones infundadas.
            OBS="RECHAZADO: el 'content' tiene un renglon tipo '[IMAGEN:...]'. Eso NO inserta ninguna imagen: queda como texto y el documento sale sin la foto. Para insertar de verdad, reemplaza ese renglon por UNO de estos dos y volve a llamar a gen:
  !img <que buscar>                       -> baja una foto real y libre de Wikimedia Commons.
  !imgfile <ruta absoluta>|<epigrafe>      -> inserta una imagen que ya tenes en el disco."
            echo "[nv-agent] iter $it: gen doc RECHAZADO (cartel de imagen en vez de !img/!imgfile)" >&2
          else
            mkdir -p "$MENTIS_CREATIONS_DIR/Documentos"
            GOUT="$MENTIS_CREATIONS_DIR/Documentos/$GOUTNAME.$GFORMAT"
            GRESULT="$(bash "$MENTIS_ROOT/mentis-doc-gen.sh" -o "$GOUT" -k "$GFORMAT" "$GCONTENT" 2>&1 | _trunc || true)"
            OBS="$GRESULT"
            echo "[nv-agent] iter $it: gen doc ($GFORMAT)" >&2
            if _gen_verify "$GRESULT" "$GOUT"; then
              OBS="$(_gen_ok_obs "el documento ($GFORMAT)" "$GOUT")"
              # HAD_DOC ademas de HAD_REAL_ACTION: la guarda del final del loop necesita saber que
              # se genero un DOCUMENTO, no una accion real cualquiera. Sin esta distincion,
              # "te hice el informe" pasaba como cierto con solo haber generado una imagen.
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)); HAD_DOC=1; echo "[nv-agent] ARTIFACT: $(_win_path "$GOUT")" >&2
            elif [[ "$GRESULT" != ERROR:* ]]; then
              OBS="ERROR: el generador no devolvio error pero el archivo no quedo escrito en $(_win_path "$GOUT")."
              echo "[nv-agent] iter $it: gen doc FALLO (archivo ausente pese a exito reportado)" >&2
            fi
          fi
        elif [ "$GKIND" = "image" ]; then
          if [ -z "$GPROMPT" ]; then
            OBS="ERROR: falta 'prompt' para gen kind=image. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
          else
            GPROVIDER="$(_b64d "${PROVIDER_B64:-}" 2>/dev/null || true)"
            mkdir -p "$MENTIS_CREATIONS_DIR/Imagenes"
            GOUT="$MENTIS_CREATIONS_DIR/Imagenes/$GOUTNAME.jpg"
            if [ "$GPROVIDER" = "ideogram" ] && [ "$(_connector_enabled 'api:ideogram')" != "1" ]; then
              GRESULT="ERROR: conector Ideogram desactivado (Directorio -> Conectores en la app de Mentis)."
              echo "[nv-agent] iter $it: gen image RECHAZADO (ideogram desactivado)" >&2
            elif [ "$GPROVIDER" = "ideogram" ]; then
              GRESULT="$(bash "$MENTIS_ROOT/mentis-image-gen-ideogram.sh" -o "$GOUT" "$GPROMPT" 2>&1 | _trunc || true)"
              echo "[nv-agent] iter $it: gen image (ideogram)" >&2
            else
              GRESULT="$(bash "$MENTIS_ROOT/mentis-image-gen.sh" -o "$GOUT" "$GPROMPT" 2>&1 | _trunc || true)"
              echo "[nv-agent] iter $it: gen image" >&2
            fi
            OBS="$GRESULT"
            if _gen_verify "$GRESULT" "$GOUT"; then
              OBS="$(_gen_ok_obs "la imagen" "$GOUT")"
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)); echo "[nv-agent] ARTIFACT: $(_win_path "$GOUT")" >&2
            elif [[ "$GRESULT" != ERROR:* ]]; then
              OBS="ERROR: el generador no devolvio error pero el archivo no quedo escrito en $(_win_path "$GOUT")."
              echo "[nv-agent] iter $it: gen image FALLO (archivo ausente pese a exito reportado)" >&2
            fi
          fi
        elif [ "$GKIND" = "video" ]; then
          if [ -z "$GPROMPT" ]; then
            OBS="ERROR: falta 'prompt' para gen kind=video. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
          elif [ "$(_connector_enabled 'api:runway')" != "1" ]; then
            OBS="ERROR: conector Runway desactivado (Directorio -> Conectores en la app de Mentis)."
            echo "[nv-agent] iter $it: gen video RECHAZADO (runway desactivado)" >&2
          else
            mkdir -p "$MENTIS_CREATIONS_DIR/Videos"
            GOUT="$MENTIS_CREATIONS_DIR/Videos/$GOUTNAME.mp4"
            GRESULT="$(bash "$MENTIS_ROOT/mentis-video-gen-runway.sh" -o "$GOUT" --prompt "$GPROMPT" 2>&1 | _trunc || true)"
            OBS="$GRESULT"
            echo "[nv-agent] iter $it: gen video (runway)" >&2
            if _gen_verify "$GRESULT" "$GOUT"; then
              OBS="$(_gen_ok_obs "el video" "$GOUT")"
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)); echo "[nv-agent] ARTIFACT: $(_win_path "$GOUT")" >&2
            elif [[ "$GRESULT" != ERROR:* ]]; then
              OBS="ERROR: el generador no devolvio error pero el archivo no quedo escrito en $(_win_path "$GOUT")."
              echo "[nv-agent] iter $it: gen video FALLO (archivo ausente pese a exito reportado)" >&2
            fi
          fi
        elif [ "$GKIND" = "3d" ]; then
          mkdir -p "$MENTIS_CREATIONS_DIR/Modelos-3D"
          if [ -n "$GPATH_REL" ]; then
            if GABS="$(_caged "$GPATH_REL")" && [ -f "$GABS" ]; then
              GOUT="$MENTIS_CREATIONS_DIR/Modelos-3D/$GOUTNAME.glb"
              GRESULT="$(bash "$MENTIS_ROOT/mentis-3d-gen.sh" -o "$GOUT" --image "$GABS" 2>&1 | _trunc || true)"
              OBS="$GRESULT"
              echo "[nv-agent] iter $it: gen 3d (desde imagen existente)" >&2
              if _gen_verify "$GRESULT" "$GOUT"; then
                OBS="$(_gen_ok_obs "el modelo 3D" "$GOUT")"
                HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)); echo "[nv-agent] ARTIFACT: $(_win_path "$GOUT")" >&2
              elif [[ "$GRESULT" != ERROR:* ]]; then
                OBS="ERROR: el generador no devolvio error pero el archivo no quedo escrito en $(_win_path "$GOUT")."
                echo "[nv-agent] iter $it: gen 3d FALLO (archivo ausente pese a exito reportado)" >&2
              fi
            else
              OBS="ERROR: ruta de imagen invalida o fuera de la raiz: $GPATH_REL"
              echo "[nv-agent] iter $it: gen RECHAZADO (ruta invalida)" >&2
            fi
          elif [ -n "$GPROMPT" ]; then
            GOUT="$MENTIS_CREATIONS_DIR/Modelos-3D/$GOUTNAME.glb"
            GRESULT="$(bash "$MENTIS_ROOT/mentis-3d-gen.sh" -o "$GOUT" --prompt "$GPROMPT" 2>&1 | _trunc || true)"
            OBS="$GRESULT"
            echo "[nv-agent] iter $it: gen 3d (desde prompt)" >&2
            if _gen_verify "$GRESULT" "$GOUT"; then
              OBS="$(_gen_ok_obs "el modelo 3D" "$GOUT")"
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)); echo "[nv-agent] ARTIFACT: $(_win_path "$GOUT")" >&2
            elif [[ "$GRESULT" != ERROR:* ]]; then
              OBS="ERROR: el generador no devolvio error pero el archivo no quedo escrito en $(_win_path "$GOUT")."
              echo "[nv-agent] iter $it: gen 3d FALLO (archivo ausente pese a exito reportado)" >&2
            fi
          else
            OBS="ERROR: gen kind=3d necesita 'prompt' o 'path'."
          fi
        else
          OBS="ERROR: kind de gen desconocido: '$GKIND'. Usa image|3d|video|doc."
          echo "[nv-agent] iter $it: gen RECHAZADO (kind desconocido: $GKIND)" >&2
        fi
      fi ;;
    skill)
      # SKILLS AUTONOMAS (pedido del usuario, 2026-07-30). Hasta hoy el prompt le decia "vos NO podes
      # ejecutarlas, sugeriselas": eran 14 herramientas que Mentis podia recomendar y no usar.
      # Ahora puede, con el alcance que el usuario eligio en skills-autonomas.json.
      if [ "${ALLOW_SKILLS:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -K para habilitar skills)."
        echo "[nv-agent] iter $it: skill RECHAZADO (sin -K)" >&2
      else
        SKN="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        SKARG="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        SKFILE="$MENTIS_ROOT/capabilities/$SKN.sh"
        # El nombre se valida contra un patron cerrado ANTES de tocar el disco: sin esto,
        # "../mentis-backup" seria una ruta valida y la lista de permisos no serviria de nada.
        if [[ ! "$SKN" =~ ^[a-z0-9-]+$ ]] || [ ! -f "$SKFILE" ]; then
          OBS="ERROR: no existe la skill '$SKN'. Las que hay: $(ls "$MENTIS_ROOT/capabilities" 2>/dev/null | sed 's/\.sh$//' | tr '
' ' ')"
          echo "[nv-agent] iter $it: skill RECHAZADO (no existe: $SKN)" >&2
        else
          SKPERM="$(_skill_permiso "$SKN")"
          case "$SKPERM" in
            no)
              OBS="ERROR: la skill '$SKN' NO esta habilitada para que la uses sola. el usuario la puede correr el mismo escribiendo /$SKN, y podes sugerirsela -- pero no la ejecutes."
              echo "[nv-agent] iter $it: skill RECHAZADO (no autorizada: $SKN)" >&2 ;;
            libre|recibo)
              SKFOTO=""
              if [ "$SKPERM" = "recibo" ]; then
                # Punto de retorno ANTES de tocar nada. Es lo que convierte "autonomia" en
                # "autonomia reversible": el usuario no frena para dar permiso, pero puede volver atras.
                SKFOTO="$(timeout 30 bash "$MENTIS_ROOT/mentis-deshacer.sh" foto "skill $SKN" 2>/dev/null | tail -1)" || SKFOTO=""
              fi
              echo "[nv-agent] iter $it: skill $SKN" >&2
              OBS="$(timeout 600 bash "$SKFILE" "$SKARG" 2>&1 | _trunc || true)"
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
              if [ "$SKPERM" = "recibo" ]; then
                OBS="$OBS

[RECIBO -- esto es de las que dejan algo hecho despues del turno. DECISELO A USUARIO en tu respuesta, en una linea: que corriste /$SKN, que hizo, y como se deshace.${SKFOTO:+ Punto de retorno: mentis-deshacer.sh volver $SKFOTO}]"
                echo "[nv-agent] SKILL-RECIBO $SKN :: ${SKFOTO:-sin-foto}" >&2
              fi ;;
          esac
        fi
      fi ;;
    telefono)
      # EL TELEFONO (pedido del usuario, 2026-07-30: "que aparezca como un boton mas, parecido al de
      # computer-use"). Dos llaves, igual que la camara: la bandera -P y el conector
      # 'local:telefono', que arranca APAGADO. Va por KDE Connect (ver mentis-telefono.sh).
      # Lo que NO hace, y no es olvido: no manda SMS ni mensajes en nombre del usuario. Escribirle a
      # alguien por el no se deshace.
      if [ "${ALLOW_TELEFONO:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -P para habilitar telefono)."
        echo "[nv-agent] iter $it: telefono RECHAZADO (sin -P)" >&2
      elif [ "$(_connector_enabled 'local:telefono')" != "1" ]; then
        OBS="ERROR: el conector del telefono esta apagado (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: telefono RECHAZADO (conector desactivado)" >&2
      elif _tope_alcanzado telefono; then
        OBS="$(_tope_mensaje telefono)"
        echo "[nv-agent] iter $it: telefono RECHAZADO (tope de ${TOPE_MAX[telefono]} por turno alcanzado)" >&2
      else
        _tope_sumar telefono
        TACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"; [ -n "$TACTION" ] || TACTION="estado"
        TVALOR="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        case "$TACTION" in
          estado|notificaciones|sonar)
            echo "[nv-agent] iter $it: telefono $TACTION" >&2
            OBS="$(timeout 90 bash "$MENTIS_ROOT/mentis-telefono.sh" "$TACTION" 2>&1 | _trunc || true)" ;;
          avisar|texto|enviar)
            if [ -z "${TVALOR// }" ]; then
              OBS="ERROR: 'telefono $TACTION' necesita un 'value' (el texto o el archivo)."
            else
              echo "[nv-agent] iter $it: telefono $TACTION" >&2
              OBS="$(timeout 90 bash "$MENTIS_ROOT/mentis-telefono.sh" "$TACTION" "$TVALOR" 2>&1 | _trunc || true)"
              HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1))
            fi ;;
          *)
            OBS="ERROR: accion de telefono desconocida: '$TACTION'. Usa estado|notificaciones|sonar|avisar|texto|enviar."
            echo "[nv-agent] iter $it: telefono RECHAZADO (accion invalida)" >&2 ;;
        esac
      fi ;;
    webcam)
      # La cámara es la herramienta más invasiva que tiene Mentis, así que tiene DOS llaves: el
      # permiso del proceso (-V) y el conector que el usuario prende y apaga desde la app. Cualquiera
      # de las dos apagada y esto no corre.
      if [ "${ALLOW_WEBCAM:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -V para habilitar la camara)."
        echo "[nv-agent] iter $it: webcam RECHAZADO (sin -V)" >&2
      elif [ "$(_connector_enabled 'local:webcam')" != "1" ]; then
        OBS="ERROR: la camara esta desactivada (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: webcam RECHAZADO (conector desactivado)" >&2
      elif _tope_alcanzado webcam; then
        # La TERCERA llave, y la unica que no depende de que alguien reaccione a tiempo.
        # El mensaje le dice al modelo que no insista y que cierre con lo que tenga: sin esta
        # ultima parte, un modelo obstinado gasta el resto del presupuesto reintentando.
        OBS="$(_tope_mensaje webcam)"
        echo "[nv-agent] iter $it: webcam RECHAZADO (tope de $WEBCAM_MAX por turno alcanzado)" >&2
      else
        WACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        [ -n "$WACTION" ] || WACTION="mirar"
        case "$WACTION" in
          mirar|leer|presencia)
            # Se cuenta ANTES de sacar la foto, no despues: si se contara despues, un fallo a
            # mitad de camino dejaria el contador sin incrementar y el bucle podria seguir
            # eternamente a base de intentos fallidos.
            _tope_sumar webcam
            # La marca con "-> ruta" es la que la app y la pagina del celular usan para mostrar el
            # recuadro con lo que la camara vio. Mismo formato que 'screen ver ->...'.
            # OJO: el formato de ESTA linea es un contrato con LIVE_PREVIEW_MARKER en app/main.js,
            # que espera exactamente "webcam <accion> -> <ruta>". El contador va en la linea de
            # abajo justamente para no romperlo: metido acá adentro, la app dejaba de mostrar la
            # foto en silencio (probado al escribirlo).
            echo "[nv-agent] iter $it: webcam $WACTION -> $(_win_path "$WEBCAM_PREVIEW")" >&2
            echo "[nv-agent] (una foto, la camara se apaga al terminar -- uso ${TOPE_USOS[webcam]} de $WEBCAM_MAX en este turno)" >&2
            if WOUT="$(_webcam_mirar "$WACTION")"; then
              OBS="$(printf 'la camara vio (%s):\n%s' "$WACTION" "$WOUT" | _trunc)"
            else
              OBS="$WOUT"
            fi ;;
          *)
            OBS="ERROR: accion de webcam desconocida: '$WACTION'. Usa mirar|leer|presencia."
            echo "[nv-agent] iter $it: webcam RECHAZADO (accion invalida)" >&2 ;;
        esac
      fi ;;
    screen)
      if [ "${ALLOW_SCREEN:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -s para habilitar computer-use)."
        echo "[nv-agent] iter $it: screen RECHAZADO (sin -s)" >&2
      elif _tope_alcanzado screen; then
        OBS="$(_tope_mensaje screen)"
        echo "[nv-agent] iter $it: screen RECHAZADO (tope de ${TOPE_MAX[screen]} por turno alcanzado)" >&2
      else
        _tope_sumar screen
        if SDESC="$(_computer_use_snapshot)"; then
          OBS="$(_trunc <<< "$SDESC")"
          echo "[nv-agent] iter $it: screen ver -> $LIVE_PREVIEW" >&2
        else
          OBS="ERROR: no se pudo capturar la pantalla."
          echo "[nv-agent] iter $it: screen FALLO" >&2
        fi
      fi ;;
    control)
      if [ "${ALLOW_CONTROL:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -c para habilitar computer-use)."
        echo "[nv-agent] iter $it: control RECHAZADO (sin -c)" >&2
      elif _tope_alcanzado control; then
        OBS="$(_tope_mensaje control)"
        echo "[nv-agent] iter $it: control RECHAZADO (tope de ${TOPE_MAX[control]} por turno alcanzado)" >&2
      else
        _tope_sumar control
        CACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        CVALUE="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        CX="$(_b64d "${X_B64:-}" 2>/dev/null || true)"; [[ "$CX" =~ ^-?[0-9]+$ ]] || CX=0
        CY="$(_b64d "${Y_B64:-}" 2>/dev/null || true)"; [[ "$CY" =~ ^-?[0-9]+$ ]] || CY=0
        CTMP_OUT="$(mktemp)"
        case "$CACTION" in
          launch) bash "$MENTIS_ROOT/mentis-computer-control.sh" launch "$CVALUE" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          move)   bash "$MENTIS_ROOT/mentis-computer-control.sh" move "$CX" "$CY" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          click)  bash "$MENTIS_ROOT/mentis-computer-control.sh" click "$CX" "$CY" "${CVALUE:-left}" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          type)   bash "$MENTIS_ROOT/mentis-computer-control.sh" type "$CVALUE" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          key)    bash "$MENTIS_ROOT/mentis-computer-control.sh" key "$CVALUE" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          scroll) bash "$MENTIS_ROOT/mentis-computer-control.sh" scroll "${CVALUE:-down}" >"$CTMP_OUT" 2>&1; CRC=$? ;;
          *)      printf 'accion desconocida: %s' "$CACTION" > "$CTMP_OUT"; CRC=1 ;;
        esac
        COUT="$(cat "$CTMP_OUT")"; rm -f "$CTMP_OUT"
        if [ "$CRC" = "0" ]; then
          # Computer-use en vivo (pedido del usuario, 2026-07-16): auto-captura SOLO despues de
          # 'click' -- es donde mas importa confirmar visualmente (coordenadas, puede fallar el
          # target). Hallazgo real (2026-07-17, verificacion supervisada en vivo): auto-capturar
          # despues de CADA accion (incluido cada 'key'/'type' individual) hacia que una tarea
          # de varios pasos tardara 10+ minutos, porque la descripcion multimodal es lenta por
          # diseno (~30-45s cada vez) -- para 'move'/'type'/'key'/'scroll' el modelo puede seguir
          # sin la confirmacion visual inmediata, y sigue pudiendo pedir 'screen' el mismo a mano
          # si de verdad la necesita.
          if { [ "$CACTION" = "click" ] || [ "$CACTION" = "launch" ]; } && SDESC="$(_computer_use_snapshot)"; then
            OBS="OK: control $CACTION ejecutado. Resultado visible ahora: $(_trunc <<< "$SDESC")"
            echo "[nv-agent] iter $it: control $CACTION -> $LIVE_PREVIEW" >&2
          else
            OBS="OK: control $CACTION ejecutado."
            echo "[nv-agent] iter $it: control $CACTION" >&2
          fi
        else
          OBS="ERROR: fallo control $CACTION: $COUT"
          echo "[nv-agent] iter $it: control FALLO ($CACTION)" >&2
        fi
      fi ;;
    vscode)
      if [ "${ALLOW_EDITOR:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -e para habilitar VS Code)."
        echo "[nv-agent] iter $it: vscode RECHAZADO (sin -e)" >&2
      elif [ "$(_connector_enabled 'local:vscode')" != "1" ]; then
        OBS="ERROR: conector VS Code desactivado (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: vscode RECHAZADO (conector desactivado)" >&2
      elif ! command -v code >/dev/null 2>&1; then
        OBS="ERROR: no se encontró el CLI 'code' de VS Code en el PATH. Se puede habilitar desde VS Code: Ctrl+Shift+P -> 'Shell Command: Install code command in PATH'."
        echo "[nv-agent] iter $it: vscode FALLO (CLI no encontrado)" >&2
      else
        VREL="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
        if [ -z "$VREL" ] || [ "$VREL" = "." ]; then
          VABS="$ROOT"
        else
          VABS="$(_caged "$VREL" || true)"
        fi
        if [ -z "$VABS" ] || [ ! -e "$VABS" ]; then
          OBS="ERROR: ruta inválida, fuera de la raíz, o no existe: $VREL"
          echo "[nv-agent] iter $it: vscode RECHAZADO (ruta inválida): $VREL" >&2
        else
          VWIN="$(_win_path "$VABS")"
          if code -n "$VWIN" >/dev/null 2>&1; then
            OBS="OK: abierto en VS Code: ${VREL:-.}"
            echo "[nv-agent] iter $it: vscode open ${VREL:-.}" >&2
          else
            OBS="ERROR: VS Code no pudo abrir: ${VREL:-.}"
            echo "[nv-agent] iter $it: vscode FALLO (open): $VREL" >&2
          fi
        fi
      fi ;;
    # 'hardware' reemplaza a la vieja tool 'arduino' (2026-08-01). El nombre viejo se sigue
    # aceptando: una conversacion en curso no se puede romper por un cambio de nombre interno.
    # Ahora despacha a mentis-hardware.sh, que cubre FPGA, RISC-V, PlatformIO, MicroPython y la
    # impresora ademas de Arduino. Las acciones viejas (boards/verify/upload/monitor) siguen
    # valiendo y se traducen a los verbos nuevos.
    arduino|hardware)
      if [ "${ALLOW_ARDUINO:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -a para habilitar hardware)."
        echo "[nv-agent] iter $it: hardware RECHAZADO (sin -a)" >&2
      elif [ "$(_connector_enabled 'local:arduino-cli')" != "1" ]; then
        OBS="ERROR: conector de hardware desactivado (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: hardware RECHAZADO (conector desactivado)" >&2
      elif _tope_alcanzado arduino; then
        OBS="$(_tope_mensaje arduino)"
        echo "[nv-agent] iter $it: hardware RECHAZADO (tope de ${TOPE_MAX[arduino]} por turno alcanzado)" >&2
      else
        _tope_sumar arduino
        AACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        ARELPATH="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
        AVALUE="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        HWSH="$MENTIS_ROOT/mentis-hardware.sh"
        case "$AACTION" in
          backends)
            AOUT="$(bash "$HWSH" backends 2>&1)"; ARC=$?
            ;;
          placas|boards)
            AOUT="$(bash "$HWSH" placas 2>&1)"; ARC=$?
            ;;
          nuevo)
            if [ -z "$ARELPATH" ] || [ -z "$AVALUE" ]; then
              AOUT="falta 'path' (carpeta del proyecto) y/o 'value' (la placa)."; ARC=1
            else
              AABS="$(_caged "$ARELPATH" || true)"
              if [ -z "$AABS" ]; then
                AOUT="ruta invalida o fuera de la raiz: $ARELPATH"; ARC=1
              else
                AOUT="$(bash "$HWSH" nuevo "$AABS" "$AVALUE" 2>&1)"; ARC=$?
              fi
            fi
            ;;
          simular)
            if [ -z "$ARELPATH" ]; then
              AOUT="falta 'path' con el proyecto o el archivo.v a simular."; ARC=1
            else
              AABS="$(_caged "$ARELPATH" || true)"
              if [ -z "$AABS" ] || [ ! -e "$AABS" ]; then
                AOUT="ruta invalida, fuera de la raiz, o no existe: $ARELPATH"; ARC=1
              else
                AOUT="$(bash "$HWSH" simular "$AABS" 2>&1)"; ARC=$?
              fi
            fi
            ;;
          laminar)
            if [ -z "$ARELPATH" ]; then
              AOUT="falta 'path' con el modelo 3D a laminar."; ARC=1
            else
              AABS="$(_caged "$ARELPATH" || true)"
              if [ -z "$AABS" ] || [ ! -e "$AABS" ]; then
                AOUT="ruta invalida, fuera de la raiz, o no existe: $ARELPATH"; ARC=1
              else
                AOUT="$(bash "$HWSH" laminar "$AABS" 2>&1)"; ARC=$?
              fi
            fi
            ;;
          verificar|verify|subir|upload)
            if [ -z "$ARELPATH" ]; then
              AOUT="falta 'path' con la ruta del proyecto."; ARC=1
            else
              AABS="$(_caged "$ARELPATH" || true)"
              if [ -z "$AABS" ] || [ ! -e "$AABS" ]; then
                AOUT="ruta inválida, fuera de la raíz, o no existe: $ARELPATH"; ARC=1
              else
                # verify->verificar, upload->subir: los nombres viejos se traducen.
                case "$AACTION" in
                  verify) AVERBO=verificar ;;
                  upload) AVERBO=subir ;;
                  *)      AVERBO="$AACTION" ;;
                esac
                AOUT="$(bash "$HWSH" "$AVERBO" "$AABS" "$AVALUE" 2>&1)"; ARC=$?
              fi
            fi
            ;;
          monitor)
            if [ -z "$ARELPATH" ]; then
              AOUT="falta 'path' con el puerto (ej. COM3)."; ARC=1
            else
              AOUT="$(bash "$HWSH" monitor "$ARELPATH" "${AVALUE:-10}" 2>&1)"; ARC=$?
            fi
            ;;
          *)
            AOUT="accion de hardware desconocida: '$AACTION'. Usa backends|placas|nuevo|verificar|simular|laminar|subir|monitor."; ARC=1
            ;;
        esac
        if [ "$ARC" = "0" ]; then
          OBS="$(_trunc <<< "$AOUT")"
          echo "[nv-agent] iter $it: hardware $AACTION" >&2
        else
          # Una herramienta que falta NO es lo mismo que una accion que fallo: el mensaje de
          # mentis-hardware.sh ya explica que instalar, y taparlo con "ERROR:" haria que el
          # modelo pruebe otra cosa en vez de decirle al usuario que le falta una herramienta.
          if [ "$ARC" = "3" ]; then
            OBS="$(_trunc <<< "$AOUT")"
            echo "[nv-agent] iter $it: hardware $AACTION -- falta una herramienta" >&2
          else
            OBS="ERROR: $AOUT"
            echo "[nv-agent] iter $it: hardware FALLO ($AACTION)" >&2
          fi
        fi
      fi ;;
    datos)
      if [ "${ALLOW_DATOS:-0}" != "1" ]; then
        OBS="ERROR: herramienta deshabilitada (correr nv-agent.sh con -D para habilitar Datos externos)."
        echo "[nv-agent] iter $it: datos RECHAZADO (sin -D)" >&2
      elif [ "$(_connector_enabled 'local:datos-externos')" != "1" ]; then
        OBS="ERROR: conector de Datos externos desactivado (Directorio -> Conectores en la app de Mentis)."
        echo "[nv-agent] iter $it: datos RECHAZADO (conector desactivado)" >&2
      else
        DACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        DPATH="$(_b64d "${PATH_B64:-}" 2>/dev/null || true)"
        DVALUE="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        case "$DACTION" in
          overpass|archive|doaj|papers|wikipedia|nominatim)
            DOUT="$(bash "$MENTIS_ROOT/mentis-datos.sh" "$DACTION" "$DVALUE" 2>&1)"; DRC=$?
            ;;
          georef)
            DOUT="$(bash "$MENTIS_ROOT/mentis-datos.sh" georef "$DPATH" "$DVALUE" 2>&1)"; DRC=$?
            ;;
          opensky)
            IFS=',' read -r DLAMIN DLOMIN DLAMAX DLOMAX <<< "$DVALUE"
            DOUT="$(bash "$MENTIS_ROOT/mentis-datos.sh" opensky "$DLAMIN" "$DLOMIN" "$DLAMAX" "$DLOMAX" 2>&1)"; DRC=$?
            ;;
          nasa)
            DOUT="$(bash "$MENTIS_ROOT/mentis-datos.sh" nasa apod "$DVALUE" 2>&1)"; DRC=$?
            ;;
          overture)
            DOUT="$(bash "$MENTIS_ROOT/mentis-datos.sh" overture "$DPATH" "$DVALUE" 2>&1)"; DRC=$?
            ;;
          *)
            DOUT="accion de datos desconocida: '$DACTION'. Usa overpass|georef|opensky|nasa|archive|doaj|papers|wikipedia|overture|nominatim."; DRC=1
            ;;
        esac
        if [ "$DRC" = "0" ]; then
          OBS="$(_trunc <<< "$DOUT")"
          echo "[nv-agent] iter $it: datos $DACTION" >&2
        else
          OBS="ERROR: $DOUT"
          echo "[nv-agent] iter $it: datos FALLO ($DACTION)" >&2
        fi
      fi ;;
    delegate)
      DROLE="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
      DPROMPT="$(_b64d "${PROMPT_B64:-}" 2>/dev/null || true)"
      if [[ ! "$DROLE" =~ ^(code|reason|deep|general|extract|multimodal|ultra)$ ]]; then
        OBS="ERROR: rol de delegate invalido: '$DROLE'. Usa code|reason|deep|general|extract|multimodal|ultra."
        echo "[nv-agent] iter $it: delegate RECHAZADO (rol invalido: $DROLE)" >&2
      elif [ -z "$DPROMPT" ]; then
        OBS="ERROR: falta 'prompt' para delegate. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
      else
        DRESP="$(printf '%s' "$DPROMPT" | bash "$NVDIR/ask-nvidia.sh" -r "$DROLE" 2>/dev/null || true)"
        [ -z "$DRESP" ] && DRESP="(el cerebro '$DROLE' no respondio)"
        OBS="$(printf 'respuesta de %s:\n%s' "$DROLE" "$DRESP" | _trunc)"
        echo "[nv-agent] iter $it: delegate -> $DROLE" >&2
      fi ;;
    parallel)
      PJSON="$(_b64d "${ARGS_B64:-}" 2>/dev/null || echo '[]')"
      PCOUNT="$(printf '%s' "$PJSON" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception:
    print(0)' 2>/dev/null)"
      if ! [[ "$PCOUNT" =~ ^[0-9]+$ ]] || [ "$PCOUNT" -lt 1 ] || [ "$PCOUNT" -gt 6 ]; then
        OBS="ERROR: 'args' de parallel tiene que ser una lista de 1 a 6 objetos {\"role\":...,\"prompt\":...}."
        echo "[nv-agent] iter $it: parallel RECHAZADO (args invalidos)" >&2
      else
        PTMPDIR="$(mktemp -d)"
        # Extraer role+prompt de CADA elemento en UNA sola pasada de python, con manejo de
        # elementos malformados (no-objeto) adentro del propio python -- bug real encontrado en
        # auditoria 2026-07-14: las 3 extracciones por-elemento de antes eran `python3 -c` sueltos
        # (uno para role, otro para prompt, y un tercero repitiendo role al armar OBS) SIN
        # try/except y sin `if` que las proteja; bajo `set -e` (linea 24), un elemento no-objeto
        # en "args" (ej. un string suelto) hacia que python tirara AttributeError y el script
        # entero abortara en silencio, exit 1, sin ninguna respuesta al llamador. Confirmado con
        # PJSON='[{"role":"code","prompt":"hola"}, "esto_no_es_un_objeto"]'. El prompt viaja en
        # base64 en el TSV para no romper el `while read` con saltos de linea/tabs embebidos.
        PMETA="$PTMPDIR/meta.tsv"
        printf '%s' "$PJSON" | python3 -c '
import json, sys, base64
d = json.load(sys.stdin)
for item in d:
    role = item.get("role", "general") if isinstance(item, dict) else "general"
    prompt = item.get("prompt", "") if isinstance(item, dict) else ""
    if not isinstance(role, str): role = "general"
    if not isinstance(prompt, str): prompt = ""
    role = role.replace("\n", " ").replace("\t", " ")
    print(role + "\t" + base64.b64encode(prompt.encode("utf-8", "replace")).decode())
' > "$PMETA" 2>/dev/null || true
        PPIDS=()
        PROLES=()
        pi=0
        while IFS=$'\t' read -r PROLE PPROMPT_B64; do
          PPROMPT="$(printf '%s' "$PPROMPT_B64" | base64 -d 2>/dev/null || true)"
          [[ "$PROLE" =~ ^(code|reason|deep|general|extract|multimodal|ultra)$ ]] || PROLE="general"
          PROLES[$pi]="$PROLE"
          ( printf '%s' "$PPROMPT" | bash "$NVDIR/ask-nvidia.sh" -r "$PROLE" > "$PTMPDIR/out-$pi.txt" 2>/dev/null ) &
          PPIDS+=("$!")
          pi=$((pi+1))
        done < "$PMETA"
        for _pid in "${PPIDS[@]}"; do wait "$_pid" 2>/dev/null || true; done
        OBS=""
        for (( pi=0; pi<PCOUNT; pi++ )); do
          PRES="$(cat "$PTMPDIR/out-$pi.txt" 2>/dev/null)"
          [ -z "$PRES" ] && PRES="(sin respuesta)"
          OBS="$OBS
--- resultado $((pi+1)) (${PROLES[$pi]:-general}) ---
$PRES"
        done
        OBS="$(printf '%s' "$OBS" | _trunc)"
        rm -rf "$PTMPDIR"
        echo "[nv-agent] iter $it: parallel ($PCOUNT tareas en simultaneo)" >&2
      fi ;;
    subagent)
      # Sub-agente real (pedido del usuario, a la par de los sub-agentes de Claude Code): a
      # diferencia de 'delegate' (una sola consulta sin herramientas), esto invoca OTRA
      # instancia completa de nv-agent.sh con su propio loop de herramientas -- puede leer,
      # buscar y navegar por su cuenta para resolver una sub-tarea autonoma. Presupuesto FIJO
      # chico (4 iteraciones) y SOLO LECTURA (sin -w/-e/-c/-g/etc): un sub-agente nunca escribe,
      # ejecuta ni gasta recursos reales por su cuenta -- si la sub-tarea necesita eso, el
      # cerebro principal la hace el mismo, no la delega. Profundidad maxima 1: un sub-agente
      # NO puede spawnear otro (NVA_SUBAGENT_DEPTH), para no crear una cadena sin limite.
      if [ "${NVA_SUBAGENT_DEPTH:-0}" -ge 1 ]; then
        OBS="ERROR: un sub-agente no puede spawnear otro sub-agente (limite de profundidad=1)."
        echo "[nv-agent] iter $it: subagent RECHAZADO (profundidad excedida)" >&2
      else
        SAROLE="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
        SAPROMPT="$(_b64d "${PROMPT_B64:-}" 2>/dev/null || true)"
        # Presupuesto configurable (2026-07-28). Estaba clavado en 4 iteraciones, y medido en vivo
        # eso no alcanza ni para una tarea de clasificacion: el sub-agente se quedaba sin nafta
        # leyendo, devolvia STATUS=budget y su trabajo se tiraba a la basura. Ahora lo pide quien
        # lo lanza, con un tope: 12 es el mismo default que tiene el agente principal, y mas que
        # eso deja de ser una sub-tarea.
        SAITER="$(_b64d "${VALUE_B64:-}" 2>/dev/null || true)"
        [[ "$SAITER" =~ ^[0-9]+$ ]] || SAITER=8
        [ "$SAITER" -lt 2 ] && SAITER=2
        [ "$SAITER" -gt 12 ] && SAITER=12
        # Herramientas GRADUADAS: leer y buscar siempre; la web sólo si se pide explícitamente.
        # Escribir y ejecutar siguen prohibidos y no son negociables desde el JSON -- un
        # sub-agente que nadie está mirando no toca archivos ni corre comandos.
        SAWEB="$(_b64d "${ARGS_B64:-}" 2>/dev/null || echo '{}')"
        SAFLAGS=()
        case "$SAWEB" in *'"web"'*'true'*) SAFLAGS+=(-b) ;; esac
        if [[ ! "$SAROLE" =~ ^(code|reason|deep|general|extract|multimodal|ultra)$ ]]; then
          OBS="ERROR: rol de subagent invalido: '$SAROLE'. Usa code|reason|deep|general|extract|multimodal|ultra."
          echo "[nv-agent] iter $it: subagent RECHAZADO (rol invalido: $SAROLE)" >&2
        elif [ -z "$SAPROMPT" ]; then
          OBS="ERROR: falta 'prompt' para subagent. NO repitas la misma llamada sin ese campo: completalo, o si el pedido no lo necesita, seguí con otra herramienta o cerrá con 'done'."
        else
          echo "[nv-agent] iter $it: subagent -> $SAROLE (presupuesto $SAITER iter, solo lectura${SAFLAGS:+, con web})" >&2
          SARESP="$(NVA_SUBAGENT_DEPTH=1 bash "$NVDIR/nv-agent.sh" -d "$ROOT" -m "$SAROLE" -i "$SAITER" "${SAFLAGS[@]}" "$SAPROMPT" 2>/dev/null || true)"
          if [ -z "$SARESP" ]; then
            OBS="ERROR: el sub-agente no devolvio nada (revisar el log de progreso)."
          elif printf '%s' "$SARESP" | head -1 | grep -q '^STATUS=budget'; then
            # NO se le pasa el historial crudo y listo: el cerebro principal recibia un volcado
            # sin saber que estaba leyendo un intento fallido, y lo trataba como si fuera la
            # respuesta. Ahora se le dice qué pasó y cuáles son sus dos salidas reales.
            OBS="$(printf 'El sub-agente (%s) se quedó SIN PRESUPUESTO a las %s iteraciones y NO llegó a una respuesta.\nEsto de abajo es lo que alcanzó a explorar, NO una conclusión -- no lo cites como si lo fuera.\nTenés dos opciones: volver a lanzarlo con más iteraciones (campo "value", hasta 12) y un pedido más acotado, o resolverlo vos mismo.\n\n%s' "$SAROLE" "$SAITER" "$SARESP" | _trunc)"
            echo "[nv-agent] iter $it: el sub-agente agoto su presupuesto ($SAITER iter) sin terminar" >&2
          elif printf '%s' "$SARESP" | head -1 | grep -q '^STATUS='; then
            OBS="$(printf 'El sub-agente (%s) termino mal: %s. Lo explorado:\n%s' "$SAROLE" "$(printf '%s' "$SARESP" | head -1)" "$SARESP" | _trunc)"
          else
            OBS="$(printf 'resultado del sub-agente (%s, solo lectura, %s iter max):\n%s' "$SAROLE" "$SAITER" "$SARESP" | _trunc)"
          fi
        fi
      fi ;;
    task)
      # Tracking de tareas de una sesion larga (pedido del usuario, a la par de TaskCreate/
      # TaskUpdate/TaskList de Claude Code). Un archivo.mentis-tasks.json vive DENTRO de $ROOT
      # -- persiste entre iteraciones de este mismo turno Y entre turnos futuros de la misma
      # conversacion (mismo ROOT), pero no se mezcla con otro workspace.
      TACTION="$(_b64d "${ACTION_B64:-}" 2>/dev/null || true)"
      # Robustez (bug real encontrado en prueba en vivo, 2026-07-17): el modelo a veces anida
      # los campos de 'task' dentro de "args" (imitando el patron de 'parallel') en vez de
      # ponerlos sueltos como documentado. Si el campo suelto vino vacio, se intenta sacar el
      # mismo dato de adentro de "args" antes de dar error.
      TARGS_JSON="$(_b64d "${ARGS_B64:-}" 2>/dev/null || echo '{}')"
      _task_field_or_args() {
        local direct="$1" key="$2"
        if [ -n "$direct" ]; then printf '%s' "$direct"; return; fi
        printf '%s' "$TARGS_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get(sys.argv[1], '') if isinstance(d, dict) else ''
    print(v if v is not None else '', end='')
except Exception:
    pass
" "$key"
      }
      case "$TACTION" in
        create)
          TSUBJECT="$(_task_field_or_args "$(_b64d "${SUBJECT_B64:-}" 2>/dev/null || true)" subject)"
          TDESC="$(_task_field_or_args "$(_b64d "${DESCRIPTION_B64:-}" 2>/dev/null || true)" description)"
          # SI FALTA EL TITULO PERO HAY DESCRIPCION, SE DERIVA EN VEZ DE RECHAZAR (2026-08-12).
          # El mensaje de abajo ya explicaba con todas las letras como mandar 'subject', y aun asi
          # el modelo reintentaba sin el hasta que el corta-bucles mataba el turno: el usuario se quedaba
          # sin respuesta por un campo que se puede deducir de lo que YA mando. Es la leccion del
          # ERR-143: cuando insiste despues de dos explicaciones, el que esta equivocado es el que
          # exige el campo. El titulo son las primeras palabras de la descripcion, cortadas en el
          # ultimo espacio para no partir una palabra al medio.
          if [ -z "$TSUBJECT" ] && [ -n "${TDESC// }" ]; then
            TSUBJECT="$(printf '%s' "$TDESC" | tr '\n' ' ' | cut -c1-60 | sed 's/ [^ ]*$//; s/ *$//')"
            [ -z "${TSUBJECT// }" ] && TSUBJECT="$(printf '%s' "$TDESC" | cut -c1-60)"
            echo "[nv-agent] iter $it: task create sin 'subject' -- derivado de la descripcion: '$TSUBJECT'" >&2
          fi
          if [ -z "$TSUBJECT" ]; then
            # EL RECHAZO TIENE QUE ENSEÑAR, NO SOLO NEGAR (2026-08-12). El mensaje anterior era
            # "ERROR: falta 'subject' para task create." y nada más. El modelo no sabía qué
            # corregir, así que reintentaba lo mismo: cuatro vueltas seguidas hasta que el
            # corta-bucles cortó el turno, y el usuario se quedó sin respuesta por un campo faltante.
            # Es la misma lección que dejó el tope de la cámara: un rechazo que no dice cómo
            # seguir manda al modelo a chocar contra la misma pared.
            #
            # El mensaje da las dos salidas: la forma exacta si de verdad hace falta la tarea, y
            # el permiso explícito de NO crearla -- porque el caso real que disparó esto fue un
            # "hola, esto es una prueba", donde la tarea no tenía por qué existir.
            # SIN TITULO Y SIN DESCRIPCION no hay nada que derivar ni nada que anotar: la llamada
            # esta vacia. Y la observacion NO empieza con "ERROR:" a proposito (2026-08-12): con
            # el mensaje de error, el modelo reintentaba la misma llamada vacia tres veces hasta
            # que el corta-bucles mataba el turno y el usuario se quedaba sin respuesta. Un error lo
            # empuja a corregir la herramienta; lo que hace falta es que deje la herramienta y
            # conteste. Por eso esto se lee como una instruccion y no como una falla.
            OBS="No cree ninguna tarea (la llamada vino sin 'subject' ni 'description', asi que no habia nada que anotar) y NO hace falta que lo intentes de nuevo. Lo que el usuario pregunto se contesta hablando: responde AHORA con {\"tool\":\"done\"} y tu respuesta adentro. Si mas adelante hiciera falta anotar un trabajo largo de varios pasos, la forma es {\"tool\":\"task\",\"action\":\"create\",\"subject\":\"titulo corto\",\"description\":\"detalle\"}."
          else
            OBS="$(bash "$MENTIS_ROOT/mentis-tasks.sh" create "$ROOT" "$TSUBJECT" "$TDESC" 2>&1)"
          fi
          echo "[nv-agent] iter $it: task create" >&2 ;;
        update)
          TID="$(_task_field_or_args "$(_b64d "${ID_B64:-}" 2>/dev/null || true)" id)"
          TSTATUS="$(_task_field_or_args "$(_b64d "${STATUS_B64:-}" 2>/dev/null || true)" status)"
          if [[ ! "$TID" =~ ^[0-9]+$ ]]; then
            OBS="ERROR: 'id' de task update tiene que ser numerico."
          else
            OBS="$(bash "$MENTIS_ROOT/mentis-tasks.sh" update "$ROOT" "$TID" "$TSTATUS" 2>&1)"
          fi
          echo "[nv-agent] iter $it: task update #$TID -> $TSTATUS" >&2 ;;
        list)
          OBS="$(bash "$MENTIS_ROOT/mentis-tasks.sh" list "$ROOT" 2>&1)"
          echo "[nv-agent] iter $it: task list" >&2 ;;
        *)
          OBS="ERROR: 'action' de task invalida: '$TACTION'. Usa create|update|list."
          echo "[nv-agent] iter $it: task RECHAZADO (action invalida: $TACTION)" >&2 ;;
      esac ;;
    *)
      OBS="ERROR: herramienta desconocida: '$TOOL'. Usá read|search|run|done|delegate|parallel|subagent|task|control|vscode|webcam."
      echo "[nv-agent] iter $it: tool desconocida: $TOOL" >&2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

REPARTO=0
TABLERO=0
ROLE="reason"; MAXIT=20; ROOT="$PWD"; ALLOW_WRITE=0; ALLOW_BROWSE=0; ALLOW_MCP=0; ALLOW_GEN=0; ALLOW_SCREEN=0; ALLOW_DANGEROUS=0; ALLOW_CONTROL=0; ALLOW_EDITOR=0; ALLOW_ARDUINO=0; ALLOW_DATOS=0; ALLOW_CARBS=0; ALLOW_WEBCAM=0; ALLOW_TELEFONO=0; ALLOW_SKILLS=0; ALLOW_TELEFONO=0
IMG_ATTACH=()
SIN_TOOLS="${NVA_SIN_TOOLS:-}"
while getopts ":d:m:i:n:wbtgscexaDCVPKpTI:" opt; do
  case "$opt" in
    d) ROOT="$OPTARG" ;;
    m) ROLE="$OPTARG" ;;
    # -n: herramientas que este turno NO puede usar, separadas por coma. Ver el bloque
    # "HERRAMIENTAS QUE ESTE TURNO NO PUEDE USAR" mas abajo. Vacio = todo como siempre.
    n) SIN_TOOLS="$OPTARG" ;;
    i) MAXIT="$OPTARG" ;;
    w) ALLOW_WRITE=1 ;;
    b) ALLOW_BROWSE=1 ;;
    t) ALLOW_MCP=1 ;;
    g) ALLOW_GEN=1 ;;
    P) ALLOW_TELEFONO=1 ;;
    K) ALLOW_SKILLS=1 ;;
    s) ALLOW_SCREEN=1 ;;
    V) ALLOW_WEBCAM=1 ;;
    x) ALLOW_DANGEROUS=1 ;;
    c) ALLOW_CONTROL=1 ;;
    e) ALLOW_EDITOR=1 ;;
    a) ALLOW_ARDUINO=1 ;;
    D) ALLOW_DATOS=1 ;;
    # -p: reparto automatico (paralelo). OJO: en mentis-chat.sh "-R" ya significa modo remoto, por
    # eso aca la letra es otra. El motor pide un plan y, si la tarea se parte en dos o mas piezas
    # independientes, las resuelve EN PARALELO antes de empezar el loop. Lo pasa mentis-chat.sh
    # cuando el modo tiene la herramienta 'parallel' (hoy: Cowork). Ver el bloque AUTO-REPARTO.
    p) REPARTO=1 ;;
    # -T: tablero de tareas del turno (modo Cowork). Ver el bloque TABLERO DE TAREAS.
    T) TABLERO=1 ;;
    I) IMG_ATTACH+=("$OPTARG") ;;
    *) echo "ERROR: opción inválida -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))
TASK="${*:-}"
[ -z "${TASK// }" ] && { echo "Uso: nv-agent.sh [-d dir] [-m rol] [-i max_iter] [-n tools,prohibidas] \"<tarea>\"" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "ERROR: dir raíz no existe: $ROOT" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"   # canónico

OBSMAX="${NV_AGENT_OBSMAX:-2000}"   # tope de chars por observación devuelta al modelo
HIST=""                              # historial acumulado (acciones + observaciones)

# FOTO ANTES DE TOCAR NADA (2026-07-27). Se saca UNA por turno, la primera vez que el agente va
# a modificar algo de verdad -- no en cada write, que sería lento y llenaría la lista de ruido.
# Si el turno sale mal, `mentis-deshacer.sh volver <dir> <id>` devuelve la carpeta a como estaba.
# El repo sombra vive aparte y NUNCA toca el.git que el usuario pueda tener en esa carpeta.
FOTO_TOMADA=0
_foto_antes_de_tocar() {
  [ "$FOTO_TOMADA" = "1" ] && return 0
  [ "${MENTIS_DESHACER:-1}" = "1" ] || return 0
  FOTO_TOMADA=1
  local id
  # El `|| true` NO es decorativo (2026-07-29). Bajo `set -e`, una asignación cuyo comando falla
  # mata el script -- y acá el comando es un script externo que puede no estar, fallar o pasarse
  # de los 30 s. Como además el stderr va a /dev/null, moría EN SILENCIO: el agente se apagaba
  # justo antes de la primera escritura, sin log, sin error y con código de salida 0.
  # Se descubrió porque toda una suite de tests venía dando verde en la mitad de sus casos por
  # esta razón (ERR-095), pero el agujero es de producción: la foto de seguridad es un servicio
  # AUXILIAR, y que falte no puede impedir que Mentis trabaje. Que no haya red no es motivo para
  # cancelar la función; sí lo es para avisar que hoy no hay red.
  if ! id="$(timeout 30 bash "$MENTIS_ROOT/mentis-deshacer.sh" foto "$ROOT" "antes de: $(printf '%s' "$TASK" | head -c 90)" 2>/dev/null)"; then
    id=""
    echo "[nv-agent] AVISO: no pude sacar el punto de retorno previo (mentis-deshacer.sh no respondió). Sigo, pero este turno no se va a poder deshacer." >&2
  fi
  if [ -n "${id// }" ]; then
    echo "[nv-agent] punto de retorno $id (para volver: mentis-deshacer.sh volver \"$ROOT\" $id)" >&2
  fi
  return 0
}

# Las observaciones descargadas del turno ANTERIOR ya no le sirven a nadie: sus referencias
# vivían en el historial de ese turno, que se descartó. Se limpian acá y no al final del turno
# a propósito -- si un turno se corta a la mitad, los archivos quedan para poder mirarlos.
rm -rf "$ROOT/$OBSDIR_REL" 2>/dev/null || true
WRITE_CNT=0; EXEC_CNT=0
# EVIDENCIA_N: cuantas PRUEBAS FRESCAS de terminal hubo en este turno. Distinto de EXEC_CNT, que
# cuenta INTENTOS de exec (se incrementa incluso cuando el comando se rechaza por permisos o
# llega vacio, casos donde no se ejecuto nada). Solo suman: un 'exec' que corrio de verdad y
# salio con exit 0, y una verificacion independiente que PASO. Es lo unico que el gate de
# completitud acepta como respaldo de un "funciona".
EVIDENCIA_N=0
# Cuantas veces se rechazo el cierre por falta de evidencia. A la segunda no se rechaza mas: se
# corrige el texto (misma leccion que la guarda de documento -- rechazar en bucle quema el turno).
GATE_RECHAZOS=0
# Idem para la guarda de "los archivos que nombra existen".
ARCH_RECHAZOS=0
# Y para la guarda de eco: cuantas veces se rechazo un 'done' que era mi propio texto de vuelta.
ECO_RECHAZOS=0
# Donde se anota TODO lo que este turno le dijo al modelo, para poder preguntarle despues a la
# respuesta final si es texto propio. Se borra al terminar el turno (trap de abajo): es un dato de
# trabajo, no un registro que valga la pena guardar.
NVA_OBS_LOG="${NVA_OBS_LOG:-$(mktemp -t nva-obs-XXXXXX 2>/dev/null || echo "")}"
[ -n "$NVA_OBS_LOG" ] && trap 'rm -f "$NVA_OBS_LOG" 2>/dev/null' EXIT

PROTOCOL="$(nv_texto protocolo/base)"

if [ "$ALLOW_WRITE" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/write)"
  if [ "$ALLOW_DANGEROUS" = "1" ]; then
    PROTOCOL="$PROTOCOL
$(nv_texto protocolo/sin-frenos)"
  fi
fi

if [ "$ALLOW_BROWSE" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/browse)"
fi

if [ "$ALLOW_MCP" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/mcp)"
fi

if [ "$ALLOW_SCREEN" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/screen)"
fi

if [ "$ALLOW_WEBCAM" = "1" ]; then
  NVA_FICHA_WEBCAM="
$(nv_texto protocolo/webcam)"
fi

if [ "$ALLOW_CONTROL" = "1" ]; then
  NVA_FICHA_CONTROL="
$(nv_texto protocolo/control)"
fi

if [ "$ALLOW_EDITOR" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/vscode)"
fi

if [ "$ALLOW_DATOS" = "1" ]; then
  NVA_FICHA_DATOS="
$(nv_texto protocolo/datos)"
fi


if [ "$ALLOW_ARDUINO" = "1" ]; then
  NVA_FICHA_ARDUINO="
$(nv_texto protocolo/arduino)"
fi

if [ "$ALLOW_SKILLS" = "1" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/skills)"
fi

if [ "$ALLOW_TELEFONO" = "1" ]; then
  NVA_FICHA_TELEFONO="
$(nv_texto protocolo/telefono)"
fi

# --- INDICE DE CAPACIDADES BAJO DEMANDA (2026-08-03, A5 del plan) --------------------------------
# El protocolo pesaba 27.032 caracteres con todo prendido -- y la app prende todo por defecto
# desde el "sin fronteras" del 2026-07-12. Eso viaja ENTERO en cada turno, incluida la ficha
# completa del Arduino cuando el usuario pregunta que hora es.
#
# Las siete capacidades mas pesadas y de uso mas explicito (el usuario las pide por su nombre: "prende
# el arduino", "conta los carbohidratos", "mira por la camara") ya no viajan enteras: viaja UNA
# LINEA por capacidad y la ficha completa se pide con {"tool":"capacidad","action":"<nombre>"}.
#
# SIN EMBEDDINGS, Y ESO ES DELIBERADO. Filtrar por parecido semantico puede ESCONDER la
# herramienta que hacia falta, y entonces Mentis no falla con un error: dice que no puede hacer
# algo que si puede. Es ERR-084, el modo de falla mas dificil de detectar. Aca no se esconde
# nada: la capacidad SIEMPRE aparece en el indice, siempre se puede pedir, y el texto del indice
# esta escrito para que "no puedo" nunca sea una lectura posible.
# Google Drive (2026-08-03, B3 del plan). Va bajo ALLOW_WRITE y no bajo una bandera propia por
# dos razones: subir un archivo es una accion de ESCRITURA hacia afuera, y el modo remoto (la
# pagina del celular) ya apaga ALLOW_WRITE -- que es exactamente donde no se quiere que Mentis
# suba cosas a la nube del usuario sin que el este sentado adelante.
if [ "$ALLOW_WRITE" = "1" ] && [ -f "$MENTIS_ROOT/mentis-drive.sh" ]; then
  NVA_FICHA_DRIVE="
$(nv_texto protocolo/drive)"
fi

# LA FICHA DE 'gen' SE ARMA ACA ARRIBA Y NO ABAJO, Y ESO ES UN ARREGLO (2026-08-15).
# Estaba despues del indice: _nva_indexar "gen" leia "${NVA_FICHA_GEN:-}" quince lineas antes de
# que existiera, o sea SIEMPRE vacia, y la funcion sale temprano cuando la ficha esta vacia. Con
# -g puesto, el modelo no recibia ni la ficha de 'gen' ni su linea en el indice: no sabia que
# podia generar imagenes, modelos 3D ni documentos.
# Venia "funcionando" porque el modelo deducia el formato de la persona del modo Designe -- es
# decir, adivinando exactamente lo que el propio indice le prohibe: "NUNCA lo intentes de memoria
# inventando el formato". Es ERR-084 otra vez: no falla, hace de menos.
if [ "$ALLOW_GEN" = "1" ]; then
  NVA_FICHA_GEN="
$(nv_texto protocolo/gen CREACIONES="$MENTIS_CREATIONS_DIR")"
fi

NVA_INDICE=""
_nva_indexar() {
  # $1 = nombre para el modelo, $2 = contenido de la ficha, $3 = una linea de que hace
  [ -n "$2" ] || return 0
  NVA_INDICE="$NVA_INDICE
  - \"$1\": $3"
}
_nva_indexar "gen"      "${NVA_FICHA_GEN:-}"      "generar imagenes, modelos 3D y documentos (docx/pdf/pptx/xlsx) reales."
_nva_indexar "arduino"  "${NVA_FICHA_ARDUINO:-}"  "programar y hablar con placas Arduino/ESP32 conectadas por USB."
_nva_indexar "control"  "${NVA_FICHA_CONTROL:-}"  "mover el mouse y escribir con el teclado de la computadora del usuario."
_nva_indexar "datos"    "${NVA_FICHA_DATOS:-}"    "fuentes de datos reales: mapas, vuelos en vivo, Wikipedia, papers, NASA."
_nva_indexar "webcam"   "${NVA_FICHA_WEBCAM:-}"   "mirar por la camara y ver que hay en la habitacion."
_nva_indexar "${NVA_FICHA_CARBS:-}"    "estimar los gramos de carbohidratos de una comida (el usuario tiene )."
_nva_indexar "telefono" "${NVA_FICHA_TELEFONO:-}" "ver notificaciones del celular, hacerlo sonar y mandar mensajes."
_nva_indexar "drive"    "${NVA_FICHA_DRIVE:-}"    "subir archivos a Google Drive (sin API: por la app de escritorio)."

if [ -n "$NVA_INDICE" ]; then
  PROTOCOL="$PROTOCOL
$(nv_texto protocolo/indice INDICE="$NVA_INDICE")"
fi

# ===================== HERRAMIENTAS QUE ESTE TURNO NO PUEDE USAR (-n) =====================
#
# POR QUE EXISTE (2026-08-10, sistema de modos): las banderas -w -b -t -g... alcanzan para las
# herramientas que nacieron opcionales, pero hay un grupo que SIEMPRE estuvo en el protocolo base
# y no tiene bandera: 'delegate', 'parallel', 'subagent', 'lsp', 'git', 'exec'. El modo "Mentis a
# secas" tiene que poder sacarlas, y agregarles una bandera a cada una habria sido inventar seis
# banderas para una sola politica.
#
# ESTO NO SABE QUE ES UN MODO, A PROPOSITO. Recibe una lista de nombres y los saca. Quien decide
# esa lista es mentis-chat.sh, que si conoce los modos. El motor ejecuta politica, no la define --
# si no, cada llamador de nv-agent.sh (las skills, los sub-agentes, mentis-delegar.sh) tendria que
# aprender de modos para poder llamarlo.
#
# SE SACAN EN DOS CAPAS Y LAS DOS HACEN FALTA:
#   1. Del PROTOCOLO, para que el modelo ni siquiera sepa que existen. Sin esto se las pasa
#      pidiendo y gastando iteraciones contra una puerta cerrada.
#   2. Del despacho (mas abajo), para que si igual la pide, bash la rechace. La leccion de la
#      camara: cualquier defensa escrita como instruccion al modelo es una sugerencia.
#
# El filtro saca la linea de la herramienta Y sus lineas de continuacion (las que van con 4
# espacios o mas). 'subagent' ocupa cuatro lineas: sacar solo la primera dejaria tres lineas
# huerfanas explicando como usar algo que no existe, que es peor que dejarla entera.
if [ -n "${SIN_TOOLS// }" ]; then
  PROTOCOL="$(printf '%s\n' "$PROTOCOL" | SIN="$SIN_TOOLS" awk '
    BEGIN {
      n = split(ENVIRON["SIN"], v, /[, ]+/)
      for (i = 1; i <= n; i++) if (v[i] != "") prohibida[v[i]] = 1
      saltando = 0
    }
    {
      # Linea de continuacion: pertenece a la herramienta anterior.
      if (saltando && $0 ~ /^    [^ ]/) next
      saltando = 0
      if (match($0, /^  \{\\?"tool\\?":\\?"[a-z]+/)) {
        linea = $0
        sub(/^  \{\\?"tool\\?":\\?"/, "", linea)
        sub(/[^a-z].*$/, "", linea)
        if (linea in prohibida) { saltando = 1; next }
      }
      print
    }')"
  echo "[nv-agent] herramientas apagadas este turno: $SIN_TOOLS" >&2
fi

# Salida de diagnostico: imprime el protocolo ya armado y filtrado, y sale sin llamar a ningun
# modelo. Existe para que el test de modos pueda comprobar el filtro contra el protocolo REAL en
# vez de contra una copia -- una copia se desactualiza y el test pasa a aprobar algo que ya no es
# lo que corre (fue exactamente el problema de ERR-130). No consume nada ni toca archivos.
if [ "${NVA_SOLO_PROTOCOLO:-0}" = "1" ]; then
  printf '%s\n' "$PROTOCOL"
  exit 0
fi

echo "[nv-agent] tarea: $TASK" >&2
echo "[nv-agent] raíz: $ROOT | rol: $ROLE | presupuesto: $MAXIT iter" >&2

# Imagenes adjuntas (-I, acumulable) se re-adjuntan en CADA llamada del loop -- el modelo
# necesita "verlas" en cada turno de razonamiento, no solo en el primero.
IMG_FLAGS=()
for _img in "${IMG_ATTACH[@]:-}"; do
  [ -n "$_img" ] && IMG_FLAGS+=("-I" "$_img")
done

FINAL=""; STATUS="budget"
# Protocolo de error (pedido del usuario, 2026-07-12, ver bug real: CAPTCHA de Bing + 3 llamadas
# repetidas a 'delegate' sin usar ninguna respuesta -> se quedaba dando vueltas hasta gastar
# el presupuesto). PREV_TOOL/SAME_TOOL_STREAK detectan reintentos ciegos de la misma
# herramienta fallando; DELEGATE_LIKE_COUNT detecta abuso de delegate/parallel. Ninguno de los
# dos bloquea nada -- solo le avisan al modelo, en el prompt del PROXIMO turno, que cambie de
# estrategia en vez de seguir insistiendo.
# Doble cerebro para computer-use (pedido del usuario, 2026-07-17): cuando ALLOW_CONTROL esta
# activo, el cerebro RAPIDO ('fast') navega iteracion a iteracion (click/scroll/mover, decidir
# donde esta algo en pantalla) -- es mecanico y no necesita razonamiento profundo. El cerebro
# avanzado ($ROLE, el pedido originalmente por el usuario con -m) SOLO entra cuando: (a) es la
# primera iteracion (planificacion inicial, ya le pide el prompt que use 'screen' antes de
# actuar), (b) hay que escribir contenido compuesto (control type con texto largo -- redactar,
# no tipear una tecla), o (c) la misma herramienta viene fallando 2+ veces seguidas (la senal
# de "esto necesita mas razonamiento" que YA existia via SAME_TOOL_STREAK). Escalada STICKY:
# una vez que se activa el cerebro avanzado para este turno, se queda ahi el resto del turno
# (no vuelve a bajar a 'fast' a mitad de una tarea que ya demostro necesitar mas criterio).
CU_ESCALATED=0
PREV_TOOL=""; SAME_TOOL_STREAK=0; DELEGATE_LIKE_COUNT=0; HAD_REAL_ACTION=0
# Bucle de ACIERTOS: la misma accion EXITOSA repetida no dispara ningun detector de errores.
# Cuenta por FIRMA de accion (herramienta + argumentos), no consecutivas: un bucle alternado
# (A, B, A, B) es igual de mortal que uno seguido y la version por rachas no lo veia.
declare -A OK_SIG_COUNT=()
OK_SIG_MAX=3
# El techo: a partir de aca no se avisa mas, se corta el turno. Son tres avisos ignorados antes de
# cortar -- suficiente evidencia de que el modelo no va a reaccionar, y nueve iteraciones menos que
# las quince del caso que lo motivo. Se puede subir con MENTIS_BUCLE_CORTE.
OK_SIG_CORTE="${MENTIS_BUCLE_CORTE:-6}"
# LO QUE ESTE TURNO ESCRIBIO, con su huella (2026-08-15). Sirve para no releer lo propio: ver la
# guarda "YA LO ESCRIBISTE VOS" mas abajo. La huella es del CONTENIDO, no de la ruta: si un
# comando modifica el archivo despues, deja de coincidir y releerlo vuelve a ser legitimo.
declare -A ESCRITO_HUELLA=()
RELEE_PROPIO=0
# CUANDO YA LO LOGRASTE, TERMINA (2026-08-08).
#
# EL AGUJERO: todas las guardas de este archivo miran en UNA sola direccion -- que el modelo no
# afirme cosas que no hizo. Hay una nota para "pediste un documento y todavia no lo generaste", y
# un rechazo para "decis que hiciste un informe pero no hay ninguno". No habia NADA para el caso
# contrario: ya lo hizo y sigue dando vueltas.
#
# MEDIDO el 2026-08-08 con un pedido real ("un documento sobre el ciclo del agua con una imagen"):
# el documento quedo listo y correcto en la iteracion 3, con la imagen adentro. El turno siguio
# hasta la 8 haciendo busquedas que no encontraban nada y listados de directorios, y la respuesta
# final que leyo el usuario fue un 'ls' -- ni una palabra del documento que ya existia. 299 segundos
# para algo que estaba hecho a los 60.
#
# Se cuentan las acciones REALES (los 12 puntos que ponen HAD_REAL_ACTION). Si el contador no se
# mueve, la iteracion no produjo nada: fue una vuelta perdida.
#   - A las 2 vueltas perdidas: se le avisa, con la lista de lo que ya consiguio.
#   - A las 4: se corta. El corte es un numero, no un pedido -- misma leccion que el tope de la
#     camara (ERR-133): una defensa que depende de que el modelo obedezca es una sugerencia.
# El contador se reinicia con cada accion nueva, asi que una tarea legitima de varios pasos
# ("hacete tres documentos") no se ve afectada: cada documento resetea la cuenta.
ACCIONES_N=0
ACCIONES_N_VUELTA_ANTERIOR=0
VUELTAS_SIN_PRODUCIR=0
CIERRE_FORZADO=0
# ¿Se genero un DOCUMENTO en este turno? Distinto de HAD_REAL_ACTION, que se conforma con
# cualquier accion real: hacia falta poder distinguir "hizo algo" de "hizo lo que dice que hizo".
HAD_DOC=0
# Cuantas veces se rechazo un 'done' por hablar de un documento que no existe. Se corta en 1:
# rechazar en bucle quema el presupuesto entero del turno y termina dejando al usuario sin nada.
DOC_RECHAZOS=0

# ADHERENCIA B2 (2026-08-04): ¿la tarea PIDE un documento?
#
# Las dos guardas de mas abajo son CORRECTIVAS: se activan cuando el modelo ya termino y afirma
# un documento que no existe. Sirven para que no mienta, pero el usuario igual se queda sin el archivo.
# El problema medido no era que mintiera, era que se iba por las ramas -- investigaba, generaba
# una imagen, resumia -- y nunca llegaba a 'gen doc'.
#
# Esto es preventivo: si el pedido es un documento y a mitad del turno todavia no hay ninguno, se
# le recuerda ANTES de que cierre, usando el mismo canal (CORRECTION_NOTE) que ya endereza otros
# desvios. Corregir a tiempo cuesta una nota; corregir tarde cuesta el turno entero.
#
# La deteccion vive en nv_pide_documento (engine/nv-lib.sh) para que sea PROBABLE con frases de
# verdad: aca adentro solo se podria testear con grep sobre este archivo, y eso da verde aunque la
# logica este mal.
NVA_DOC_PEDIDO=0
nv_pide_documento "$TASK" && NVA_DOC_PEDIDO=1
# Tope duro anti-loop (pedido del usuario, 2026-07-18, ver bug real: 'read Calculadora.exe' fallo
# 7+ veces porque SAME_TOOL_STREAK solo cuenta repeticiones CONSECUTIVAS -- se intercalaban
# otras herramientas (control click, delegate, run) entre medio, asi que nunca llegaba a 2
# seguidas y el aviso nunca se disparaba. Esto cuenta el mismo (herramienta+error EXACTO) en
# TODO el turno, sin importar si fue consecutivo, y corta el turno entero (sin gastar otra
# llamada al modelo) si se repite demasiado -- plata/tokens tirados en un error que ya se
# demostro que no se arregla solo.
declare -A FAIL_SIG_COUNT=()
FAIL_SIG_MAX=3
LOOP_DETECTADO=0
# Escalera de verificacion de codigo (pedido del usuario, 2026-07-18: cerrar la brecha de calidad
# de codigo con un harness real -- ver nv-verify.sh, que ya escala autor "code deep ultra" ante
# fallos de sandbox. Esto es lo mismo pero sobre el repo real de la tarea, no un snippet aislado
# en sandbox, y activado por 'exec' fallando en vez de por una escalera de autores separada).
CODE_ESCALA_ARR=(deep ultra)
CODE_ESCALA_IDX=0
EXEC_FAIL_STREAK=0
CODE_LANG_GUESS="general"
# Ultimo artefacto de codigo escrito en el turno: se verifica UNA vez, al cerrar (ver 'done').
VERIFY_PENDIENTE_REL=""
VERIFY_PENDIENTE_ABS=""
VERIFY_PENDIENTE_LANG=""
VERIFY_YA_HECHA=0
# Cuantos pasos tiene permitidos este turno. Se dice UNA vez, antes de empezar, para que la app
# pueda mostrar "paso 3 de 10" en vez de un "paso 3" suelto que no dice si falta mucho o nada
# (pedido del usuario, 2026-08-08). Va por stderr como todo lo demas que mira la interfaz, y en el
# mismo formato "[nv-agent]..." para que quien ya lee esas lineas no tenga que aprender otra cosa.
# Si alguien corre nv-agent.sh a mano, es una linea mas de contexto y nada se rompe.
echo "[nv-agent] PRESUPUESTO: $MAXIT" >&2

# --- AUTO-REPARTO DEL MODO COWORK (2026-08-14, pedido del usuario) ----------------------------------
#
# EL PROBLEMA MEDIDO: en el duelo contra CrewAI (eval/duelo-cowork-crewai/), Mentis corrio tres
# veces la misma tarea de tres partes independientes con 'delegate' y 'parallel' HABILITADAS y no
# uso ninguna de las dos: resolvio todo en fila. El paralelismo de CrewAI no lo decide el modelo,
# lo declara el programador -- por eso siempre reparte.
#
# POR QUE ESTO NO ES UN PARRAFO EN LA PERSONA DEL MODO: porque ya sabemos como termina. La persona
# de Cowork YA dice "cuando una tarea tenga partes independientes, repartilas en paralelo" y el
# modelo la leyo las tres veces. Una defensa escrita como instruccion es una sugerencia (ERR-133).
# Asi que reparte el MOTOR: se pide un plan, y si el plan tiene dos o mas partes independientes,
# se lanzan en paralelo sin preguntarle al modelo.
#
# LO QUE CUESTA: una llamada corta por turno de Cowork (rol 'extract', el mas rapido). Si el plan
# devuelve menos de dos partes, no se reparte nada y esa llamada fue el unico costo. Por eso entra
# medido contra el mismo duelo: si no baja el tiempo o baja el puntaje, se apaga.
#
# APAGADO: MENTIS_REPARTO_OFF=1. Se activa solo con -R (mentis-chat.sh lo pasa en modo Cowork).
_auto_reparto() {
  local plan roles_prompts n tmpd pi pids=() roles=() out=""
  plan="$(printf 'Tarea que hay que resolver:\n%s\n\nDividila en partes que se puedan hacer AL MISMO TIEMPO, sin que ninguna necesite el resultado de otra. Devolvé SOLO un array JSON, sin texto alrededor, con este formato:\n[{"role":"general","prompt":"…"},{"role":"general","prompt":"…"}]\n\nReglas: máximo 4 partes; cada "prompt" tiene que ser autosuficiente (quien lo reciba NO ve la tarea original ni lo que hacen los demás); "role" puede ser general, code, reason o extract. Si la tarea NO se puede partir en partes independientes, devolvé exactamente [].' "$TASK" \
    | timeout 90 bash "$NVDIR/ask-nvidia.sh" -r extract 2>/dev/null)" || return 1
  # Parseo tolerante: los modelos envuelven el JSON en markdown o lo explican antes. Se busca el
  # primer array del texto en vez de exigir una respuesta limpia.
  roles_prompts="$(printf '%s' "$plan" | python3 -c '
import json, sys, re, base64
t = sys.stdin.read()
m = re.search(r"\[.*\]", t, re.S)
if not m: sys.exit(0)
try: d = json.loads(m.group(0))
except Exception: sys.exit(0)
if not isinstance(d, list): sys.exit(0)
for item in d[:4]:
    if not isinstance(item, dict): continue
    r = item.get("role", "general")
    p = item.get("prompt", "")
    if not isinstance(r, str) or r not in ("general","code","reason","extract"): r = "general"
    if not isinstance(p, str) or not p.strip(): continue
    print(r + "\t" + base64.b64encode(p.encode("utf-8", "replace")).decode())
' 2>/dev/null)" || return 1
  n="$(printf '%s' "$roles_prompts" | grep -c. || true)"
  [ "${n:-0}" -ge 2 ] || return 1

  tmpd="$(mktemp -d)"; pi=0
  while IFS=$'\t' read -r _rol _p64; do
    [ -n "${_rol:-}" ] || continue
    roles[$pi]="$_rol"
    ( printf '%s' "$_p64" | base64 -d 2>/dev/null | timeout 180 bash "$NVDIR/ask-nvidia.sh" -r "$_rol" > "$tmpd/out-$pi.txt" 2>/dev/null ) &
    pids+=("$!")
    pi=$((pi+1))
  done <<< "$roles_prompts"
  for _pid in "${pids[@]}"; do wait "$_pid" 2>/dev/null || true; done

  for (( pi=0; pi<n; pi++ )); do
    out="$out
--- parte $((pi+1)) (${roles[$pi]:-general}) ---
$(cat "$tmpd/out-$pi.txt" 2>/dev/null || true)"
  done
  rm -rf "$tmpd"
  REPARTO_OBS="$(printf '%s' "$out" | _trunc)"
  REPARTO_N="$n"
  return 0
}

if [ "${REPARTO:-0}" = "1" ] && [ "${MENTIS_REPARTO_OFF:-0}" != "1" ]; then
  echo "[nv-agent] reparto automatico: pidiendo el plan" >&2
  if _auto_reparto; then
    echo "[nv-agent] reparto automatico: $REPARTO_N partes resueltas EN PARALELO antes de empezar" >&2
    # Entra al historial como una accion ya hecha, con una instruccion acotada: el material ya
    # esta, lo que falta es usarlo. Sin esta linea el modelo vuelve a generarlo todo de nuevo y
    # el reparto no habria servido para nada.
    HIST="$HIST
--- turno 0 (reparto automatico) ---
acción: {\"tool\":\"parallel\"}
observación:
$REPARTO_OBS

NOTA: estas $REPARTO_N partes ya se resolvieron en paralelo antes de empezar. NO las vuelvas a generar: usá este material tal cual.
OJO, LO MAS IMPORTANTE: este material NO está guardado en ningún archivo -- vive sólo acá, en esta conversación. Si la tarea pide archivos, los tenés que escribir vos con 'write', uno por uno, y recién ahí existen. Medido el 2026-08-14: con el material a la vista, el turno escribió UN archivo de tres y cerró diciendo que había hecho los tres.
"
  else
    echo "[nv-agent] reparto automatico: la tarea no se parte en partes independientes; sigo normal" >&2
  fi
fi

# --- TABLERO DE TAREAS (2026-08-15, pedido del usuario para el modo Cowork) -------------------------
#
# QUE ES: al arrancar el turno se le pide al modelo un plan corto -- 3 a 6 tareas en castellano, y
# para cada una, el archivo que deberia existir cuando esté cumplida. El plan sale por stderr como
# lineas "[nv-agent] PLAN: n|texto|archivo", que la app dibuja como una lista de puntos.
#
# LO QUE HACE QUE ESTO NO SEA UNA DECORACION: las tareas se tachan cuando el ARCHIVO APARECE, no
# cuando el modelo dice que las hizo. Es la misma regla que la guarda de archivos nombrados y la
# del gate de completitud: el tablero informa lo que se puede comprobar. Una tarea sin archivo
# asociado NO se tacha sola -- queda sin marcar, que es la verdad.
#
# NO BLOQUEA EL TURNO. La llamada al planificador corre en segundo plano y el loop arranca sin
# esperarla; el tablero aparece cuando llega. Si el modelo no contesta o contesta cualquier cosa,
# no hay tablero y el turno sigue igual. Esto es deliberado: el reparto automático se apagó el
# mismo día justamente por costar tiempo, y un tablero que retrase el trabajo no vale la pena.
#
# Se activa con -T (mentis-chat.sh lo pasa en los modos con "tablero": true). Apagado:
# MENTIS_TABLERO_OFF=1.
TABLERO_FILE=""
declare -A TABLERO_HECHO=()
if [ "${TABLERO:-0}" = "1" ] && [ "${MENTIS_TABLERO_OFF:-0}" != "1" ]; then
  TABLERO_FILE="$(mktemp)"
  (
    _tb_plan="$(printf 'Tarea del usuario:\n%s\n\nEscribí el plan en 3 a 6 pasos, en castellano, cada uno de menos de 60 caracteres y empezando con un verbo. Si un paso termina con un archivo concreto, poné su nombre; si no produce archivo, dejá "".\n\nDevolvé SOLO un array JSON, sin texto alrededor:\n[{"t":"Armar la lista de precios","archivo":"precios.csv"},{"t":"Revisar los números","archivo":""}]' "$TASK" \
      | timeout 60 bash "$NVDIR/ask-nvidia.sh" -r extract 2>/dev/null)" || exit 0
    printf '%s' "$_tb_plan" | python3 -c '
import json, sys, re
t = sys.stdin.read()
m = re.search(r"\[.*\]", t, re.S)
if not m: sys.exit(0)
try: d = json.loads(m.group(0))
except Exception: sys.exit(0)
if not isinstance(d, list): sys.exit(0)
n = 0
for it in d[:6]:
    if not isinstance(it, dict): continue
    texto = str(it.get("t", "")).strip().replace("|", " ")[:80]
    arch = str(it.get("archivo", "") or "").strip().replace("|", " ")[:80]
    if not texto: continue
    n += 1
    print("%d\t%s\t%s" % (n, texto, arch))
' > "$TABLERO_FILE.tmp" 2>/dev/null || exit 0
    # mv atomico: el loop lee este archivo mientras esto corre, y leer un plan a medio escribir
    # mostraria un tablero incompleto que despues cambia solo.
    if [ -s "$TABLERO_FILE.tmp" ]; then
      mv -f "$TABLERO_FILE.tmp" "$TABLERO_FILE"
      while IFS=$'\t' read -r _n _txt _arch; do
        [ -n "${_n:-}" ] && echo "[nv-agent] PLAN: $_n|$_txt|${_arch:-}" >&2
      done < "$TABLERO_FILE"
    else
      rm -f "$TABLERO_FILE.tmp"
    fi
  ) &
fi

# _tablero_revisar: marca las tareas cuyo archivo YA existe. Se llama una vez por iteración.
_tablero_revisar() {
  [ -n "${TABLERO_FILE:-}" ] && [ -s "$TABLERO_FILE" ] || return 0
  local n txt arch
  while IFS=$'\t' read -r n txt arch; do
    [ -n "${n:-}" ] || continue
    [ -n "${arch// }" ] || continue
    [ -n "${TABLERO_HECHO[$n]:-}" ] && continue
    if [ -e "$ROOT/$arch" ] || [ -n "$(find "$ROOT" -maxdepth 3 -name "$arch" -print -quit 2>/dev/null)" ] \
       || [ -n "$(find "$MENTIS_CREATIONS_DIR" -maxdepth 2 -name "$arch" -print -quit 2>/dev/null)" ]; then
      TABLERO_HECHO[$n]=1
      echo "[nv-agent] PLAN-HECHO: $n" >&2
    fi
  done < "$TABLERO_FILE"
}

for (( it=1; it<=MAXIT; it++ )); do
  CORRECTION_NOTE=""
  # ¿La vuelta anterior produjo algo? Se compara el contador de acciones reales contra el valor
  # que tenía al empezar esa vuelta. Si no se movió, fue una vuelta perdida.
  # Sólo cuenta como "perdida" si YA hay algo logrado: las vueltas de investigación al principio
  # del turno son trabajo legítimo, no dar vueltas.
  if [ "$it" -gt 1 ] && [ "$HAD_REAL_ACTION" = "1" ]; then
    if [ "$ACCIONES_N" -eq "$ACCIONES_N_VUELTA_ANTERIOR" ]; then
      VUELTAS_SIN_PRODUCIR=$((VUELTAS_SIN_PRODUCIR+1))
    else
      VUELTAS_SIN_PRODUCIR=0
    fi
  fi
  ACCIONES_N_VUELTA_ANTERIOR="$ACCIONES_N"

  # A las 4 vueltas perdidas se corta. No se le pide: se le saca el teclado. El turno pasa a la
  # respuesta final con lo que ya hay, que es justamente lo que el modelo no estaba contando.
  if [ "$VUELTAS_SIN_PRODUCIR" -ge 4 ]; then
    echo "[nv-agent] iter $it: CORTADO -- $VUELTAS_SIN_PRODUCIR vueltas sin producir nada despues de haber logrado el objetivo" >&2
    CIERRE_FORZADO=1
    break
  fi
  # A las 2, se le avisa. La nota nombra lo que ya consiguió, porque el problema medido no fue que
  # el modelo quisiera seguir: fue que se olvidó de que ya lo había hecho.
  if [ "$VUELTAS_SIN_PRODUCIR" -ge 2 ]; then
    _logrado="$ACCIONES_N acción(es) completada(s)"
    [ "${HAD_DOC:-0}" = "1" ] && _logrado="$_logrado, incluido un documento ya generado y guardado"
    CORRECTION_NOTE="$CORRECTION_NOTE

NOTA IMPORTANTE (ya cumpliste): en este turno YA hay $_logrado, y las últimas $VUELTAS_SIN_PRODUCIR vueltas no produjeron nada nuevo. Si lo que se pedía ya está hecho, cerrá AHORA con 'done' y contá en la respuesta QUÉ generaste y DÓNDE quedó -- no un listado de archivos ni un resumen de lo que buscaste. Si de verdad falta algo concreto, hacelo en este paso; si no, cerrá."
  fi
  if [ "$SAME_TOOL_STREAK" -ge 2 ]; then
    CORRECTION_NOTE="$CORRECTION_NOTE

NOTA IMPORTANTE (protocolo de error): ya intentaste la herramienta '$PREV_TOOL' sin éxito $((SAME_TOOL_STREAK+1)) veces seguidas. No la repitas de nuevo -- cambiá de estrategia por completo, o cerrá con 'done' explicando honestamente qué lograste y qué no."
    CU_ESCALATED=1
  fi
  if [ "$DELEGATE_LIKE_COUNT" -ge 2 ]; then
    CORRECTION_NOTE="$CORRECTION_NOTE

NOTA IMPORTANTE (protocolo de error): ya consultaste a otro cerebro con 'delegate'/'parallel' $DELEGATE_LIKE_COUNT veces en esta tarea. Si ya tenés una respuesta usable de alguna de esas consultas, USALA en tu 'done' -- no vuelvas a pedir lo mismo de nuevo."
  fi
  # Adherencia B2: se pidio un documento y a esta altura del turno todavia no hay ninguno. Va
  # desde la iteracion 3 -- antes seria interrumpir una investigacion legitima, y despues llega
  # tarde. El recordatorio trae la sintaxis exacta: la falla no era de intencion sino de que el
  # modelo terminaba el turno sin haber emitido nunca la llamada.
  if [ "$NVA_DOC_PEDIDO" = "1" ] && [ "${HAD_DOC:-0}" != "1" ] && [ "$it" -ge 3 ]; then
    CORRECTION_NOTE="$CORRECTION_NOTE

NOTA IMPORTANTE (lo que se pidió): la tarea pide un DOCUMENTO y en este turno todavía no generaste ninguno. Investigar, resumir o generar una imagen NO cuenta: el archivo no existe hasta que hagas la llamada. Si ya tenés el contenido, generalo AHORA con {\"tool\":\"gen\",\"action\":\"doc\",\"format\":\"docx\",\"content\":\"...\"} y recién después cerrá con 'done'. Para meterle imágenes, poné dentro del content una línea '!img <qué buscar>' (foto libre de Wikimedia Commons, con atribución) o '!imgfile <ruta>|<epígrafe>'."
  fi
  # Tareas en curso (ver tool 'task' + mentis-tasks.sh): solo se muestra si YA existe un
  # archivo.mentis-tasks.json en este ROOT -- si nunca se creo ninguna tarea, no se gasta el
  # subproceso ni se ensucia el prompt con una seccion vacia.
  TASKS_SECTION=""
  if [ -f "$ROOT/.mentis-tasks.json" ]; then
    TASKS_SECTION="

TAREAS EN CURSO (este trabajo de varios pasos ya tiene una lista -- actualizala con el tool 'task' a medida que avanzás, no la ignores):
$(bash "$MENTIS_ROOT/mentis-tasks.sh" list "$ROOT" 2>/dev/null)"
  fi
  NVA_PROMPT="$PROTOCOL

TAREA: $TASK$TASKS_SECTION

HISTORIAL (acciones previas y sus observaciones):
${HIST:-(vacío — es tu primer turno)}
${CORRECTION_NOTE}

Respondé con el próximo objeto JSON de acción."

  # ITER_ROLE (doble cerebro, ver arriba): 'fast' para navegar mientras ALLOW_CONTROL este
  # activo y no haya escalado -- iteracion 1 siempre usa el cerebro pedido por el usuario (planea
  # antes de tocar nada).
  ITER_ROLE="$ROLE"
  if [ "$ALLOW_CONTROL" = "1" ] && [ "$CU_ESCALATED" != "1" ] && [ "$it" -gt 1 ]; then
    ITER_ROLE="fast"
  fi
  # Escalera de verificacion de codigo (ver junto al tool 'exec'): pisa el brazo rapido de
  # computer-use si ambas estuvieran activas -- escalar a un cerebro mas capaz siempre gana
  # sobre navegar rapido.
  if [ "$CODE_ESCALA_IDX" -gt 0 ]; then
    ITER_ROLE="${CODE_ESCALA_ARR[$((CODE_ESCALA_IDX-1))]}"
  fi

  # --- llamar al modelo (ask-nvidia ya redacta y hace fallback entre modelos) ---
  # El stderr YA NO se tira a /dev/null (2026-07-27). Ese descarte escondió durante horas un
  # UnicodeDecodeError del guard de privacidad: Mentis contestaba "el modelo no devolvió JSON
  # válido" cuando en realidad el modelo nunca había sido consultado. Ahora se guarda, y si la
  # respuesta viene vacía se muestra el motivo real en el progreso del turno.
  NVA_ERRTMP="$(mktemp 2>/dev/null || echo "/tmp/nva-err-$$")"
  # STREAMING VISIBLE (2026-08-06). El motor emite la respuesta final por chunks y nv_stream.py la
  # va sacando des-escapada en lineas "NVANSWER <trozo>" (ver NV_ANSWER_STDERR). Pero ese stderr
  # cae en un ARCHIVO que recien se lee cuando la llamada TERMINO -- o sea que el streaming
  # existia y llegaba muerto. Por eso la app mostraba la respuesta de golpe.
  #
  # El awk hace las dos cosas de una: guarda TODO el stderr en el archivo (que es lo que se usa
  # para diagnosticar una respuesta vacia) y ademas deja pasar en vivo SOLO las lineas NVANSWER al
  # stderr real, que mentis-chat.sh ya reenvia a la UI linea por linea. Los avisos internos
  # ("usando fallback") siguen sin ensuciar el chat.
  #
  # Va CONDICIONADO porque cuesta un proceso por llamada (~26-75 ms medidos en esta maquina) y el
  # camino de produccion no tiene por que pagarlo si nadie esta mirando la pantalla. Con la
  # variable apagada, la linea es byte por byte la de antes.
  if [ "${NV_ANSWER_STDERR:-0}" = "1" ]; then
    if RESP="$(printf '%s' "$NVA_PROMPT" | bash "$NVDIR/ask-nvidia.sh" -r "${IMG_FLAGS[@]}" "$ITER_ROLE" \
               2> >(awk -v f="$NVA_ERRTMP" '{ print >> f; fflush(f) } /^NVANSWER /{ print; fflush() }' >&2))"; then :; else RESP=""; fi
  else
    if RESP="$(printf '%s' "$NVA_PROMPT" | bash "$NVDIR/ask-nvidia.sh" -r "${IMG_FLAGS[@]}" "$ITER_ROLE" 2>"$NVA_ERRTMP")"; then :; else RESP=""; fi
  fi
  if [ -z "$RESP" ] && [ -s "$NVA_ERRTMP" ]; then
    echo "[nv-agent] iter $it: la consulta al modelo falló -> $(tr '\n' ' ' < "$NVA_ERRTMP" | cut -c1-300)" >&2
  fi
  rm -f "$NVA_ERRTMP"

  # --- extraer acción; 1 reintento correctivo si no hay JSON válido ---
  if ACT="$(_extract_action "$RESP" 2>/dev/null)"; then :; else
    CORR="Tu respuesta anterior no fue un objeto JSON válido con \"tool\". Respondé SOLO el JSON de acción, sin texto ni markdown."
    if RESP="$(printf '%s\n\n%s' "$NVA_PROMPT" "$CORR" | bash "$NVDIR/ask-nvidia.sh" -r "${IMG_FLAGS[@]}" "$ITER_ROLE" 2>/dev/null)"; then :; else RESP=""; fi
    if ACT="$(_extract_action "$RESP" 2>/dev/null)"; then :; else
      echo "[nv-agent] iter $it: el modelo no devolvió JSON válido dos veces -> aborto honesto" >&2
      STATUS="nojson"; break
    fi
  fi

  # ACT trae TOOL=... y *_B64=...  -> a variables
  TOOL=""; PATH_B64=""; QUERY_B64=""; CODE_B64=""; CONTENT_B64=""; ANSWER_B64=""
  OLD_B64=""; NEW_B64=""
  ACTION_B64=""; URL_B64=""; TARGET_B64=""; VALUE_B64=""
  SERVER_B64=""; NAME_B64=""; ARGS_B64=""; PROMPT_B64=""; FORMAT_B64=""; X_B64=""; Y_B64=""; PROVIDER_B64=""
  while IFS= read -r ln; do
    ln="${ln%$'\r'}"   # python de la Store emite \r\n -> sin esto TOOL queda "search\r"
    case "$ln" in
      TOOL=*)      TOOL="${ln#TOOL=}" ;;
      PATH_B64=*)  PATH_B64="${ln#PATH_B64=}" ;;
      QUERY_B64=*) QUERY_B64="${ln#QUERY_B64=}" ;;
      CODE_B64=*)  CODE_B64="${ln#CODE_B64=}" ;;
      CONTENT_B64=*) CONTENT_B64="${ln#CONTENT_B64=}" ;;
      OLD_B64=*)   OLD_B64="${ln#OLD_B64=}" ;;
      NEW_B64=*)   NEW_B64="${ln#NEW_B64=}" ;;
      ANSWER_B64=*) ANSWER_B64="${ln#ANSWER_B64=}" ;;
      ACTION_B64=*) ACTION_B64="${ln#ACTION_B64=}" ;;
      URL_B64=*)   URL_B64="${ln#URL_B64=}" ;;
      TARGET_B64=*) TARGET_B64="${ln#TARGET_B64=}" ;;
      VALUE_B64=*) VALUE_B64="${ln#VALUE_B64=}" ;;
      SERVER_B64=*) SERVER_B64="${ln#SERVER_B64=}" ;;
      NAME_B64=*)  NAME_B64="${ln#NAME_B64=}" ;;
      ARGS_B64=*)  ARGS_B64="${ln#ARGS_B64=}" ;;
      PROMPT_B64=*) PROMPT_B64="${ln#PROMPT_B64=}" ;;
      FORMAT_B64=*) FORMAT_B64="${ln#FORMAT_B64=}" ;;
      X_B64=*)     X_B64="${ln#X_B64=}" ;;
      Y_B64=*)     Y_B64="${ln#Y_B64=}" ;;
      PROVIDER_B64=*) PROVIDER_B64="${ln#PROVIDER_B64=}" ;;
    esac
  done <<< "$ACT"

  _dispatch_tool "$it"

  # Escalada del doble cerebro (ver arriba): un 'control type' con texto largo es redaccion
  # real (el usuario pidio explicitamente que ESO lo resuelva el cerebro avanzado, no el rapido) --
  # de aca en mas, esta tarea se queda en el cerebro avanzado el resto del turno.
  if [ "$ALLOW_CONTROL" = "1" ] && [ "$TOOL" = "control" ] && [ "${CACTION:-}" = "type" ] && [ "${#CVALUE}" -gt 40 ] && [ "$CU_ESCALATED" != "1" ]; then
    CU_ESCALATED=1
    echo "[nv-agent] iter $it: escalado a cerebro avanzado (texto compuesto detectado, ${#CVALUE} caracteres)" >&2
  fi

  # Guardia anti-alucinacion de exito (bug real 2026-07-12, protocolo de error): un 'done' que
  # AFIRMA haber creado/guardado/enviado algo (archivo, doc, correo) sin que haya habido NINGUNA
  # accion real exitosa (write/mcp-call/gen) en todo el turno es una respuesta inventada, no una
  # verificada -- viola la regla del propio prompt de Mentis ("nunca inventes un resultado que
  # no verificaste"). Caso real observado: el modelo dijo "Creé el Google Doc" tras solo hacer
  # mcp list + 3 browse (todas bloqueadas por CAPTCHA) -- nunca llamó a mcp call. Si se detecta
  # el patron, se rechaza el 'done' y se le devuelve la observacion como error para que lo
  # corrija, en vez de dejarlo pasar como si fuera cierto.
  # OJO (bug real encontrado al probar esto, 2026-07-12): un bracket-expression tipo "[eé]" NO
  # matchea de forma confiable letras acentuadas UTF-8 en este entorno (grep las trata byte a
  # byte) -- y "\b" pegado justo despues de un caracter multibyte tampoco. Por eso acá van
  # alternancias explícitas "(cree|creé)" en vez de "cre[eé]", y sin "\b" tras acentos.
  if [ "$STATUS" = "done" ] && [ "$HAD_REAL_ACTION" != "1" ] && printf '%s' "$FINAL" | grep -qiE "(cree|creé) (el|la|un|una)|archivo creado|documento creado|se creo\b|se creó|(guarde|guardé) (el|la)|(envie|envié) el correo|(envie|envié) el mail|(mande|mandé) el (correo|mail)|ya (esta|está) (creado|guardado|listo)|subi el archivo|subí el archivo"; then
    echo "[nv-agent] iter $it: done RECHAZADO -- afirma un resultado sin ninguna accion real exitosa en el turno" >&2
    HIST="$HIST
--- turno $it ---
acción: {\"tool\":\"done\"}
observación:
ERROR: tu respuesta anterior decía que creaste, guardaste o enviaste algo, pero no hay ningún tool call exitoso (write/mcp/gen) en todo este turno que lo respalde. Si de verdad necesitás crear eso, hacé la llamada real correspondiente ANTES de responder con 'done'. Si no podés hacerlo (por ejemplo, la tool falló), sé honesto en tu respuesta final y no afirmes que ya está hecho.
"
    STATUS="budget"; FINAL=""
  fi

  # ¿ESTO QUE VA A LEER USUARIO ES MI PROPIO TEXTO? (2026-08-15, bug reportado con captura).
  #
  # el usuario pidio un brazalete con modulos intercambiables y lo que leyo en pantalla fue esto:
  #   "No puedo generar un documento sin contenido. Si ya tenes el contenido, generalo AHORA con
  #    "tool":"gen","action":"doc"... y recien despues cerra con 'done'."
  # Es la OBSERVACION que la guarda de documento le inyecto AL MODELO. El modelo la devolvio como
  # respuesta final y la guarda de "segunda vez" la envolvio en una frase amable y se la mostro.
  #
  # POR QUE VA ACA ARRIBA DE TODO: hay 102 puntos que le inyectan texto al modelo y tres guardas
  # mas abajo que arman la respuesta concatenando lo que devolvio. Preguntar una sola vez, en la
  # salida, tapa las combinaciones de las dos listas; taparlo en cada guarda seria perseguirlas.
  #
  # LA PRIMERA VEZ SE RECHAZA Y SE EXPLICA. No se corrige en silencio: el modelo tiene una
  # respuesta adentro (el trabajo esta hecho) y lo unico que fallo fue que copio el andamiaje en
  # vez de escribirla. Vale un paso pedirsela bien.
  # LA SEGUNDA NO SE INSISTE -- rechazar en bucle quema el turno entero y deja al usuario sin nada,
  # que es la leccion ya escrita en las guardas de documento y del gate. Se cierra con un mensaje
  # honesto, y el eco NO se adjunta: mostrarlo era exactamente el bug.
  # DOS CAPAS, EN ESTE ORDEN (la segunda se sumo el 2026-08-16):
  #   1. nv_eco_procedencia: ¿esta respuesta salio del registro de lo que YO le dije este turno?
  #      No envejece -- cubre las guardas que se escriban manana sin tocar ninguna lista.
  #   2. nv_eco_interno: los marcadores. Cuesta nada y ataja el caso donde no hay registro (un
  #      llamador que no lo activo) o donde el eco viene de otro turno.
  # La primera esta medida contra las 75 respuestas reales del usuario: 0 falsos positivos.
  if [ "$STATUS" = "done" ] && { nv_eco_procedencia "$FINAL" || nv_eco_interno "$FINAL"; }; then
    if [ "${ECO_RECHAZOS:-0}" -lt 1 ]; then
      ECO_RECHAZOS=1
      echo "[nv-agent] iter $it: done RECHAZADO -- la respuesta era eco de mis propias instrucciones" >&2
      HIST="$HIST
--- turno $it ---
acción: {\"tool\":\"done\"}
observación:
ERROR: lo que pusiste en 'answer' no es una respuesta para el usuario: es el texto que YO te mandé a vos (instrucciones internas del sistema, el formato JSON de una herramienta, o una orden de cerrar con done). el usuario no tiene que leer nada de eso -- para él, ese texto no significa nada. Escribí con TUS palabras qué hiciste y qué no, en español y dirigido a él. Si no llegaste a hacer lo que pedía, decíselo derecho: es una respuesta perfectamente válida.
"
      STATUS="budget"; FINAL=""
    else
      echo "[nv-agent] iter $it: segundo eco de instrucciones internas -- se reemplaza el texto" >&2
      FINAL="No llegué a resolver esto en este turno y no quiero devolverte un texto que no te sirve. Contame de nuevo qué necesitás y lo encaro con otro enfoque."
    fi
  fi

  # GUARDA POR TIPO DE ARTEFACTO (2026-08-03). La de arriba pregunta si hubo ALGUNA accion real
  # en el turno; alcanza para "cree el archivo" dicho sin haber hecho nada. Pero se le escapa un
  # caso peor y mas creible: hacer UNA cosa y afirmar OTRA.
  #
  # Visto tres veces seguidas probando B2: a "hacme un documento word con una foto", Mentis
  # generaba la imagen -- accion real, exitosa, HAD_REAL_ACTION=1; ACCIONES_N=$((ACCIONES_N+1)) -- y despues cerraba el turno
  # con "El documento tiene tres secciones... la foto va integrada en el medio del texto". No
  # habia ningun documento. La guarda vieja lo dejaba pasar porque la imagen contaba como accion.
  #
  # Aca se exige que la accion sea DEL TIPO que se afirma: si dice que hizo un documento, tuvo
  # que haber un 'gen doc' exitoso en este turno.
  if [ "$STATUS" = "done" ] && [ "${HAD_DOC:-0}" != "1" ] && [ "${DOC_RECHAZOS:-0}" -ge 1 ] \
     && printf '%s' "$FINAL" | grep -qiE "(el|un|este) (documento|informe|word|pdf|presentacion|presentación|planilla)|(documento|informe) (word|pdf|adjunto)|te (arme|armé|hice) (el|un) (documento|informe)"; then
    # SEGUNDA VEZ: no se rechaza de nuevo. Rechazar en bucle quema el presupuesto entero del turno
    # y termina dejando al usuario sin nada -- medido: un turno se comio 10 minutos asi. Se deja pasar
    # el turno pero se CORRIGE la afirmacion, que es lo unico inaceptable. Mejor una respuesta que
    # admite el limite que una que promete un archivo inexistente.
    echo "[nv-agent] iter $it: segunda afirmacion de documento sin documento -- se corrige el texto" >&2
    # El "esto es lo que tenia preparado" solo se adjunta si de verdad es contenido. Cuando el
    # modelo devolvia eco de mis instrucciones, esta linea se lo mostraba al usuario envuelto en una
    # frase amable -- ese fue el bug de la captura del 2026-08-15.
    if nv_eco_interno "$FINAL"; then
      FINAL="No llegué a generar el documento en este turno, así que todavía no existe ningún archivo. Tampoco alcancé a dejar el contenido escrito. Si querés, lo encaro de nuevo con el tema más acotado."
    else
      FINAL="No llegué a generar el documento en este turno, así que todavía no existe ningún archivo. Esto es lo que tenía preparado para adentro:

$FINAL"
    fi
  elif [ "$STATUS" = "done" ] && [ "${HAD_DOC:-0}" != "1" ] \
     && printf '%s' "$FINAL" | grep -qiE "(el|un|este) (documento|informe|word|pdf|presentacion|presentación|planilla)|(documento|informe) (word|pdf|adjunto)|te (arme|armé|hice) (el|un) (documento|informe)"; then
    DOC_RECHAZOS=$(( ${DOC_RECHAZOS:-0} + 1 ))
    echo "[nv-agent] iter $it: done RECHAZADO -- habla de un documento y no se genero ninguno" >&2
    HIST="$HIST
--- turno $it ---
acción: {\"tool\":\"done\"}
observación:
ERROR: tu respuesta habla de un documento (informe/word/pdf/presentación) pero en este turno NO generaste ninguno: no hubo ningún 'gen' con kind=doc exitoso. Generar una imagen no es generar el documento. Hacé el documento de verdad con {\"tool\":\"gen\",\"action\":\"doc\",\"format\":\"docx\",\"content\":\"...\"} -- y si querés la foto adentro, poné una línea '!img <que buscar>' o '!imgfile <ruta>|<epígrafe>' en el content. Después terminá.
"
    STATUS="budget"; FINAL=""
  fi

  # GATE DE COMPLETITUD (2026-08-14, idea 2 de docs/godmode-que-sirve.md).
  #
  # Las dos guardas de arriba preguntan si el ARTEFACTO existe ("decis que creaste un documento:
  # ¿lo creaste?"). Esta pregunta otra cosa, que es la familia de errores mas frecuente de la
  # bitacora: el artefacto existe, pero nadie lo probo y el turno igual dice que funciona.
  # ERR-141 y ERR-144 son eso -- una herramienta informando un resultado que no midio.
  #
  # LA REGLA, UNA SOLA: si la respuesta final afirma que algo funciona / anda / pasa los tests /
  # quedo verificado, tiene que haber en ESTE turno una prueba fresca (EVIDENCIA_N > 0).
  #
  # LAS DOS CONDICIONES QUE LA ACOTAN (esto salio de medir, no de suponer -- ver
  # eval/gate-completitud/medir.sh sobre las 74 respuestas reales del historial del usuario):
  #   a) El turno tiene que haber TOCADO algo (write o intento de exec). Sin esta condicion el
  #      gate se metia en conversaciones donde "funciona" es descriptivo y no una afirmacion de
  #      completitud -- "el Enter funciona correctamente", "la webcam funciona". Son 5 de las 74
  #      y ninguna escribio un archivo: con la condicion (a), el gate toca 0 de 74. La palabra
  #      "funciona" no es el problema; decirla despues de escribir codigo sin correrlo lo es.
  #   b) A la SEGUNDA no se rechaza de nuevo. Rechazar en bucle quema el presupuesto entero y
  #      deja al usuario sin respuesta (medido en la guarda de documento: un turno se comio 10
  #      minutos asi). La segunda vez pasa, pero con la afirmacion corregida.
  if [ "${MENTIS_GATE_OFF:-0}" != "1" ] && [ "$STATUS" = "done" ] && [ "${EVIDENCIA_N:-0}" -eq 0 ] \
     && [ $(( WRITE_CNT + ${EXEC_CNT:-0} )) -gt 0 ] && nv_gate_afirma_listo "$FINAL"; then
    # Se corrige el texto -- en vez de rechazar -- en DOS casos: si ya se rechazo una vez, y si
    # esta es la ultima iteracion. Lo segundo importa tanto como lo primero: rechazar en la ultima
    # vuelta deja el turno sin respuesta final, y el usuario termina recibiendo el "reporte parcial
    # honesto" con el historial crudo en vez de la respuesta que el modelo ya tenia escrita.
    # Prefiero una respuesta con la advertencia adelante que ninguna respuesta.
    if [ "${GATE_RECHAZOS:-0}" -ge 1 ] || [ "$it" -ge "$MAXIT" ]; then
      echo "[nv-agent] iter $it: afirmacion de 'funciona' sin prueba (sin margen para pedirla) -- se corrige el texto" >&2
      FINAL="$(nv_gate_texto_corregido "$FINAL")"
    else
      GATE_RECHAZOS=$(( ${GATE_RECHAZOS:-0} + 1 ))
      echo "[nv-agent] iter $it: done RECHAZADO -- afirma que funciona y no hay prueba fresca en el turno" >&2
      HIST="$HIST
--- turno $it ---
acción: {\"tool\":\"done\"}
observación:
$(nv_gate_observacion_rechazo)
"
      STATUS="budget"; FINAL=""
    fi
  fi

  # ¿LOS ARCHIVOS QUE NOMBRA EXISTEN? (2026-08-14, encontrado midiendo el reparto)
  #
  # Un turno cerró así: "Se generaron los tres archivos requeridos: mercado.md, competencia.md y
  # plan90.md, cumpliendo con los requisitos especificados de estructura y longitud". Existía UNO.
  # Las tres guardas de arriba lo dejaron pasar y cada una por su motivo: la de acción real vio un
  # 'write' exitoso, la de documento sólo mira las palabras documento/informe/pdf, y el gate de
  # completitud busca "funciona/probado" -- "se generaron" no es ninguna de las tres.
  #
  # POR QUE ESTA GUARDA ES DISTINTA (y mejor) QUE LAS OTRAS: no busca frases. El motor sabe qué
  # archivos hay. Se toman los nombres de archivo que la respuesta menciona y se pregunta si
  # existen. Es una respuesta objetiva -- no depende de cómo esté redactada la afirmación, que es
  # justo donde se escapan las otras tres.
  #
  # Se busca en la raíz de trabajo, en sus subcarpetas y en la carpeta de creaciones (ahí van los
  # documentos de 'gen', que no viven en la raíz). Apagado: MENTIS_ARCHIVOS_OFF=1.
  if [ "${MENTIS_ARCHIVOS_OFF:-0}" != "1" ] && [ "$STATUS" = "done" ] && [ "${ALLOW_WRITE:-0}" = "1" ]; then
    ARCH_FALTAN=""
    for _a in $(printf '%s' "$FINAL" | grep -oE '[A-Za-z0-9_-]+\.(md|csv|txt|py|js|json|html|css|sh|docx|pdf|xlsx|pptx)' | sort -u); do
      [ -e "$ROOT/$_a" ] && continue
      [ -n "$(find "$ROOT" -maxdepth 3 -name "$_a" -print -quit 2>/dev/null)" ] && continue
      [ -n "$(find "$MENTIS_CREATIONS_DIR" -maxdepth 3 -name "$_a" -print -quit 2>/dev/null)" ] && continue
      ARCH_FALTAN="$ARCH_FALTAN $_a"
    done
    if [ -n "${ARCH_FALTAN// }" ]; then
      if [ "${ARCH_RECHAZOS:-0}" -ge 1 ] || [ "$it" -ge "$MAXIT" ]; then
        # Igual que las otras: a la segunda no se rechaza de nuevo, se corrige. Pero acá la
        # corrección puede ser EXACTA, porque sabemos cuáles faltan.
        echo "[nv-agent] iter $it: sigue nombrando archivos inexistentes ($ARCH_FALTAN) -- se corrige el texto" >&2
        FINAL="Ojo: de lo que sigue, estos archivos NO existen —no llegué a crearlos—:$ARCH_FALTAN

$FINAL"
      else
        ARCH_RECHAZOS=$(( ${ARCH_RECHAZOS:-0} + 1 ))
        echo "[nv-agent] iter $it: done RECHAZADO -- nombra archivos que no existen:$ARCH_FALTAN" >&2
        HIST="$HIST
--- turno $it ---
acción: {\"tool\":\"done\"}
observación:
ERROR: tu respuesta nombra estos archivos, y NO existen:$ARCH_FALTAN

No alcanza con haber preparado el contenido: mientras no lo escribas con {\"tool\":\"write\",\"path\":\"...\",\"content\":\"...\"}, el archivo no existe y quien lo busque no lo va a encontrar. Escribí ahora los que falten, uno por uno, y recién después terminá. Si alguno no lo podés hacer, decilo en la respuesta final en vez de darlo por hecho.
"
        STATUS="budget"; FINAL=""
      fi
    fi
  fi

  if [ "$STATUS" = "done" ]; then break; fi

  # Previsualizacion en vivo para la app Electron (bug real 2026-07-13): el panel de
  # previsualizacion solo podia mostrar contenido para read/write (podia releer el archivo del
  # disco) -- para browse/mcp/gen/screen/control/delegate/parallel el resultado real vivia y
  # moria DENTRO de este proceso, nunca salia hacia la app, asi que el usuario solo veia la etiqueta
  # de la accion sin nada mas. Se manda una linea aplanada (sin saltos de linea, la app
  # reenvia stderr linea por linea) con la observacion real de esta accion.
  # El tablero se revisa una vez por vuelta: es un par de stat(), no cuesta nada.
  _tablero_revisar
  PREVIEW_FLAT="$(printf '%s' "$OBS" | tr '\n' ' ' | head -c 800)"
  echo "[nv-agent] PREVIEW: $PREVIEW_FLAT" >&2

  # actualizar contadores del protocolo de error (ver arriba)
  if [ "$TOOL" = "$PREV_TOOL" ] && { [[ "$OBS" == ERROR:* ]] || [[ "$OBS" == *"[AVISO:"* ]]; }; then
    SAME_TOOL_STREAK=$((SAME_TOOL_STREAK+1))
  else
    SAME_TOOL_STREAK=0
  fi
  PREV_TOOL="$TOOL"
  if [ "$TOOL" = "delegate" ] || [ "$TOOL" = "parallel" ]; then
    DELEGATE_LIKE_COUNT=$((DELEGATE_LIKE_COUNT+1))
  fi
  if [[ "$OBS" == ERROR:* ]]; then
    FAIL_SIG_KEY="$TOOL|${OBS:0:200}"
    FAIL_SIG_COUNT["$FAIL_SIG_KEY"]=$(( ${FAIL_SIG_COUNT["$FAIL_SIG_KEY"]:-0} + 1 ))
    if [ "${FAIL_SIG_COUNT["$FAIL_SIG_KEY"]}" -ge "$FAIL_SIG_MAX" ]; then
      LOOP_DETECTADO=1
      echo "[nv-agent] iter $it: LOOP DETECTADO -- '$TOOL' repitió el mismo error $FAIL_SIG_MAX veces (no consecutivas). Corto el turno para no seguir gastando." >&2
    fi
  fi

  # BUCLE DE ACIERTOS (2026-08-12). El detector de arriba solo mira ERRORES repetidos, asi que un
  # acierto repetido identico no lo ve NADIE: en el modo Study el modelo leyo el MISMO archivo 23
  # veces seguidas -- cada 'read' devolvia exito -- hasta agotar el presupuesto y terminar sin
  # responder. Para el usuario se ve igual que un cuelgue, y es peor que un error: no hay ningun
  # mensaje de falla en toda la traza.
  #
  # No corta el turno: le devuelve el contenido UNA vez mas con un empujon a contestar. Cortar
  # castigaria al modelo por una accion que estuvo bien -- el problema no es que lea, es que no
  # se da cuenta de que ya lo tiene.
  # YA LO ESCRIBISTE VOS (2026-08-15, sale del duelo contra Goose).
  #
  # EL DATO: con el mismo cerebro y la misma tarea, Goose tardaba 85 segundos y Mentis 159. Las
  # trazas lo explicaban solas -- Goose: write, write, write, shell, listo. Mentis: los cuatro
  # write y despues LEER cada archivo, uno por uno. Cada relectura es una llamada entera al
  # modelo: ahi estaban los 70 segundos.
  #
  # NO LO VEIA NINGUNA GUARDA: el detector de bucles mira la MISMA accion repetida, y aca cada
  # lectura es de un archivo distinto y ninguna se repite.
  #
  # NO SE BLOQUEA LA LECTURA: el contenido se devuelve igual, con una linea adelante. Bloquear
  # seria negarle algo que a veces necesita; lo que le falta es darse cuenta de que ya lo tiene.
  # Y si el archivo cambio desde que lo escribio -- por ejemplo, porque un comando lo modifico --
  # la huella no coincide y no se dice nada: releer eso es exactamente lo correcto.
  # APAGADA POR DEFECTO DESDE EL 2026-08-15. Se midio (eval/relectura/VEREDICTO.md, 3 corridas
  # prendida contra 3 apagada, alternadas, mismo modelo y mismo juez) y NO gana:
  #   - No evita la relectura: en las dos corridas donde se activo, el modelo leyo igual 4
  #     archivos. Recibe el aviso y lee lo mismo de todas formas.
  #   - Mediana de 177 s prendida contra 150 s apagada. Si algo, va para el otro lado.
  #   - La calidad no se mueve: 32/33 contra 32/33.
  # El mecanismo se deja porque hace exactamente lo que dice y esta probado (15 casos), pero no
  # entra por la misma regla que dejo afuera a la disputa cruzada: si no le gana a no tenerlo, no va.
  # Se enciende con MENTIS_RELECTURA_ON=1. (MENTIS_RELECTURA_OFF=1 sigue ganandole, por si algun
  # script viejo lo pasa.)
  if [ "${MENTIS_RELECTURA_ON:-0}" = "1" ] && [ "${MENTIS_RELECTURA_OFF:-0}" != "1" ] \
     && [ "$TOOL" = "read" ] && [ "${RELEE_PROPIO:-0}" = "1" ] \
     && [[ "$OBS" != ERROR:* ]]; then
    OBS="AVISO: este archivo ('${REL:-}') lo escribiste VOS en este mismo turno y no cambio desde entonces -- lo que sigue es exactamente lo que mandaste. Leerlo no te dice nada nuevo y cuesta un paso entero. Segui con lo que falta; si ya esta todo, respondé con done.

$OBS"
    echo "[nv-agent] iter $it: relectura de lo propio ($REL) -- avisado" >&2
  fi

  # GENERALIZADO EL 2026-08-14. La version anterior de esta guarda miraba SOLO 'read'. El agujero
  # aparecio probando el gate de completitud: se le pidio un archivo y escribio el MISMO
  # 'resta_gate_7k2.py' seis veces seguidas -- seis 'write' exitosos, uno atras del otro -- hasta
  # agotar el presupuesto y terminar sin responder. Ningun detector lo vio: el de errores porque
  # no habia errores, y el de aciertos porque solo entendia de 'read'. Para el usuario se ve igual que
  # un cuelgue.
  #
  # Ahora cuenta por FIRMA DE ACCION (herramienta + argumentos), y por total, no por racha:
  # un bucle alternado (write A, write B, write A, write B) es igual de mortal y la version
  # por rachas lo daba por bueno.
  #
  # QUE ENTRA EN LA FIRMA, Y POR QUE NO ES LO MISMO PARA TODAS LAS HERRAMIENTAS:
  #   - write/edit: la firma es ruta + contenido. Reescribir el mismo archivo con contenido
  #     DISTINTO es corregir, y eso es trabajo legitimo: no cuenta.
  #   - todo lo demas (read/search/exec/git/browse/...): la firma incluye WRITE_CNT, o sea el
  #     estado del mundo. Volver a correr el mismo test DESPUES de escribir algo es exactamente
  #     lo que queremos que haga -- la firma cambia sola y no se lo penaliza. Repetirlo sin haber
  #     tocado nada en el medio es el bucle.
  if [[ "$OBS" != ERROR:* ]] && [ "$TOOL" != "done" ]; then
    case "$TOOL" in
      write|edit) OK_SIG_RAW="$TOOL|${PATH_B64:-}|${CONTENT_B64:-}|${NEW_B64:-}|${OLD_B64:-}" ;;
      *)          OK_SIG_RAW="$TOOL|${PATH_B64:-}|${QUERY_B64:-}|${CODE_B64:-}|${URL_B64:-}|${ACTION_B64:-}|${TARGET_B64:-}|w$WRITE_CNT" ;;
    esac
    OK_SIG_KEY="$(printf '%s' "$OK_SIG_RAW" | cksum | cut -d' ' -f1)"
    OK_SIG_COUNT["$OK_SIG_KEY"]=$(( ${OK_SIG_COUNT["$OK_SIG_KEY"]:-0} + 1 ))
    OK_SIG_VECES="${OK_SIG_COUNT["$OK_SIG_KEY"]}"
    # EL AVISO SOLO NO ALCANZA (2026-08-15, bug reportado por el usuario con captura).
    #
    # Le pidio un brazalete con modulos intercambiables. El turno hizo 'task create' QUINCE veces
    # con la misma firma: la guarda aviso trece veces seguidas -- de la 3a a la 15a -- y el modelo
    # siguio igual. Nunca genero el documento, quemo el presupuesto entero y el usuario termino leyendo
    # un texto interno. Trece avisos ignorados no son un empujon: son un cuelgue con subtitulos.
    #
    # POR ESO AHORA HAY DOS ESCALONES. El aviso se mantiene tal cual estaba (a las 3 veces), porque
    # el razonamiento original sigue en pie: la accion estuvo BIEN y a veces alcanza con avisar. Lo
    # que se agrega es un techo: a las 6, se corta.
    #
    # Y SE CORTA SIN DEJAR A USUARIO SIN NADA, que era la objecion correcta contra cortar. Si el turno
    # tenia acciones reales, se prende CIERRE_FORZADO y se le pide al modelo la respuesta final con
    # lo que ya hizo (el mismo camino del cierre por objetivo logrado). Si no hizo nada real -- que
    # es justo el caso de los 15 'task create' -- se corta como loop y mentis-chat.sh ya tiene el
    # mensaje honesto para eso. Las dos salidas son mejores que quince vueltas.
    if [ "$OK_SIG_VECES" -ge "${OK_SIG_CORTE:-6}" ]; then
      LOOP_DETECTADO=1
      [ "${ACCIONES_N:-0}" -gt 0 ] && CIERRE_FORZADO=1
      OBS="ERROR: repetiste '$TOOL' con los mismos argumentos $OK_SIG_VECES veces en este turno y te lo avisé $(( OK_SIG_VECES - OK_SIG_MAX + 1 )) veces. No estás avanzando, así que corto acá para no seguir gastando el presupuesto del usuario."
      echo "[nv-agent] iter $it: BUCLE DE ACIERTOS -- CORTO EL TURNO: '$TOOL' repetido $OK_SIG_VECES veces pese a $(( OK_SIG_VECES - OK_SIG_MAX + 1 )) avisos" >&2
    elif [ "$OK_SIG_VECES" -ge "$OK_SIG_MAX" ]; then
      # No corta el turno: le devuelve el resultado UNA vez mas con un empujon. Cortar castigaria
      # al modelo por una accion que estuvo BIEN -- el problema no es la accion, es no darse
      # cuenta de que ya la tiene hecha. Cortar aca dejaria al usuario sin nada teniendo el trabajo
      # hecho, que es el error que ya costo el cierre forzado de 2026-08-08.
      case "$TOOL" in
        write|edit)
          OBS="AVISO: ya escribiste '${REL:-ese archivo}' $OK_SIG_VECES veces en este turno con EXACTAMENTE el mismo contenido. El archivo ya existe y ya dice eso: volver a escribirlo no cambia nada y te queda menos presupuesto. Segui con lo que falta, o si ya esta todo, respondé con done." ;;
        read)
          OBS="AVISO: ya leiste '${REL:-ese archivo}' $OK_SIG_VECES veces en este mismo turno y su contenido no cambio -- lo tenes completo mas arriba, en las observaciones anteriores. Volver a leerlo no te va a dar nada nuevo y te queda poco presupuesto. Contesta AHORA con lo que ya leiste; si de verdad falta algo, es que no esta en ese archivo." ;;
        *)
          OBS="AVISO: esta es la ${OK_SIG_VECES}a vez que hacés esta misma acción ('$TOOL') con los mismos argumentos en este turno, y no cambió nada en el medio: el resultado es el mismo que ya tenés más arriba. Repetirla no te va a dar información nueva. Si te falta algo, probá otra cosa; si ya tenés lo que necesitabas, respondé con done." ;;
      esac
      echo "[nv-agent] iter $it: BUCLE DE ACIERTOS -- '$TOOL' repetido $OK_SIG_VECES veces con la misma firma; empujando a avanzar" >&2
    fi
  fi

  # registrar el turno en el historial (acción compacta + observación truncada)
  ACTLINE="{\"tool\":\"$TOOL\"}"
  HIST="$HIST
--- turno $it ---
acción: $ACTLINE
observación:
$OBS
"

  # LA PROCEDENCIA DEL TEXTO (2026-08-16). Cada observacion que el motor le da al modelo se anota
  # tambien en un archivo aparte. Al cerrar, la respuesta final se compara contra ESTE registro:
  # si comparte con alguna observacion una tirada larga y textual de palabras, es eco, y no se le
  # muestra al usuario.
  #
  # POR QUE ACA Y NO EN CADA GUARDA: hay ~100 puntos en este archivo que arman un OBS, y TODOS
  # terminan pasando por esta linea. Es la unica puerta. Registrar en un solo lugar cubre tambien
  # las guardas que se escriban manana, que es lo que la deteccion por marcadores no puede hacer:
  # esa es una lista que hay que mantener sincronizada a mano, y las listas se desincronizan
  # (ERR-130, ERR-159, ERR-165 son tres versiones del mismo cuento).
  #
  # Va a un ARCHIVO y no a una variable porque el historial de un turno largo pesa, y este dato
  # solo se lee una vez al final: no tiene por que vivir en memoria todo el turno.
  if [ -n "${NVA_OBS_LOG:-}" ]; then
    printf '%s\n\036\n' "$OBS" >> "$NVA_OBS_LOG" 2>/dev/null || true
  fi
  if [ "$LOOP_DETECTADO" = "1" ]; then
    STATUS="loop_detectado"
    break
  fi
done

echo "" >&2
# CIERRE FORZADO: se corto el turno porque ya habia logrado el objetivo y seguia dando vueltas.
# Este caso NO es un fracaso y no puede tratarse como tal: hay artefactos reales, hechos y
# guardados. Sin esta rama caia en el "no llegue a una respuesta final" de abajo, que le habria
# dicho al usuario que la tarea no se resolvio cuando su documento estaba listo hace cinco pasos.
# Se le pide UNA sola respuesta final al modelo, con el historial completo y una instruccion
# acotada: contar que hizo y donde quedo. Si eso falla, se arma un cierre a mano -- pero nunca
# se reporta como fracaso algo que produjo resultados.
if [ "$STATUS" != "done" ] && [ "${CIERRE_FORZADO:-0}" = "1" ]; then
  echo "[nv-agent] cierre forzado: habia $ACCIONES_N accion(es) real(es) sin reportar; pidiendo la respuesta final" >&2
  _cierre_prompt="Terminaste la tarea. En este turno completaste $ACCIONES_N acción(es) real(es).

$HIST

Escribí AHORA la respuesta final para el usuario, en español y en pocas líneas: qué hiciste, qué generaste y dónde quedó guardado. Si generaste un archivo, nombralo con su ruta. NO listes directorios, NO cuentes lo que buscaste, NO ofrezcas seguir con otro enfoque."
  FINAL="$(printf '%s' "$_cierre_prompt" | bash "$NVDIR/ask-nvidia.sh" -r "$ROLE" 2>/dev/null || true)"
  if [ -z "$FINAL" ]; then
    # Ultimo recurso: sin modelo, se dice lo unico que sabemos con certeza -- que hubo acciones
    # reales -- en vez de mentir en cualquiera de las dos direcciones.
    FINAL="Terminé la tarea: completé $ACCIONES_N acción(es) en este turno. Revisá el panel de previsualización para ver los archivos generados."
  fi
  STATUS="done"
fi
if [ "$STATUS" = "done" ]; then
  printf '%s\n' "$FINAL"
  nv_log "tool=nv-agent status=done iters=$it role=$ROLE write=$WRITE_CNT exec=$EXEC_CNT cierre_forzado=${CIERRE_FORZADO:-0}" 2>/dev/null || true
else
  echo "[nv-agent] terminé sin respuesta final (status=$STATUS, iter=$it/$MAXIT)." >&2
  echo "[nv-agent] Reporte parcial honesto — lo último explorado quedó en el historial; la tarea NO se resolvió del todo." >&2
  # devolver el historial para que el invocador (Opus) decida
  printf 'STATUS=%s\nEl agente de apoyo no llegó a una respuesta final. Historial explorado:\n%s\n' "$STATUS" "$HIST"
  nv_log "tool=nv-agent status=$STATUS iters=$it role=$ROLE write=$WRITE_CNT exec=$EXEC_CNT" 2>/dev/null || true
  exit 4
fi

fi
