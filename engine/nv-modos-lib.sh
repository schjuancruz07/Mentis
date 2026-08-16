#!/usr/bin/env bash
# nv-modos-lib.sh -- traduce modos.json a permisos concretos para un turno.
#
# POR QUE EXISTE (2026-08-10): Mentis pasa a tener cuatro modos (Mentis, Code, Designe, Cowork).
# Un modo no es una app aparte: es el mismo Mentis con una parte de sus capacidades a la vista.
# Esta libreria es el unico lugar que sabe traducir "estoy en modo Designe" a "estas son las
# banderas y estas son las herramientas apagadas".
#
# DONDE ENCAJA EN LO QUE YA HABIA: mentis-chat.sh ya tenia un precedente exacto de esto -- el modo
# remoto (-R) del telefono, que reescribe la persona y le saca escribir, ejecutar, pantalla y
# camara. Aquello funciona hace semanas. Esto lo generaliza en vez de inventar un mecanismo nuevo
# al lado.
#
# LA REGLA QUE NO SE ROMPE: **un modo solo puede QUITAR**. Los permisos siguen saliendo de los
# conectores que el usuario prende en la app y de las banderas del proceso; el modo se aplica encima y
# solo apaga. Si el conector de la camara esta apagado, ningun modo la enciende. Hay un test que
# lo verifica (tests/test-modos.sh) porque es la clase de invariante que se rompe sin que falle
# nada visible.
#
# NADA DE jq: no viene con Git Bash (ERR-001). Todo el JSON se lee con node, que si esta.

NVMODOS_RAIZ="${MENTIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NVMODOS_JSON="$NVMODOS_RAIZ/modos.json"
NVMODOS_ESTADO="$NVMODOS_RAIZ/state.json"

# Lector generico. Devuelve vacio y codigo 1 si algo no esta -- nunca rompe al que llama, porque
# quedarse sin modo tiene que degradar a "el modo por defecto", no a "Mentis no arranca".
_nvmodos_node() {
  local guion="$1"
  [ -f "$NVMODOS_JSON" ] || return 1
  MODOS_JSON="$NVMODOS_JSON" node -e "
    const fs = require('fs');
    let d;
    try { d = JSON.parse(fs.readFileSync(process.env.MODOS_JSON, 'utf8')); }
    catch (e) { process.exit(1); }
    $guion
  " 2>/dev/null
}

# ---------------------------------------------------------------------------------------------
# nv_modo_valido <id>   -> 0 si ese modo existe
nv_modo_valido() {
  [ -n "${1:-}" ] || return 1
  MODO_ID="$1" _nvmodos_node 'process.exit(d.modos[process.env.MODO_ID] ? 0 : 1)'
}

# nv_modo_por_defecto   -> el id del modo de fabrica
nv_modo_por_defecto() {
  _nvmodos_node 'process.stdout.write(d.por_defecto || "mentis")' || echo "mentis"
}

# nv_modo_actual        -> el modo elegido, o el de fabrica si no hay ninguno guardado.
#
# El orden importa: la variable de entorno gana sobre el archivo. Eso es lo que deja probar un
# modo puntual (MENTIS_MODO=code...) sin cambiarle el modo a la conversacion del usuario, y es como
# lo usan los tests.
nv_modo_actual() {
  local m="${MENTIS_MODO:-}"
  if [ -z "$m" ] && [ -f "$NVMODOS_ESTADO" ]; then
    m="$(ESTADO="$NVMODOS_ESTADO" node -e '
      const fs = require("fs");
      try { const s = JSON.parse(fs.readFileSync(process.env.ESTADO, "utf8"));
            process.stdout.write(String(s.modo || "")); } catch (e) {}
    ' 2>/dev/null)"
  fi
  if nv_modo_valido "$m"; then printf '%s' "$m"; else nv_modo_por_defecto; fi
}

# nv_modo_titulo <id>   -> "Mentis Code". Es lo que se ve en el logotipo del header.
nv_modo_titulo() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID];
    process.stdout.write(m ? (m.titulo || process.env.MODO_ID) : "Mentis")'
}

# nv_modo_persona <id>  -> el parrafo que se le suma al prompt del sistema.
nv_modo_persona() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID];
    process.stdout.write(m && m.persona ? m.persona : "")'
}

# nv_modo_reparto <id> -> "1" si este modo arranca REPARTIENDO el trabajo en paralelo.
#
# Es una clave propia del modo ("reparto": true) y no se deduce de tener la herramienta
# 'parallel': el modo Code tambien la tiene, y meterle una llamada de planificacion a cada turno
# de codigo lo haria mas lento sin motivo -- un fix de una linea no se parte en pedazos. Que sea
# explicito ademas deja el criterio a la vista en modos.json, que es donde el usuario lo va a buscar.
nv_modo_reparto() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    process.stdout.write(m.reparto ? "1" : "0")'
}

# nv_modo_tablero <id> -> "1" si este modo dibuja el TABLERO DE TAREAS del turno.
#
# Clave propia ("tablero": true) por el mismo motivo que reparto: cuesta una llamada corta por
# turno, asi que lo declara el modo que la quiere en vez de heredarla todo el mundo.
nv_modo_tablero() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    process.stdout.write(m.tablero ? "1" : "0")'
}

# nv_modo_banderas <id> -> "-b -g -K -w -e" : las banderas que ESTE modo habilita.
#
# Son nucleo + las del modo + (las invasivas, si el modo las tiene). Quien llama tiene que
# INTERSECTARLAS con lo que ya permitian los conectores, nunca usarlas tal cual: ver la regla de
# "un modo solo puede quitar" arriba.
# `banderas_fuera` es el gemelo de herramientas_fuera para las banderas, y existe por la interfaz:
# el boton de una capacidad se ve si y solo si el modo tiene su bandera, asi que apagar la
# herramienta sin apagar la bandera le deja al usuario el boton de navegar prendido en el unico modo
# que no navega. Tambien resta al final y solo quita.
nv_modo_banderas() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    let b = (d.nucleo.banderas || []).concat(m.banderas || []);
    if (m.invasivas) b = b.concat(d.invasivas.banderas || []);
    const fuera = new Set(m.banderas_fuera || []);
    process.stdout.write([...new Set(b)].filter((x) => !fuera.has(x)).join(" "))'
}

# nv_modo_sin_tools <id> -> "exec,git,lsp,delegate,..." : lo que hay que APAGAR en este modo.
#
# Se calcula por resta y no por lista: todo lo del catalogo que no este en ningun anillo del modo
# queda apagado. Asi, el dia que se agregue una herramienta nueva al motor, el default es que NO
# aparezca en los modos que no la declararon -- que es el default seguro. Al reves (lista de
# prohibidas) una herramienta nueva se colaria en los cuatro modos sin que nadie lo decida.
#
# `herramientas_fuera` (2026-08-12): la resta de arriba solo puede apagar lo que NO es nucleo,
# porque el nucleo se suma antes de restar. Study lo necesita: es un modo de CORPUS CERRADO y
# 'browse' vive en el anillo 0, asi que hasta hoy podia salir a Internet a buscar lo que le
# faltara -- y citar como fuente del usuario algo que el usuario nunca le dio.
#
# POR QUE ESTO NO ROMPE LA INVARIANTE: se aplica al FINAL y solo sabe AGREGAR a la lista de
# apagadas (`fuera`). No hay ninguna rama en la que saque algo de esa lista, que es la unica
# forma en que un modo podria terminar encendiendo una herramienta. Poner aca una herramienta
# que el modo tampoco tenia es un no-op, no un permiso. Tiene su propio test en test-modos.sh.
nv_modo_sin_tools() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    let tiene = new Set((d.nucleo.herramientas || []).concat(m.herramientas || []));
    if (m.invasivas) for (const t of (d.invasivas.herramientas || [])) tiene.add(t);
    const fuera = new Set((d._todas_las_herramientas || []).filter((t) => !tiene.has(t)));
    for (const t of (m.herramientas_fuera || [])) fuera.add(t);
    process.stdout.write([...fuera].join(","))'
}

# nv_modo_corpus <id> -> ruta ABSOLUTA de la carpeta cuyo indice semantico reemplaza a Kai Vault
# en ese modo, o vacio si el modo no tiene corpus propio (que es el caso de todos menos Study).
#
# Existe porque el lookup de Kai Vault corre en CADA turno y para TODOS los modos por igual
# (mentis-chat.sh). En un modo de corpus cerrado eso mete el codigo de Mentis adentro del prompt
# rotulado como fuente, que es exactamente lo que Study promete no hacer.
nv_modo_corpus() {
  local rel
  rel="$(MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    process.stdout.write(m.corpus || "")')"
  [ -n "${rel// }" ] || return 1
  case "$rel" in
    /*|[A-Za-z]:*) printf '%s' "$rel" ;;
    *)             printf '%s/%s' "$NVMODOS_RAIZ" "$rel" ;;
  esac
}

# _mc_banderas_libres -> las banderas que el modo NO gobierna y por lo tanto nunca filtra.
# Viven en modos.json para que la decision este declarada en un solo lugar y no escondida en un
# `case` de bash.
_mc_banderas_libres() {
  _nvmodos_node 'process.stdout.write((d.banderas_que_el_modo_no_gobierna || []).join(" "))'
}

# nv_modo_capacidades <id> -> "recall where recordar plan architecture..."
nv_modo_capacidades() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    const c = (d.nucleo.capacidades || []).concat(m.capacidades || []);
    process.stdout.write([...new Set(c)].join(" "))'
}

# nv_modo_paneles <id> -> "projects schedule directory" : que botones de la app se ven.
# Se calcula igual que las herramientas -- nucleo + modo -- para que la interfaz y el motor no
# puedan contar historias distintas sobre el mismo modo.
nv_modo_paneles() {
  MODO_ID="${1:-mentis}" _nvmodos_node '
    const m = d.modos[process.env.MODO_ID] || {};
    const p = ((d.paneles || {}).nucleo || []).concat(m.paneles || []);
    process.stdout.write([...new Set(p)].join(" "))'
}

# nv_modo_lista -> "id<TAB>titulo<TAB>descripcion" por linea. Lo consume el selector de la app y
# la pagina del celular, para que no haya dos listas de modos que puedan quedar distintas.
nv_modo_lista() {
  _nvmodos_node '
    const out = Object.entries(d.modos).map(([id, m]) =>
      [id, m.titulo || id, m.descripcion || "", m.letra || "", m.acento || "medio"].join("\t"));
    process.stdout.write(out.join("\n"))'
}

# nv_modo_guardar <id> -> deja elegido ese modo para las proximas veces.
#
# Se reescribe el state.json ENTERO con node en vez de parchear el texto con sed: es un archivo
# que tocan varios procesos y un sed sobre JSON lo rompe el dia que aparece una clave con una
# llave adentro de un string.
nv_modo_guardar() {
  local m="${1:-}"
  nv_modo_valido "$m" || { echo "modo desconocido: $m" >&2; return 1; }
  ESTADO="$NVMODOS_ESTADO" MODO_ID="$m" node -e '
    const fs = require("fs");
    const p = process.env.ESTADO;
    let s = {};
    try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { s = {}; }
    s.modo = process.env.MODO_ID;
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' || return 1
  printf '%s' "$m"
}

# nv_study_sugerencia <modo> <mensaje_de_juan> <respuesta_final>
#   -> imprime la linea que hay que pegarle al final de la respuesta, o nada (codigo 1).
#
# POR QUE EXISTE (2026-08-15): los nueve formatos de /material se ofrecian UNICAMENTE desde la
# persona del modo Study ("Ofrecele el que le sirva... y decile la linea exacta"). En uso real
# aparecia a veces si y a veces no, que es lo que pasa siempre que una funcion del producto
# depende de que el modelo se acuerde. Es la misma leccion que ya esta escrita dos veces en este
# repositorio -- la camara y el reparto de Cowork -- y que modos.json resume asi: "una defensa
# redactada como instruccion es una sugerencia".
#
# POR QUE ES UN GREP Y NO UNA LLAMADA A UN MODELO: preguntarle a un modelo chico que formato
# corresponde cuesta una llamada por turno de Study para adornar una respuesta que YA esta lista
# y esperando. Ese es exactamente el gasto que se saco del verificador (138 s de mediana con la
# respuesta escrita del otro lado). Contra una lista de frases cuesta milisegundos.
#
# LAS CUATRO CONDICIONES (las cuatro, o no se agrega nada) estan explicadas en
# study-sugerencias.json. La tercera es la que no es obvia: si la respuesta YA menciona
# /material, no se agrega nada. Repetirlo seria ruido y ademas delataria la costura -- el usuario
# leeria dos ofrecimientos del mismo formato, uno escrito por el modelo y otro pegado por el
# motor, y sabria que hay una maquina atras adivinando.
#
# Apagado: MENTIS_SUGERENCIA_OFF=1.
NVMODOS_SUGERENCIAS="${MENTIS_SUGERENCIAS_JSON:-$NVMODOS_RAIZ/study-sugerencias.json}"

nv_study_sugerencia() {
  local modo="${1:-}" msg="${2:-}" resp="${3:-}"
  [ "${MENTIS_SUGERENCIA_OFF:-0}" = "1" ] && return 1
  [ "$modo" = "study" ] || return 1
  [ -f "$NVMODOS_SUGERENCIAS" ] || return 1

  # Condicion 2: que haya material cargado. Ofrecerle convertir un corpus vacio lo manda contra
  # una pared -- /material le contestaria "de ese tema no hay nada", y el ofrecimiento habria
  # salido del propio Mentis. Se mira que exista AL MENOS UN archivo, no que la carpeta exista:
  # knowledge/estudio se crea sola la primera vez que se abre el modo.
  local corpus
  corpus="$(nv_modo_corpus "$modo" 2>/dev/null)" || return 1
  [ -d "$corpus" ] || return 1
  find "$corpus" -type f -print -quit 2>/dev/null | grep -q. || return 1

  # El mensaje y la respuesta viajan por ENTORNO y no como argumentos del -e. Es deliberado:
  # meter texto del usuario adentro del cuerpo de un script es la familia de errores de ERR-159 (los
  # escapes se colapsan al armar el codigo), y aca el texto puede traer comillas, backslashes y
  # saltos de linea. Por entorno llegan literales, sin que nadie los interprete.
  SUG_JSON="$NVMODOS_SUGERENCIAS" SUG_MSG="$msg" SUG_RESP="$resp" node -e '
    const fs = require("fs");
    // Sin acentos y en minusculas de los dos lados: el usuario escribe "presentación" y "presentacion"
    // el mismo dia, y una regla que solo matchea una de las dos es una regla rota la mitad de
    // las veces.
    const norm = (s) => (s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    if (norm(process.env.SUG_RESP).includes("/material")) process.exit(1);
    let d;
    try { d = JSON.parse(fs.readFileSync(process.env.SUG_JSON, "utf8")); } catch (e) { process.exit(1); }
    const msg = norm(process.env.SUG_MSG);
    for (const r of (d.reglas || [])) {
      if ((r.frases || []).some((f) => f && msg.includes(norm(f)))) {
        process.stdout.write(String(r.linea || ""));
        process.exit(r.linea ? 0 : 1);
      }
    }
    process.exit(1);
  ' 2>/dev/null
}

# Uso desde la linea de comandos, para poder mirarlo sin escribir un script:
#   bash engine/nv-modos-lib.sh actual|lista|banderas <id>|sin-tools <id>|titulo <id>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-actual}" in
    actual)       nv_modo_actual; echo ;;
    lista)        nv_modo_lista; echo ;;
    titulo)       nv_modo_titulo "${2:-$(nv_modo_actual)}"; echo ;;
    persona)      nv_modo_persona "${2:-$(nv_modo_actual)}"; echo ;;
    banderas)     nv_modo_banderas "${2:-$(nv_modo_actual)}"; echo ;;
    sin-tools)    nv_modo_sin_tools "${2:-$(nv_modo_actual)}"; echo ;;
    capacidades)  nv_modo_capacidades "${2:-$(nv_modo_actual)}"; echo ;;
    paneles)      nv_modo_paneles "${2:-$(nv_modo_actual)}"; echo ;;
    corpus)       nv_modo_corpus "${2:-$(nv_modo_actual)}"; echo ;;
    guardar)      nv_modo_guardar "${2:-}"; echo ;;
    *) echo "uso: nv-modos-lib.sh actual|lista|titulo|persona|banderas|sin-tools|capacidades|paneles|corpus|guardar <id>" >&2; exit 64 ;;
  esac
fi
