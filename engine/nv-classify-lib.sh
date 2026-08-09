# nv-classify-lib.sh — heuristica de clasificacion, extraida a lib reusable
# (Fase 5 de Mentis, 2026-07-12) para que mentis-chat.sh pueda clasificar cada mensaje sin
# duplicar la logica ni depender del resto de nv.sh (dispatch, flags de archivos, etc.).
#
# Uso:
#   source nv-classify-lib.sh
#   read -r TIPO MODE LANG CONF <<< "$(nv_classify_msg "$MSG" "$HASFILES")"
#
# TIPO: code|reason|extract|search|general|multimodal|trivial
# MODE: simple|verify|ensemble
# LANG: python|node|bash|none
# CONF: alta|baja (si baja, quien llama puede desempatar con un modelo si quiere)
#
# ============================================================================================
# POR QUE ESTO ES BASH PURO Y NO PYTHON (2026-07-30, pedido del usuario: "mas velocidad en el modo
# rapido"). Medido en esta maquina, no supuesto:
#
#     clasificador anterior (python3 -c)....... 515 / 613 / 675 ms
#     arranque PELADO de python3 (import nada). 475 ms
#     spawn de CUALQUIER proceso (grep, awk)... ~75 ms
#     bash puro, cero procesos................. ~0 ms
#
# O sea: el 80% de lo que tardaba el "cerebro rapido" era arrancar el interprete, y se pagaba
# en CADA mensaje, ANTES de hablar con ningun modelo. Con 75 ms por proceso, ni grep ni un
# servidor auxiliar entran en el presupuesto: la unica salida es no crear procesos.
#
# Se conserva la version python como nv_classify_msg_ref() -- no se usa en produccion, es la
# REFERENCIA contra la que tests/test-clasificador.sh compara caso por caso. Si alguna vez se
# toca la heuristica, hay que tocar las DOS y el test avisa si se separaron.
#
# TRAMPAS DE ESTA MAQUINA que condicionan como esta escrito (verificadas):
#   - bash aca NO soporta \b en [[ =~ ]] (es MSYS). Las fronteras de palabra se simulan con
#     (^|[^a-z0-9_]) y ([^a-z0-9_]|$).
#   - bash trabaja por BYTES: "funcion" con tilde son 2 bytes y [[:alnum:]] no los reconoce como
#     letra, asi que una clase tipo [oó] dentro de un regex se rompe. Por eso los acentos se
#     sacan ANTES (con expansion de parametros, sin procesos) y todos los patrones son ASCII.
#   - por lo mismo, un caracter multibyte que quiera hacerse OPCIONAL hay que agruparlo: "¿?" no
#     significa "un ¿ opcional" sino "el SEGUNDO byte de ¿ opcional", dejando el primero
#     obligatorio -- y entonces "que es un decorator?" dejaba de entrar por la rama de preguntas.
#     Se escribe "(¿)?". (Lo encontro el test comparando contra la referencia, 2026-07-30.)
# ============================================================================================
#
# "trivial" (agregado 2026-07-16, pedido del usuario, "cerebro rapido"): saludos/agradecimientos/
# confirmaciones SIN necesidad de herramientas ni razonamiento -- matchea el mensaje COMPLETO
# (normalizado, sin puntuacion) contra una lista cerrada, NO un prefijo. Un prefijo tipo "^hola"
# + limite de palabras suena razonable pero ATRAPA mensajes reales cortos ("hola, implementame
# una funcion en python" son 6 palabras y matcheaba "trivial" en la primera version de esto,
# real bug encontrado probando antes de wirear -- ver bitacora). Precision por sobre recall:
# mejor un saludo real que no se detecta como trivial (pierde algo de velocidad, cero riesgo)
# que un pedido real que se manda por error a un modelo chico (pierde calidad, eso si importa).

# --- normalizacion (cero procesos) -----------------------------------------------------------
# Baja a minusculas y saca acentos. ${s,} solo sabe de ASCII en este bash (modo byte), asi que
# las mayusculas acentuadas se resuelven a mano en la misma tabla.
#
# OJO con como devuelven el resultado estas dos (medido, 2026-07-30): la primera version hacia
# m="$(_nv_norm "$msg")", y esa forma forkea un SUBSHELL. Dos subshells por mensaje costaban
# 45 ms de los 45 ms totales -- o sea TODO el tiempo restante era eso, no el trabajo. Devolviendo
# por variable global (NV__M / NV__MW) no se crea ningun proceso y queda en ~1 ms. Es la misma
# leccion que el arranque de python, una escala mas abajo: en Windows lo caro es crear procesos.
_nv_norm() {   # -> NV__M
  local s="${1,}"
  s="${s//á/a}"; s="${s//à/a}"; s="${s//ä/a}"; s="${s//â/a}"; s="${s//Á/a}"; s="${s//À/a}"; s="${s//Ä/a}"; s="${s//Â/a}"
  s="${s//é/e}"; s="${s//è/e}"; s="${s//ë/e}"; s="${s//ê/e}"; s="${s//É/e}"; s="${s//È/e}"; s="${s//Ë/e}"; s="${s//Ê/e}"
  s="${s//í/i}"; s="${s//ì/i}"; s="${s//ï/i}"; s="${s//î/i}"; s="${s//Í/i}"; s="${s//Ì/i}"; s="${s//Ï/i}"; s="${s//Î/i}"
  s="${s//ó/o}"; s="${s//ò/o}"; s="${s//ö/o}"; s="${s//ô/o}"; s="${s//Ó/o}"; s="${s//Ò/o}"; s="${s//Ö/o}"; s="${s//Ô/o}"
  s="${s//ú/u}"; s="${s//ù/u}"; s="${s//ü/u}"; s="${s//û/u}"; s="${s//Ú/u}"; s="${s//Ù/u}"; s="${s//Ü/u}"; s="${s//Û/u}"
  s="${s//ñ/n}"; s="${s//Ñ/n}"
  s="${s//ç/c}"; s="${s//Ç/c}"
  NV__M="$s"
}

# Deja SOLO palabras separadas por un espacio: "¿Cómo estás?" -> "como estas".
# Equivale al " ".join(re.findall(r"\w+",...)) del original.
_nv_solo_palabras() {   # -> NV__MW
  local w="${1//[!a-z0-9_]/ }"
  while [[ "$w" == *"  "* ]]; do w="${w//  / }"; done
  w="${w# }"; w="${w% }"
  NV__MW="$w"
}

# ¿alguno de estos patrones aparece en el mensaje ya normalizado (NV__M)?
# Definida UNA vez y no adentro del clasificador: redefinirla en cada llamada tambien se paga.
_nv_hay() {
  local _p
  for _p in "$@"; do [[ "$NV__M" =~ $_p ]] && return 0; done
  return 1
}

# --- lista cerrada de mensajes triviales -----------------------------------------------------
# Se arma UNA sola vez al hacer source, no en cada llamada.
#
# OJO: las claves van YA normalizadas (sin acentos). El original guardaba "hasta mañana" con eñe
# y comparaba contra un texto al que le habia sacado los acentos ("hasta manana"), asi que esa
# entrada NUNCA podia matchear -- era codigo muerto. Se arregla en las dos implementaciones a la
# vez para que sigan coincidiendo (bug real encontrado el 2026-07-30 al reescribir esto).
declare -gA NV_TRIVIAL 2>/dev/null || declare -A NV_TRIVIAL
_nv_cargar_trivial() {
  local f
  for f in \
    "hola" "holaa" "holaaa" "hola mentis" "buenas" "buen dia" "buenos dias" "buenas tardes" \
    "buenas noches" "gracias" "muchas gracias" "gracias totales" "dale" "dale gracias" \
    "gracias dale" "ok" "okay" "oka" "dale ok" "listo" "genial" "genial gracias" "perfecto" \
    "perfecto gracias" "buenisimo" "buenisima" "joya" "de nada" "chau" "nos vemos" "todo bien" \
    "como andas" "como estas" "como va" "como andas vos" "si" "no" "bien" "dale perfecto" \
    "gracias mentis" "mil gracias" "muchisimas gracias" "te agradezco" "gracias por todo" \
    "buenisimo gracias" "joya gracias" "genial mentis" "excelente" "excelente gracias" \
    "impecable" "barbaro" "de diez" "tal cual" "exacto" "exactamente" "correcto" \
    "dale dale" "ok dale" "va" "vamos" "obvio" "claro" "claro que si" "por supuesto" \
    "esta bien" "estaria bien" "me parece bien" "de acuerdo" "sale" "hecho" "confirmado" \
    "si por favor" "no gracias" "no por ahora" "despues vemos" "mas tarde" \
    "hey" "holis" "que tal" "que hacer" "buen finde" "buen fin de semana" "hasta luego" \
    "hasta manana" "nos hablamos" "me voy" "ya vuelvo" "ahi vuelvo" "chau mentis" \
    "buenas noches mentis" "que descanses" \
    "jaja" "jajaja" "jeje" "uh" "uy" "ah" "ahh" "ahi va" "mira vos" "no puede ser" \
    "increible" "que bueno" "que grande" "bien ahi"; do
    NV_TRIVIAL["$f"]=1
  done
}
_nv_cargar_trivial

# --- clasificador -----------------------------------------------------------------------------
# Version que NO imprime: deja el resultado en NV_TIPO/NV_MODE/NV_LANG/NV_CONF. Es la que conviene
# usar desde el chat, porque capturar la salida con $(...) vuelve a costar un subshell (~26 ms).
nv_classify_msg_vars() {
  local msg="$1" hasfiles="${2:-0}"
  local tipo=none mode=none lang=none conf=alta
  _nv_norm "$msg"
  _nv_solo_palabras "$NV__M"
  local mw="$NV__MW"

  # Fronteras de palabra simuladas (bash de esta maquina no tiene \b).
  local B='(^|[^a-z0-9_])' E='([^a-z0-9_]|$)'

  if   _nv_hay "${B}python${E}" "${B}py${E}"; then lang=python
  elif _nv_hay "${B}node${E}" "${B}javascript${E}" "${B}js${E}" "${B}typescript${E}" "${B}ts${E}"; then lang=node
  elif _nv_hay "${B}bash${E}" "${B}shell${E}" "${B}sh${E}" "${B}script de shell${E}"; then lang=bash
  fi

  if [[ -n "${NV_TRIVIAL[$mw]:-}" ]]; then
    tipo=trivial; mode=simple

  elif _nv_hay "${B}busc" "${B}donde (esta|se )" "${B}encontr" "${B}en que archivo" "${B}ubic" \
       && _nv_hay "(proyecto|codigo|repo|archivos?)"; then
    tipo=search; mode=simple

  elif [ "${hasfiles:-0}" -gt 0 ] 2>/dev/null; then
    tipo=extract; mode=simple

  elif _nv_hay "${B}funcion(es)?${E}" "${B}implement" "${B}escribi.*codigo" "${B}program" \
            "${B}algoritmo" "${B}script${E}" "${B}regex${E}" "${B}query sql${E}" "codigo (para|que)" \
       || { _nv_hay "${B}clase${E}" "${B}metodo${E}" \
            && { [ "$lang" != none ] || _nv_hay "objeto" "atributo" "herencia" "instanci" "${B}oop${E}"; }; }; then
    tipo=code
    if _nv_hay "${B}implement" "${B}funcion(es)?${E}" "escrib" "${B}program" "${B}algoritmo" \
            "${B}clase${E}" "devuelv" "retorn" "calcul" "${B}orden" "parse"; then mode=verify; else mode=simple; fi
    [ "$lang" = none ] && lang=python

  elif { [[ "$NV__M" == *"?"* ]] || _nv_hay "^[[:space:]]*(¿)?[[:space:]]*(que|como|cual|cuando|para que|diferencia|sirve|signific)${E}"; } \
       && { [ "$lang" != none ] \
            || _nv_hay "async" "await" "decorator" "closure" "promise" "callback" "regex" "${B}json${E}" \
                    "lambda" "iterador" "generador" "polimorf" "herencia" "recursion" "puntero" \
                    "${B}array${E}" "framework" "libreria" "endpoint" "${B}api${E}" "compilador" \
                    "sintaxis" "${B}thread" "concurren" "mutex" "semaforo" "big[ -]?o" "stack trace" \
                    "excepcion" "middleware" "${B}hash${E}" "orientad[ao] a objetos" "${B}oop${E}" \
                    "webhook" "${B}n8n${E}" "workflow" "${B}rest${E}" "${B}http${E}" \
                    "${B}nodo${E}.*n8n" "n8n.*${B}nodo${E}"; }; then
    tipo=code; mode=simple
    [ "$lang" = none ] && lang=python

  elif _nv_hay "${B}cuant" "probabil" "demostr" "${B}optim" "convien" "mejor opci" "estrateg" \
            "trade-?off" "compar" "decid" "elegir entre" "analiz.*fondo" "por que" "justific" "${B}demuestr"; then
    tipo=reason
    if _nv_hay "cuant" "probabil" "demostr" "${B}demuestr" \
       || { _nv_hay "compar" "elegir entre" "trade-?off" "${B}vs${E}" "versus" \
            && _nv_hay "convien" "mejor" "opci" "alternativ"; }; then mode=ensemble; else mode=simple; fi

  elif _nv_hay "${B}imagen" "${B}foto" "${B}video" "${B}visual${E}" "${B}diagrama.*imagen"; then
    tipo=multimodal; mode=simple

  else
    conf=baja; tipo=general; mode=simple
  fi

  NV_TIPO="$tipo"; NV_MODE="$mode"; NV_LANG="$lang"; NV_CONF="$conf"
}

# Envoltorio que imprime, para no romper a quien ya la usaba asi (y para los tests). Cuesta un
# subshell del lado del que llama; si te importan los milisegundos, usa nv_classify_msg_vars.
nv_classify_msg() {
  nv_classify_msg_vars "$1" "${2:-0}"
  printf '%s %s %s %s\n' "$NV_TIPO" "$NV_MODE" "$NV_LANG" "$NV_CONF"
}

# --- REFERENCIA (no se usa en produccion) ------------------------------------------------------
# La implementacion original en python. Queda para que tests/test-clasificador.sh pueda comparar
# caso por caso contra la version rapida. Si las dos dejan de coincidir, el test lo grita.
nv_classify_msg_ref() {
  local msg="$1" hasfiles="${2:-0}"
  NVH_MSG="$msg" NVH_HASFILES="$hasfiles" python3 -c '
import os,re,unicodedata
m=os.environ["NVH_MSG"].lower(); hasfiles=int(os.environ["NVH_HASFILES"])>0
def has(*ws): return any(re.search(w,m) for w in ws)
def _sin_acentos(s): return "".join(c for c in unicodedata.normalize("NFKD",s) if not unicodedata.combining(c))
tipo=mode=lang="none"; conf="alta"
if has(r"\bpython\b",r"\bpy\b"): lang="python"
elif has(r"\bnode\b",r"\bjavascript\b",r"\bjs\b",r"\btypescript\b",r"\bts\b"): lang="node"
elif has(r"\bbash\b",r"\bshell\b",r"\bsh\b",r"\bscript de shell\b"): lang="bash"
TRIVIAL_EXACT={
    "hola","holaa","holaaa","hola mentis","buenas","buen dia","buenos dias","buenas tardes",
    "buenas noches","gracias","muchas gracias","gracias totales","dale","dale gracias",
    "gracias dale","ok","okay","oka","dale ok","listo","genial","genial gracias","perfecto",
    "perfecto gracias","buenisimo","buenisima","joya","de nada","chau","nos vemos","todo bien",
    "como andas","como estas","como va","como andas vos","si","no","bien","dale perfecto",
    "gracias mentis","mil gracias","muchisimas gracias","te agradezco","gracias por todo",
    "buenisimo gracias","joya gracias","genial mentis","excelente","excelente gracias",
    "impecable","barbaro","de diez","tal cual","exacto","exactamente","correcto",
    "dale dale","ok dale","va","vamos","obvio","claro","claro que si","por supuesto",
    "esta bien","estaria bien","me parece bien","de acuerdo","sale","hecho","confirmado",
    "si por favor","no gracias","no por ahora","despues vemos","mas tarde",
    "hey","holis","que tal","que hacer","buen finde","buen fin de semana","hasta luego",
    "hasta mañana","nos hablamos","me voy","ya vuelvo","ahi vuelvo","chau mentis",
    "buenas noches mentis","que descanses",
    "jaja","jajaja","jeje","uh","uy","ah","ahh","ahi va","mira vos","no puede ser",
    "increible","que bueno","que grande","bien ahi",
}
# Las claves se normalizan igual que el mensaje: sin esto, "hasta mañana" era codigo muerto
# (el mensaje llegaba como "hasta manana" y jamas coincidia). Ver el comentario en la version
# de bash -- el arreglo va en las dos a la vez para que sigan siendo comparables.
TRIVIAL_EXACT={_sin_acentos(t) for t in TRIVIAL_EXACT}
msg_norm=_sin_acentos(" ".join(re.findall(r"\w+",m)))
if msg_norm in TRIVIAL_EXACT:
    tipo="trivial"; mode="simple"
elif has(r"\bbusc",r"\bd[oó]nde (est[aá]|se )",r"\bencontr",r"\ben qu[eé] archivo",r"\bubic") and has(r"proyecto|codigo|repo|c[oó]digo|archivos?"):
    tipo="search"; mode="simple"
elif hasfiles:
    tipo="extract"; mode="simple"
elif has(r"\bfunci[oó]n(es)?\b",r"\bimplement",r"\bescrib[ií].*c[oó]digo",r"\bprogram",r"\balgoritmo",r"\bscript\b",r"\bregex\b",r"\bquery sql\b",r"c[oó]digo (para|que)") \
     or (has(r"\bclase\b",r"\bm[eé]todo\b") and (lang!="none" or has(r"objeto",r"atributo",r"herencia",r"instanci",r"\boop\b"))):
    tipo="code"
    mode="verify" if has(r"\bimplement",r"\bfunci[oó]n(es)?\b",r"escrib",r"\bprogram",r"\balgoritmo",r"\bclase\b",r"devuelv",r"retorn",r"calcul",r"\borden",r"parse") else "simple"
    if lang=="none": lang="python"
elif (has(r"\?") or has(r"^\s*¿?\s*(qu[eé]|c[oó]mo|cu[aá]l|cu[aá]ndo|para qu[eé]|diferencia|sirve|signific)\b")) and (lang!="none" or has(r"async",r"await",r"decorator",r"closure",r"promise",r"callback",r"regex",r"\bjson\b",r"lambda",r"iterador",r"generador",r"polimorf",r"herencia",r"recursi[oó]n",r"puntero",r"\barray\b",r"framework",r"librer[ií]a",r"endpoint",r"\bapi\b",r"compilador",r"sintaxis",r"\bthread",r"concurren",r"mutex",r"sem[aá]foro",r"big[ -]?o",r"stack trace",r"excepci[oó]n",r"middleware",r"\bhash\b",r"orientad[ao] a objetos",r"\boop\b",r"webhook",r"\bn8n\b",r"workflow",r"\brest\b",r"\bhttp\b",r"\bnodo\b.*n8n",r"n8n.*\bnodo")):
    tipo="code"; mode="simple"
    if lang=="none": lang="python"
elif has(r"\bcu[aá]nt",r"probabil",r"demostr",r"\boptim",r"convien",r"mejor opci",r"estrateg",r"trade-?off",r"compar",r"decid",r"elegir entre",r"analiz.*fondo",r"por qu[eé]",r"justific",r"\bdemuestr"):
    tipo="reason"
    mode="ensemble" if (has(r"cu[aá]nt",r"probabil",r"demostr",r"\bdemuestr") or (has(r"compar",r"elegir entre",r"trade-?off",r"\bvs\b",r"versus") and has(r"convien",r"mejor",r"opci",r"alternativ"))) else "simple"
elif has(r"\bimagen",r"\bfoto",r"\bvideo",r"\bvisual\b",r"\bdiagrama.*imagen"):
    tipo="multimodal"; mode="simple"
else:
    conf="baja"; tipo="general"; mode="simple"
print(tipo,mode,lang,conf)
'
}
