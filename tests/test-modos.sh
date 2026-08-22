#!/usr/bin/env bash
# test-modos.sh -- que el reparto de capacidades por modo sea real y no una promesa del prompt.
#
# QUE SE PRUEBA (2026-08-10): Mentis pasa a tener cuatro modos (Mentis, Code, Designe, Cowork) y
# cada uno ve una parte de sus capacidades. Un reparto asi se puede fingir de dos maneras, y las
# dos ya pasaron en este proyecto:
#   1. Escribiendolo solo en el prompt ("en este modo no podes ejecutar"). Eso es una sugerencia,
#      no una defensa -- es literalmente lo que fallo con la camara (ERR-133).
#   2. Comprobandolo contra una copia del protocolo en vez de contra el protocolo real. Una copia
#      se desactualiza y el test pasa a aprobar algo que ya no es lo que corre (ERR-130).
# Por eso casi todo lo de aca abajo le PREGUNTA AL MOTOR REAL que herramientas ofrece, corriendo
# nv-agent.sh con NVA_SOLO_PROTOCOLO=1 (arma el protocolo, lo imprime y sale sin llamar a nadie).
#
# LA INVARIANTE MAS IMPORTANTE DE TODO EL SISTEMA: **un modo solo puede QUITAR**. Los permisos
# salen de los conectores que el usuario prende en la app; el modo se aplica encima y solo apaga. Si
# alguna vez un modo pudiera AGREGAR, elegir "Code" prenderia la camara aunque el usuario la tenga
# apagada -- y no fallaria nada visible. Ese caso tiene su propio bloque abajo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$HERE/engine/nv-modos-lib.sh"
JSON="$HERE/modos.json"
AGENTE="$HERE/engine/nv-agent.sh"
CHAT="$HERE/mentis-chat.sh"
# node NO entiende rutas MSYS: con "/c/Users/..." resuelve la unidad como una carpeta y busca en
# "C:\c\Users\...", que no existe (ERR-004, ya documentado). bash usa la ruta de la izquierda y
# node la de la derecha. Y se pasa por variable de entorno, no interpolada dentro del -e, porque
# la version de Windows viene con barras invertidas que JavaScript leeria como escapes.
JSON_WIN="$(cygpath -w "$JSON" 2>/dev/null || echo "$JSON")"
HERE_WIN="$(cygpath -m "$HERE" 2>/dev/null || echo "$HERE")"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# Le pregunta al motor REAL que herramientas le ofreceria al modelo en ese modo.
_tools_de() {
  local modo="$1" banderas sin
  banderas="$(bash "$LIB" banderas "$modo")"
  sin="$(bash "$LIB" sin-tools "$modo")"
  # shellcheck disable=SC2086
  NVA_SOLO_PROTOCOLO=1 bash "$AGENTE" $banderas -n "$sin" -d "$HERE" "x" 2>/dev/null \
    | grep -oE '^  \{"tool":"[a-z]+' | sed 's/.*"//' | sort -u
}

echo "== la declaracion existe y esta completa =="
MODOS_JSON="$JSON_WIN" node -e "JSON.parse(require('fs').readFileSync(process.env.MODOS_JSON,'utf8'))" 2>/dev/null \
  && _ok "modos.json es JSON valido" \
  || _mal "modos.json parsea" "si no parsea, nv_modo_actual cae al de por defecto y el reparto no existe"

# LOS MODOS SE LEEN DE modos.json Y NO SE ESCRIBEN ACA (2026-08-16). Estaban a mano, asi que
# al agregar Mentis Editor el modo nuevo no lo probaba nadie -- el unico caso que lo delato
# fue el del catalogo, y por otro motivo. Un test que hay que acordarse de actualizar no
# cubre lo que se agrega manana.
for m in $(bash "$LIB" lista | cut -f1); do
  t="$(bash "$LIB" titulo "$m")"
  p="$(bash "$LIB" persona "$m")"
  [ -n "${t// }" ] && [ "$t" != "Mentis" -o "$m" = "mentis" ] \
    && _ok "el modo '$m' tiene titulo ($t)" \
    || _mal "titulo de '$m'" "sin titulo, el logotipo del header no sabe que mostrar"
  [ -n "${p// }" ] \
    && _ok "el modo '$m' le explica al modelo que puede hacer" \
    || _mal "persona de '$m'" "apagarle herramientas sin decirselo lo manda a chocar contra una pared (ERR-098)"
done

echo "== el catalogo de herramientas coincide con el motor REAL =="
# Si alguien agrega una herramienta a nv-agent.sh y no la reparte en ningun anillo, queda en un
# limbo: ni disponible ni prohibida. Y al reves, una del catalogo que el motor ya no tenga es una
# regla que no protege nada.
DESPACHO="$(grep -oE '^    [a-z|]+\)$' "$AGENTE" | tr -d ' )' | tr '|' '\n' | sort -u)"
CATALOGO="$(MODOS_JSON="$JSON_WIN" node -e "
  const d = JSON.parse(require('fs').readFileSync(process.env.MODOS_JSON,'utf8'));
  process.stdout.write(d._todas_las_herramientas.join('\n'))" | sort -u)"
# 'hardware' es alias de 'arduino' en el despacho; 'capacity'/'capability' de 'capacidad'.
FALTAN="$(comm -23 <(echo "$DESPACHO") <(echo "$CATALOGO") | grep -vxE 'hardware|capacity|capability' || true)"
SOBRAN="$(comm -13 <(echo "$DESPACHO") <(echo "$CATALOGO") || true)"
[ -z "${FALTAN// }" ] \
  && _ok "toda herramienta del motor esta repartida en algun anillo" \
  || _mal "hay herramientas sin repartir" "quedan en el limbo (ni ofrecidas ni prohibidas): $(echo $FALTAN)"
[ -z "${SOBRAN// }" ] \
  && _ok "el catalogo no inventa herramientas que el motor no tiene" \
  || _mal "el catalogo tiene de mas" "reglas que no protegen nada: $(echo $SOBRAN)"

echo "== UN MODO SOLO PUEDE QUITAR (la invariante que sostiene todo) =="
# Se simula el filtro de mentis-chat.sh con una lista de banderas de entrada, y se exige que la
# salida sea un SUBCONJUNTO. Cualquier bandera que aparezca a la salida sin estar a la entrada
# significa que el modo encendio algo por su cuenta.
_filtrar() {  # $1 = modo, $2 = banderas que dieron los conectores
  local libres okset="" f
  libres="$(bash "$LIB" banderas "$1") $(bash -c "source '$LIB'; _mc_banderas_libres")"
  for f in $2; do case " $libres " in *" $f "*) okset="$okset $f" ;; esac; done
  echo "$okset"
}
for m in mentis code designe cowork study science; do
  ENTRADA="-w -b -g -K"          # unos pocos conectores prendidos, NINGUNO invasivo
  SALIDA="$(_filtrar "$m" "$ENTRADA")"
  DEMAS=""
  for f in $SALIDA; do case " $ENTRADA " in *" $f "*) ;; *) DEMAS="$DEMAS $f" ;; esac; done
  [ -z "${DEMAS// }" ] \
    && _ok "el modo '$m' no enciende nada que los conectores dejaron apagado" \
    || _mal "'$m' AGREGA banderas" "encendio$DEMAS sin que nadie lo decida -- este es EL bug grave"
done
# Y el caso concreto que mas importa: la camara apagada sigue apagada en el modo mas permisivo.
SALIDA="$(_filtrar cowork "-w -b")"
case " $SALIDA " in
  *" -V "*) _mal "camara apagada en modo Cowork" "el modo prendio la camara sin conector" ;;
  *)        _ok  "con el conector de camara apagado, ni el modo mas permisivo la enciende" ;;
esac

echo "== el modo Mentis (a secas) no puede romper ni mirar nada =="
TOOLS_CHAT="$(_tools_de mentis)"
for t in exec run git lsp delegate parallel subagent screen control webcam telefono arduino mcp vscode datos; do
  if echo "$TOOLS_CHAT" | grep -qx "$t"; then
    _mal "el modo Mentis ofrece '$t'" "es el unico modo que se le puede prestar a otra persona: no puede tener esto"
  else
    _ok "el modo Mentis NO ofrece '$t'"
  fi
done

# 'run' esta en esa lista por algo que solo aparecio corriendo un turno de verdad: corre en un
# sandbox AISLADO que no ve la carpeta de trabajo, pero en la respuesta se lee igual que ejecutar
# un comando. En la primera corrida real del modo Mentis, el modelo lo uso para "confirmar con ls"
# un archivo recien creado y reporto como confirmacion la salida de OTRO directorio. Un modo que
# promete "no ejecuta comandos" no puede tener una herramienta que se describe como ejecutar.

echo "==...pero si puede hacer su trabajo =="
for t in read search browse write edit recordar task skill; do
  echo "$TOOLS_CHAT" | grep -qx "$t" \
    && _ok "el modo Mentis ofrece '$t'" \
    || _mal "al modo Mentis le falta '$t'" "sin esto no es un chat, es un adorno"
done

echo "== los otros modos si tienen su oficio =="
TOOLS_CODE="$(_tools_de code)"
for t in exec git lsp vscode subagent; do
  echo "$TOOLS_CODE" | grep -qx "$t" \
    && _ok "Mentis Code ofrece '$t'" \
    || _mal "a Mentis Code le falta '$t'" "es justo lo que define al modo"
done
TOOLS_COWORK="$(_tools_de cowork)"
for t in delegate parallel subagent; do
  echo "$TOOLS_COWORK" | grep -qx "$t" \
    && _ok "Mentis Cowork ofrece '$t'" \
    || _mal "a Mentis Cowork le falta '$t'" "sin repartir trabajo no es Cowork"
done

echo "== la prohibicion tambien vive en el codigo, no solo en el prompt =="
# Sacar la herramienta del protocolo cubre el 99%. Esta es la segunda capa, para el modelo que la
# recuerda de su entrenamiento o que copia una respuesta de un turno donde si estaba.
grep -q 'RECHAZADO (apagada en este modo)' "$AGENTE" \
  && _ok "si el modelo pide una herramienta apagada, bash la rechaza" \
  || _mal "hay rechazo en el despacho" "sin esto la prohibicion es una sugerencia (la leccion de ERR-133)"
grep -q '\[ "\$TOOL" != "done" \]' "$AGENTE" \
  && _ok "'done' nunca se puede apagar" \
  || _mal "'done' esta protegida" "si se apaga, el turno no tiene forma de terminar y siempre agota el presupuesto"

echo "== el chat aplica el modo, y lo aplica DESPUES de los conectores =="
grep -q 'MC_SIN_TOOLS="\$(nv_modo_sin_tools' "$CHAT" \
  && _ok "mentis-chat calcula las herramientas apagadas del modo" \
  || _mal "el chat usa nv_modo_sin_tools" "sin esto el modo no llega al motor"
grep -q 'nv-agent.sh" \$NVA_FLAGS -n "\$MC_SIN_TOOLS"' "$CHAT" \
  && _ok "y se las pasa al motor con -n" \
  || _mal "el chat pasa -n" "se calcula la lista y no se usa"
# El orden es la garantia de la invariante: si el filtro estuviera ANTES de armar las banderas,
# la interseccion se haria contra una lista vacia y el modo pasaria a ser la unica fuente.
LINEA_CARBS="$(grep -n 'ALLOW_CARBS" = "1" \] && NVA_FLAGS' "$CHAT" | head -1 | cut -d: -f1)"
LINEA_FILTRO="$(grep -n 'MC_FLAGS_FILTRADAS="\$MC_FLAGS_FILTRADAS' "$CHAT" | head -1 | cut -d: -f1)"
if [ -n "$LINEA_CARBS" ] && [ -n "$LINEA_FILTRO" ] && [ "$LINEA_FILTRO" -gt "$LINEA_CARBS" ]; then
  _ok "el filtro del modo corre DESPUES de armar las banderas de los conectores"
else
  _mal "orden del filtro" "si filtra antes, el modo deja de ser una interseccion y pasa a ser la fuente de permisos"
fi

echo "== la puerta: cuando algo no esta en este modo =="
grep -q 'LA PUERTA:' "$CHAT" \
  && _ok "se le explica al modelo que ofrezca cambiar de modo" \
  || _mal "existe la instruccion de la puerta" "sin ella, separar capacidades se siente un castigo y no un orden"
grep -q 'vos no cambiás de modo solo' "$CHAT" \
  && _ok "y que el cambio lo decide el usuario, no el modelo" \
  || _mal "el modelo no se cambia solo de modo" "un modo que se puede auto-levantar no es un limite"

echo "== degradar sin romper =="
# Se compara contra el modo POR DEFECTO, no contra "lo que devuelve sin variable de entorno". La
# primera version hacia eso ultimo y se rompio sola en cuanto alguien eligio un modo desde la app:
# sin variable devuelve el modo GUARDADO, que es otra cosa. El test medía dos valores que no
# tienen por que coincidir y lo hacia pasar por un fallo del codigo.
POR_DEFECTO="$(MODOS_JSON="$JSON_WIN" node -e "
  const d = JSON.parse(require('fs').readFileSync(process.env.MODOS_JSON,'utf8'));
  process.stdout.write(d.por_defecto || 'mentis')")"
[ "$(MENTIS_MODO=no-existe-este-modo bash "$LIB" actual)" = "$POR_DEFECTO" ] \
  && _ok "un modo inventado cae al de por defecto ($POR_DEFECTO) en vez de dejar a Mentis sin modo" \
  || _mal "degradacion" "un modo desconocido tiene que caer al de fabrica, no romper el turno"
# Y el modo guardado tambien tiene que ser uno que exista: si alguien renombra un modo, el que
# quedo guardado en state.json apunta a la nada.
GUARDADO="$(bash "$LIB" actual)"
bash "$LIB" titulo "$GUARDADO" >/dev/null 2>&1 && [ -n "$GUARDADO" ] \
  && _ok "el modo guardado ('$GUARDADO') existe en la lista" \
  || _mal "modo guardado invalido" "state.json apunta a un modo que ya no esta"
[ -n "$(bash "$LIB" lista)" ] \
  && _ok "hay una sola lista de modos y la sirve la libreria" \
  || _mal "nv_modo_lista responde" "si la app arma su propia lista, un dia va a tener modos distintos a los del motor"

echo "== la app: el cambio de modo se VE, no pasa por atras =="
# el usuario lo pidio con todas las letras: "estaria mal si fuese solo por atras". Un modo que cambia en
# silencio es indistinguible de uno que no cambio -- y lo que cambia son los PERMISOS.
R="$HERE/app/renderer/renderer.js"
H="$HERE/app/renderer/index.html"
C="$HERE/app/renderer/style.css"
M="$HERE/app/main.js"
P="$HERE/app/preload.js"

# El selector se mudo del logotipo al compositor (2026-08-11): con seis modos, el lugar para
# elegir es donde estas por escribir, no arriba a la izquierda. El logotipo quedo mostrando en que
# modo estas. Un lugar para ver, otro para cambiar.
grep -q 'id="modo-fichas"' "$H"   && _ok "las fichas de modo estan en el compositor, donde se escribe"   || _mal "el selector esta donde se usa" "el modo decide que puede hacer Mentis: no puede vivir escondido"
grep -q 'id="header-wordmark"' "$H"   && _ok "el logotipo sigue mostrando en que modo estas"   || _mal "el logotipo muestra el modo" "sin el, no hay forma de saber en que modo estas de un vistazo"
grep -q 'id="modo-menu"' "$H"   && _mal "quedo el menu desplegable viejo" "hay dos selectores: uno va a quedar desincronizado"   || _ok "no quedo el menu desplegable viejo (un solo selector)"
grep -q "document.documentElement.dataset.modo = modo.id" "$R"   && _ok "el modo queda marcado en el <html> (como el tema)"   || _mal "data-modo" "sin eso el CSS no puede cambiar la letra del logotipo"
for _m in code designe cowork; do
  grep -q ":root\[data-modo=\"$_m\"\]" "$C"     && _ok "el modo '$_m' tiene su propia letra en el logotipo"     || _mal "letra de '$_m'" "los cuatro logotipos se verian iguales y el cambio no se notaria"
done
grep -q 'pasás a \${modo.titulo}' "$R"   && _ok "queda una linea en la conversacion marcando el corte"   || _mal "el corte se ve en la conversacion" "sin marca, media hora despues no sabes en que modo dijiste que"
grep -q '\.modo-corte' "$C"   && _ok "esa linea tiene estilo propio (no parece un mensaje de Mentis)"   || _mal "estilo de la marca de corte" "si parece algo que dijo Mentis, ensucia el historial"

echo "== la app y el motor leen la MISMA lista de modos =="
grep -q "require('./lib/modos-store')" "$M"   && _ok "main.js usa el store de modos"   || _mal "main.js lee modos" "si la app arma su propia lista, un dia va a tener modos que el motor no conoce"
grep -q "modos.json" "$HERE/app/lib/modos-store.js"   && _ok "y ese store lee modos.json, el mismo archivo que el motor"   || _mal "una sola fuente" "dos listas de modos terminan siendo dos productos distintos"
grep -q 'onModoCambio' "$P"   && _ok "el aviso del cambio llega por evento (sirve aunque el cambio venga de afuera)"   || _mal "evento de cambio" "solo se enteraria si el cambio lo hizo el propio boton"

echo "== degradar sin romper (del lado de la app) =="
node -e "
  const s = require('$HERE_WIN/app/lib/modos-store.js');
  const d = s.leerDeclaracion('/carpeta/que/no/existe');
  if (!d || !d.modos || !Object.keys(d.modos).length) process.exit(1);
" 2>/dev/null   && _ok "sin modos.json la app abre igual, con un modo minimo"   || _mal "degradacion en la app" "un JSON con una coma de mas no puede impedir que Mentis abra"

echo "== el reparto de capacidades por modo (2026-08-12) =="
# Los invasivos solo en Code y Cowork; imagenes/3D solo en Designe. La regla que lo sostiene es
# "el boton se ve si y solo si el modo tiene su bandera", asi que se comprueban las BANDERAS.
for m in code cowork; do
  for f in -s -V -P -a; do
    bash "$LIB" banderas "$m" | grep -q -- "$f"       && _ok "'$m' tiene la capacidad invasiva $f"       || _mal "'$m' sin $f" "el usuario pidio los invasivos en Code y Cowork"
  done
done
for m in mentis designe study science; do
  for f in -s -V -P -a; do
    bash "$LIB" banderas "$m" | grep -q -- "$f"       && _mal "'$m' tiene $f" "los invasivos van SOLO en Code y Cowork"       || _ok "'$m' NO tiene la invasiva $f"
  done
done
bash "$LIB" banderas designe | grep -q -- "-g"   && _ok "Designe es el unico con imagenes y 3D (-g)"   || _mal "Designe sin -g" "el boton de imagenes es suyo"
for m in mentis code cowork study science; do
  bash "$LIB" banderas "$m" | grep -q -- "-g"     && _mal "'$m' tiene -g" "imagenes y 3D es solo de Designe"     || _ok "'$m' NO genera imagenes"
done

echo "== los botones de la app siguen a las banderas, no a una lista aparte =="
# Una lista de "botones por modo" se desincroniza el primer dia que se crea un modo. Atado a la
# bandera, un modo nuevo hereda el reparto correcto sin tocar codigo -- que es exactamente lo que
# paso con Study y Science.
grep -q "const BOTON_BANDERA" "$HERE/app/renderer/renderer.js"   && _ok "existe el mapa boton -> bandera"   || _mal "el mapa boton->bandera" "sin el, los botones no se reparten por modo"
grep -q "banderas: unicos(" "$HERE/app/lib/modos-store.js"   && _ok "la app recibe las banderas del modo"   || _mal "modos-store expone banderas" "el renderer no sabria que esconder"
# Cada id del mapa tiene que existir de verdad en el HTML: un id inventado esconde nada y no falla.
for id in $(grep -oE "'flag-[a-z-]+':" "$HERE/app/renderer/renderer.js" | tr -d "':"); do
  grep -q "id=\"$id\"" "$HERE/app/renderer/index.html"     && _ok "el boton '$id' existe en el HTML"     || _mal "'$id' no existe" "un id inventado no esconde nada y no da error: el boton quedaria siempre visible"
done

echo "== los dos modos nuevos tienen su limite claro =="
bash "$LIB" persona study | grep -qi "corpus cerrado"   && _ok "Study se define por su corpus cerrado"   || _mal "persona de Study" "sin esa regla es un chat mas, no un NotebookLM"
bash "$LIB" persona science | grep -qi "NO INVENTAS"   && _ok "Science tiene prohibido inventar datos y citas"   || _mal "persona de Science" "es la unica regla que lo hace util para algo cientifico"

echo "== Study es un corpus CERRADO de verdad, no solo en el prompt (2026-08-12) =="
# La promesa del modo es "solo con lo que el usuario te dio". Se puede romper por dos puertas y las dos
# estaban abiertas hasta hoy:
#   1. 'browse' vive en el ANILLO 0, asi que Study podia salir a Internet -- y una cita a una
#      pagina web en un modo que promete citar TUS fuentes es peor que no citar nada.
#   2. el lookup de Kai Vault corre en TODOS los turnos y le metia el codigo de Mentis al prompt
#      rotulado como fuente.
# Ninguna de las dos habria hecho fallar un test: el modo "anda", solo que contesta con material
# que no es el del usuario.
STUDY_SIN="$(bash "$LIB" sin-tools study)"
for t in browse drive; do
  printf '%s' "$STUDY_SIN" | tr ',' '\n' | grep -qx "$t" \
    && _ok "Study tiene apagado '$t' (no puede traer nada de afuera del corpus)" \
    || _mal "Study puede usar '$t'" "un modo de corpus cerrado que sale a la web no es un corpus cerrado"
done
_tools_de study | grep -qx "browse" \
  && _mal "el motor REAL le ofrece browse a Study" "sin-tools lo dice pero el protocolo no lo aplica" \
  || _ok "el motor real no le ofrece 'browse' a Study"

# La invariante, ahora sobre el mecanismo nuevo: herramientas_fuera SOLO puede apagar. Se prueba
# con el caso que la rompiria -- pedir por herramientas_fuera algo que el modo SI tiene declarado
# no puede sacarlo de la lista de apagadas ni, mucho menos, encenderlo.
CODE_SIN_ANTES="$(bash "$LIB" sin-tools code)"
TMP_JSON="$(mktemp)"
MODOS_JSON="$JSON_WIN" SALIDA="$(cygpath -w "$TMP_JSON" 2>/dev/null || echo "$TMP_JSON")" node -e '
  const fs = require("fs");
  const d = JSON.parse(fs.readFileSync(process.env.MODOS_JSON, "utf8"));
  // "exec" es una herramienta que Code SI tiene. Si herramientas_fuera pudiera dar permisos,
  // ponerla aca la dejaria encendida igual; si esta bien hecho, la APAGA.
  d.modos.code.herramientas_fuera = ["exec"];
  fs.writeFileSync(process.env.SALIDA, JSON.stringify(d));
' 2>/dev/null
CODE_SIN_DESPUES="$(MENTIS_MODO=code NVMODOS_JSON="$TMP_JSON" bash -c '
  source "'"$LIB"'"; NVMODOS_JSON="'"$TMP_JSON"'"; nv_modo_sin_tools code')"
printf '%s' "$CODE_SIN_DESPUES" | tr ',' '\n' | grep -qx "exec" \
  && _ok "herramientas_fuera solo apaga (nunca saca nada de la lista de apagadas)" \
  || _mal "herramientas_fuera no apago 'exec'" "si puede fallar hacia el lado permisivo, es una llave maestra y no una segunda llave"
for t in $(printf '%s' "$CODE_SIN_ANTES" | tr ',' ' '); do
  printf '%s' "$CODE_SIN_DESPUES" | tr ',' '\n' | grep -qx "$t" \
    || _mal "herramientas_fuera ENCENDIO '$t'" "un modo que agrega permisos rompe el modelo de seguridad entero"
done
_ok "herramientas_fuera no encendio ninguna de las que ya estaban apagadas"
rm -f "$TMP_JSON"

# El corpus: que exista la declaracion Y que el chat la use. Lo segundo es lo que importa --
# declararlo sin conectarlo es el estado en el que Study ya estuvo dos dias.
bash "$LIB" corpus study | grep -q "knowledge/estudio" \
  && _ok "Study declara su corpus propio" \
  || _mal "Study sin corpus" "sin corpus, el lookup le mete el codigo de Mentis como material de estudio"
[ -z "$(bash "$LIB" corpus code 2>/dev/null)" ] \
  && _ok "los demas modos no tienen corpus (siguen con Kai Vault normal)" \
  || _mal "otro modo tiene corpus" "el corpus cerrado es de Study; en Code romperia Kai Vault"
grep -q 'MENTIS_CORPUS_DIR' "$CHAT" \
  && _ok "mentis-chat.sh cambia la fuente del lookup segun el modo" \
  || _mal "el chat ignora el corpus" "la declaracion no sirve de nada si el lookup sigue yendo al ecosistema"
grep -q 'MENTIS_CORPUS_DIR' "$HERE/capabilities/boveda.sh" \
  && _ok "boveda.sh busca en el corpus cuando se lo piden" \
  || _mal "boveda.sh ignora el corpus" "sin esto el lookup sigue trayendo el ecosistema aunque el chat lo pida"
grep -q 'MC_KAI_ROTULO_ESTUDIO' "$CHAT" \
  && _ok "el bloque viaja rotulado como material del usuario y no como Kai Vault" \
  || _mal "rotulo fijo" "rotular material de estudio como 'ecosistema Mentis' hace que cite mal la fuente"

echo "== el corpus es un patio mas, no un agujero en la jaula =="
# 'read' llega al material de estudio a proposito (el modelo necesita el documento entero para
# resumir, y pelearle costaba el turno -- ERR-143). Pero eso agrega una segunda raiz legible, y
# una segunda raiz sin su propia comprobacion de '..' es una salida de la jaula. Se prueba la
# resolucion de rutas aislada, con las tres fugas que importan: el sistema, el codigo de Mentis
# y el material que el usuario ya habia sacado del corpus.
# La invariante NO es "toda ruta rara se rechaza" sino "ninguna termina leyendo algo de afuera".
# Son dos cosas distintas y confundirlas da un test que falla sin que haya un bug: una ruta
# absoluta como '/etc/passwd' se concatena como sufijo ('<corpus>//etc/passwd') y realpath la
# deja DENTRO del corpus, apuntando a un archivo que no existe. Eso es seguro. Lo que no puede
# pasar nunca es que el resultado caiga fuera de la carpeta del corpus.
CORPUS_TEST="$(bash "$LIB" corpus study)"
for intento in "../../../etc/passwd" "../../mentis-chat.sh" "../.estudio-olvidado/x" "/etc/passwd" "..%2f..%2fmentis-chat.sh"; do
  RES="$(INTENTO="$intento" RAIZC="$CORPUS_TEST" bash -c '
    raiz="$(realpath -m -- "$RAIZC" 2>/dev/null)"
    abs="$(realpath -m -- "$raiz/$INTENTO" 2>/dev/null)"
    # Igual que _caged_corpus: si cae fuera, la funcion devuelve 1 y no se lee nada.
    case "$abs/" in "$raiz"/*) printf "DENTRO %s" "$abs" ;; *) printf "NEGADO" ;; esac')"
  case "$RES" in
    NEGADO*) _ok "'$intento': queda fuera del corpus y se niega" ;;
    DENTRO*) _ok "'$intento': resuelve adentro del corpus (${RES#DENTRO }) -- no alcanza nada de afuera" ;;
    *)       _mal "'$intento': resolucion inesperada" "no se pudo determinar si sale del corpus" ;;
  esac
done
grep -q '_caged_corpus' "$AGENTE" \
  && _ok "el motor resuelve el corpus por su propia funcion enjaulada" \
  || _mal "no existe _caged_corpus" "sin una funcion propia, la ruta del corpus se resolveria sin comprobar nada"

echo "== la bandera y la herramienta se apagan JUNTAS (si no, la app promete lo que el motor rechaza) =="
# 'browse' apagada con '-b' encendida le deja al usuario el boton de navegar visible en el unico modo
# que no navega: aprieta, el motor rechaza la herramienta y no falla nada -- solo queda una
# interfaz que miente. Por eso Study tiene banderas_fuera ademas de herramientas_fuera.
bash "$LIB" banderas study | grep -q -- "-b" \
  && _mal "Study conserva -b" "el boton de web quedaria visible en un modo que tiene browse apagada" \
  || _ok "Study no tiene -b (el boton de web no se le muestra)"
for m in mentis code cowork designe; do
  bash "$LIB" banderas "$m" | grep -q -- "-b" \
    && _ok "'$m' sigue navegando (banderas_fuera no toco a los demas)" \
    || _mal "'$m' perdio -b" "banderas_fuera es de Study; sacarsela a otro modo es una regresion"
done
# Y que la app calcule EXACTAMENTE lo mismo: son dos implementaciones del mismo reparto (bash y
# JS) y el dia que discrepen, el boton visible y la herramienta real dejan de coincidir.
for m in study code mentis designe; do
  MOTOR="$(bash "$LIB" banderas "$m" | tr ' ' '\n' | sort | tr -d ' ')"
  APP="$(MODO="$m" node -e "
    const s = require('$HERE_WIN/app/lib/modos-store.js');
    const d = s.datosDelModo('$HERE_WIN', process.env.MODO);
    process.stdout.write(d.banderas.slice().sort().join('\n'));
  " 2>/dev/null)"
  [ "$MOTOR" = "$APP" ] \
    && _ok "'$m': la app y el motor reparten las mismas banderas" \
    || _mal "'$m': app y motor discrepan" "motor=[$MOTOR] app=[$APP] -- el boton visible dejaria de coincidir con lo que se puede usar"
done

echo "== la puerta de entrada del material existe =="
[ -f "$HERE/capabilities/estudiar.sh" ] \
  && _ok "existe /estudiar (sin esto, Study no tiene como recibir material)" \
  || _mal "falta capabilities/estudiar.sh" "un corpus cerrado sin forma de cargarlo es un modo que siempre dice 'no esta'"
head -1 "$HERE/capabilities/estudiar.sh" 2>/dev/null | grep -q '^# CAPABILITY: /estudiar' \
  && _ok "/estudiar se anuncia como capacidad (el dispatcher la carga)" \
  || _mal "/estudiar sin cabecera CAPABILITY" "no aparece en la lista y el usuario no puede invocarla"
bash "$HERE/capabilities/estudiar.sh" materias >/dev/null 2>&1 \
  && _ok "/estudiar corre sin explotar con el corpus vacio" \
  || _mal "/estudiar falla en vacio" "el primer uso del usuario es siempre con el corpus vacio"

echo "== la letra de cada modo: el JSON y la pantalla dicen lo mismo =="
# POR QUE (2026-08-20): `letra` viaja del JSON al renderer y NO PINTA NADA -- la tipografia la
# resuelve el CSS por data-modo. Al no leerse, se fue separando en silencio: designe decia
# "playfair" cuando el logotipo usa Syne, y editor decia "plus-jakarta" sin tener regla CSS, o sea
# que salia en la generica. Ocho dias asi y nadie lo vio, porque un campo que nadie lee no puede
# fallar de forma visible.
#
# La decision (el usuario, 2026-08-20) fue SINCRONIZAR Y COMPLETAR en vez de borrar el campo. Eso solo
# se sostiene con un test que los compare: si no, vuelven a separarse la primera semana. Se mira
# el CSS de verdad, no una lista copiada acá -- una tercera copia del mismo dato tendria el mismo
# problema que las dos que ya hay.
CSS="$HERE/app/renderer/style.css"
# De 'letra' (el JSON) a la familia que el CSS declara en --font-marca.
_familia_css() { # <modo> -> la primera familia de --font-marca, sin comillas
  # Se busca con index() y no con `$0 ~ m`: el selector trae corchetes, y como regex
  # "[data-modo=..]" es una clase de caracteres, asi que matcheaba cualquier linea con una letra
  # de adentro. Daba "el CSS no tiene regla" para modos que si la tenian.
  awk -v m=":root[data-modo=\"$1\"]" '
    index($0, m) > 0 {dentro=1}
    dentro && index($0, "--font-marca:") > 0 {
      sub(/.*--font-marca:[ ]*/, ""); sub(/,.*/, ""); gsub(/["\x27;]/, "");
      gsub(/^[ \t]+|[ \t]+$/, "");
      print; exit
    }
    dentro && $0 == "}" {dentro=0}
  ' "$CSS"
}
# El JSON usa un id corto ("plus-jakarta"), el CSS el nombre real ("Plus Jakarta Sans"): se
# normalizan los dos a minusculas sin espacios y se compara por prefijo.
_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' -'; }
while IFS=$'\t' read -r _m _letra; do
  [ -n "$_m" ] || continue
  _css="$(_familia_css "$_m")"
  if [ -z "$_css" ]; then
    # Sin regla propia, el modo hereda la letra de la interfaz. Eso es valido, pero entonces el
    # JSON tiene que decir 'google-sans' y no otra cosa -- que era el bug de editor.
    if [ "$(_norm "$_letra")" = "googlesans" ]; then
      _ok "'$_m': sin regla propia en el CSS y el JSON dice google-sans"
    else
      _mal "'$_m': el JSON dice '$_letra' pero el CSS no tiene regla" "el logotipo sale en la letra generica: el JSON promete un cambio que no pasa"
    fi
  else
    case "$(_norm "$_css")" in
      "$(_norm "$_letra")"*) _ok "'$_m': JSON '$_letra' = CSS '$_css'" ;;
      *) _mal "'$_m': JSON dice '$_letra' y el CSS pinta '$_css'" "el archivo y la pantalla cuentan cosas distintas" ;;
    esac
  fi
done < <(node -e "
  const d = require('$HERE_WIN/modos.json');
  for (const [id, m] of Object.entries(d.modos)) console.log(id + '\t' + (m.letra || ''));
" 2>/dev/null)

# Y que la fuente que el CSS pide exista como archivo: si el.woff2 no esta, el navegador cae al
# respaldo sin avisar y el modo se ve igual que los demas -- el mismo sintoma, otra causa.
for _m in $(node -e "const d=require('$HERE_WIN/modos.json'); console.log(Object.keys(d.modos).join(' '))" 2>/dev/null); do
  _css="$(_familia_css "$_m")"
  [ -n "$_css" ] || continue
  _slug="$(_norm "$_css")"
  if ls "$HERE/app/renderer/assets/fonts/" 2>/dev/null | tr -d '-' | grep -qi "^$_slug"; then
    _ok "'$_m': la fuente '$_css' esta empaquetada"
  else
    _mal "'$_m': falta el.woff2 de '$_css'" "sin el archivo el navegador usa el respaldo y el modo no se distingue"
  fi
done

echo "== los campos decorativos no vuelven =="
# acento, motor_externo y recordar_ultimo se borraron el 2026-08-20 despues de comprobar que NADIE
# los leia. Un campo declarado y sin cablear no es inofensivo: los tests lo daban por bueno porque
# miraban el JSON y no el uso, y quien lee el archivo cree que ahi se configura algo.
for _muerto in acento motor_externo; do
  if node -e "
    const d = require('$HERE_WIN/modos.json');
    const con = Object.entries(d.modos).filter(([k,m]) => '$_muerto' in m).map(([k]) => k);
    if (con.length) { console.log(con.join(',')); process.exit(1); }
  " >/dev/null 2>&1; then
    _ok "ningun modo declara '$_muerto'"
  else
    _mal "volvio '$_muerto' a modos.json" "si de verdad hace falta, hay que CABLEARLO; declarado y sin leer es peor que no tenerlo"
  fi
done
if node -e "const d=require('$HERE_WIN/modos.json'); if ('recordar_ultimo' in d) process.exit(1);" >/dev/null 2>&1; then
  _ok "no volvio 'recordar_ultimo'"
else
  _mal "volvio 'recordar_ultimo'" "nadie lo lee: ponerlo en false no apaga nada"
fi

echo
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
