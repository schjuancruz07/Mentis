# nv-lib.sh — libreria comun de los modelos de apoyo NVIDIA. NO ejecutable: se hace `source`.
# Centraliza lo que se repetia y lo que es fragil en Windows/MSYS (ver ERR-004),
# para que ask-nvidia.sh y los orquestadores futuros no dupliquen logica.
#
# Provee:
#   nv_winpath <ruta>        -> convierte ruta MSYS (/c/..) a Windows (C:\..) para python3 de la Store
#   nv_read_setting <clave>  -> lee env.<clave> de settings.json
#   nv_redact                -> GUARD DE PRIVACIDAD: enmascara secretos/identificadores de stdin->stdout
#   nv_log '<json-campos>'    -> TELEMETRIA: append de una linea JSONL a logs/nv.jsonl
#   nv_now_ms                -> timestamp en ms (para medir latencia)
#   nv_parse_structured      -> parsea la salida por delimitadores (contrato #11) a KEY=val en stdout
#   nv_summarize <conf>...  -> RESUMEN DETERMINISTA (#3): formatea los campos del contrato, sin modelo
#
# Principio: este archivo no imprime nada por su cuenta al hacerse source; solo define funciones.

# Bug real de la migracion (2026-07-18): quedaba hardcodeado a la carpeta vieja de antes de
# que el motor se mudara por completo a Mentis/engine (ver DOSSIER, 2026-07-17) -- eval/quality.jsonl
# se escribia/leia de ~/.claude/tools, huerfano del resto del motor. Ahora resuelve relativo a
# la propia ubicacion de este archivo (Mentis/engine), como ya hacen NVDIR en nv-agent.sh/nv-verify.sh.
NV_HOME="${NV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NV_SETTINGS="${NV_SETTINGS:-$HOME/.claude/settings.json}"
NV_LOGDIR="${NV_LOGDIR:-$NV_HOME/logs}"
NV_LOGFILE="${NV_LOGFILE:-$NV_LOGDIR/nv.jsonl}"
# Embeddings: modelo elegido MIDIENDO, no por catalogo (2026-07-26, tests/bench-embeddings.sh).
# Sobre 15 consultas reales con respuesta conocida, contra todo el codigo de Mentis:
#   nemotron-3-embed-1b   14/15 en top-3   (2048 dims, indexa en 116 s)
#   nv-embedqa-e5-v5       5/15 en top-3   (1024 dims, indexa en 73 s)
# El viejo era el que venia de antes por inercia. El indexado tarda mas con el nuevo, pero eso
# se paga una sola vez y de forma incremental; el acierto se cobra en cada consulta.
NV_EMB_MODEL="${NV_EMB_MODEL:-nvidia/nemotron-3-embed-1b}"
NV_EMB_URL="${NV_EMB_URL:-https://integrate.api.nvidia.com/v1/embeddings}"
NV_INDEXDIR="${NV_INDEXDIR:-$NV_HOME/index}"
# Presupuesto de tiempo global por invocacion (s). Sin limite practico por pedido del usuario
# (prioriza calidad de respuesta sobre velocidad) -- OJO: no usar 0 aca, budget_exceeded()
# compara "transcurrido >= NV_BUDGET" y con 0 se cumpliria de inmediato (justo lo opuesto
# a "sin limite"). Con 999999s (~11 dias) el efecto practico es "nunca se agota".
NV_BUDGET="${NV_BUDGET:-999999}"

# --- secretos: cargar API keys desde archivo dedicado (fuera de settings.json) ---
# El archivo usa ${VAR:-...} asi que respeta una env var preexistente. Si no existe,
# se cae al fallback nv_read_setting (settings.json), por retrocompatibilidad.
[ -f "$NV_HOME/.nv-secrets" ] &&. "$NV_HOME/.nv-secrets"

# === REGISTRO DE PROCESOS DE FONDO (para poder frenarlos de verdad) =============
# Bug real reportado por el usuario (computer-use, 2026-07-18): despues de "Frenar ya" seguian vivos
# procesos de fondo gastando API. La causa de raiz (ERR-034, ahora medida): la emulacion de
# fork() de MSYS deja el ParentProcessId de Windows apuntando a un PID que YA MURIO -- medido
# en vivo, el sleep de la prueba colgaba de un PPID inexistente. Por eso ni `taskkill /T` ni un
# cierre transitivo por PPID pueden encontrarlos: la cadena genealogica de Windows esta rota.
#
# La unica forma confiable es que quien los lanza los anote. nv_track_bg_pid traduce el PID de
# MSYS (el que devuelve $!) al PID REAL de Windows via /proc/<pid>/winpid -- que es el unico que
# taskkill entiende -- y lo agrega a $MENTIS_PIDFILE, que la app crea por conversacion.
# Si MENTIS_PIDFILE no esta seteado (uso desde consola, tests sueltos) no hace nada.
nv_track_bg_pid() {
  local p="${1:-}" w
  [ -n "$p" ] || return 0
  [ -n "${MENTIS_PIDFILE:-}" ] || return 0
  w="$(cat "/proc/$p/winpid" 2>/dev/null || true)"
  [ -n "$w" ] && printf '%s\n' "$w" >> "$MENTIS_PIDFILE" 2>/dev/null
  return 0
}

# --- rutas: MSYS -> Windows (el python3 de la Microsoft Store no abre /c/...) ---
nv_winpath() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p" 2>/dev/null || echo "$p"; else echo "$p"; fi
}

# --- settings.json: lee env.<clave> ---
nv_read_setting() {
  local f; f="$(nv_winpath "$NV_SETTINGS")"
  python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('env',{}).get(sys.argv[2],''))" "$f" "$1" 2>/dev/null || true
}

# --- OVERRIDE DE MODELOS POR ROL (2026-08-01) -----------------------------------------------
# La tabla rol->modelo vive hardcodeada en el case de ask-nvidia.sh. Eso esta bien como valor por
# defecto (documenta POR QUE se eligio cada modelo, con las mediciones al lado), pero convierte
# "cambiar un modelo" en "editar bash" -- y cuando un modelo se muere hay que poder cambiarlo sin
# tocar codigo, incluso de forma automatica. Este archivo es esa capa: datos, no codigo.
#
# Prioridad, de menor a mayor:   tabla del case  <  este override  <  customModels (elegido a mano)
# Lo elegido a mano por el usuario gana siempre; lo automatico solo cubre lo que el no toco.
#
# Revertir un cambio automatico = borrar una clave de este JSON. Por eso cada entrada guarda su
# "anterior": sin eso, volver atras seria adivinar.
NV_OVERRIDE_FILE="${NV_OVERRIDE_FILE:-$(cd "$NV_HOME/.." 2>/dev/null && pwd || echo "$NV_HOME")/modelos-override.json}"

# nv_override_rol <rol> -> imprime "modelo|fallback|fallback2" o nada si no hay override.
#
# RENDIMIENTO (no es un detalle): esto corre en el camino de CADA llamada al modelo, y arrancar
# python cuesta ~475 ms en esta maquina. Por eso lo primero es un test de existencia de archivo:
# mientras no haya ningun override -- que es el caso normal, un modelo se muere cada tanto, no
# todos los dias -- el costo de esta funcion es cero y el comportamiento identico al de antes.
# Cuando SI hay override se paga UN solo python que devuelve los tres valores juntos; no tres
# llamadas separadas como hace el bloque de customModels (eso cuesta ~1,4 s por turno).
# --- MEMORIA CORTA PARA CONSULTAS CARAS (2026-08-03) ---------------------------------------------
# nv_override_rol y nv_model_health arrancan un interprete de Python para leer archivos que casi
# nunca cambian. Medido con PS4/EPOCHREALTIME sobre un saludo real: 522 ms y 626 ms
# respectivamente, sobre un total de 5.098 ms. Juntos son mas que el modelo mismo en las llamadas
# rapidas.
#
# La invalidacion NO es por fecha de modificacion sino por ventana de tiempo + limpieza explicita.
# Motivo: nv_model_health lee la telemetria, y la telemetria crece en CADA llamada, asi que una
# clave por mtime se invalidaria siempre y no serviria de nada. Quien escribe un override llama a
# nv_memo_limpiar, asi que tampoco hay ventana de dato viejo despues de una edicion.
#
# EL COSTO DE LA VENTANA, DICHO CLARO: durante el TTL se puede seguir enrutando a un modelo que
# acaba de caerse. Antes eso era grave porque el timeout era de 120 s por modelo; ahora el
# presupuesto de primer token lo detecta en 12 s y cae al fallback.
#
# NI UN SOLO PROCESO EXTERNO ADENTRO. La primera version usaba `date`, `stat` y `mkdir -p` en
# cada consulta y casi se comio su propio ahorro: en MSYS cada proceso cuesta ~76 ms, asi que
# tres por consulta y tres consultas por turno son ~690 ms de "optimizacion" que se pagan solos.
# Medido: con esa version el memo ahorraba 480 ms; con builtins ahorra el ahorro entero.
#
# Como se evita cada uno:
#   date  -> $EPOCHSECONDS (builtin de bash 5).
#   stat  -> la hora de nacimiento va en el NOMBRE del archivo, y se lee con un glob.
#   mkdir -> solo si el directorio no existe (el test [ -d ] es builtin).
#   cat   -> $(<archivo) es redireccion pura, sin fork.
nv_memo_dir() {
  local d="${NV_CACHE_MEMO:-${TMPDIR:-/tmp}/mentis-memo}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$d"
}

nv_cache_ttl() {
  local clave="$1" ttl="$2"; shift 2
  local dir; dir="$(nv_memo_dir)" || { "$@"; return $?; }
  # viejo="" explicito y no solo declarado: con `set -u` (que usan ask-nvidia.sh y casi todos los
  # scripts del motor) leer una variable declarada-pero-sin-asignar aborta el script entero.
  local ahora="${EPOCHSECONDS:-0}" viejo="" f="" nacido=""
  # Un solo glob: el nombre trae la hora, asi que no hace falta preguntarle nada al sistema.
  for f in "$dir/ttl.$clave".*; do
    [ -e "$f" ] || continue
    nacido="${f##*.}"
    case "$nacido" in
      ''|*[!0-9]*) rm -f "$f" 2>/dev/null; continue ;;
    esac
    if [ $(( ahora - nacido )) -lt "$ttl" ] && [ $(( ahora - nacido )) -ge 0 ]; then
      printf '%s' "$(<"$f")"
      return 0
    fi
    viejo="$f"     # vencido: se borra despues de recalcular, no antes
  done
  local salida rc
  salida="$("$@")"; rc=$?
  [ -n "$viejo" ] && rm -f "$viejo" 2>/dev/null
  if [ $rc -eq 0 ]; then
    # Escribir y renombrar: dos turnos a la vez nunca leen un archivo a medio escribir.
    printf '%s' "$salida" > "$dir/.tmp.$$" 2>/dev/null &&
      mv -f "$dir/.tmp.$$" "$dir/ttl.$clave.$ahora" 2>/dev/null
    printf '%s' "$salida"
  fi
  return $rc
}

# nv_cache_src <clave> <archivo-fuente> <comando...>
# Para consultas cuya respuesta depende de UN archivo. Se invalida sola cuando ese archivo cambia,
# sin TTL y sin depender de que nadie se acuerde de limpiar.
#
# POR QUE HACE FALTA ADEMAS DEL TTL: el override se puede editar a mano -- de hecho asi se edito
# el 2026-08-03 -- y con un TTL de 10 minutos el cambio no se sentia. tests/test-modelos-override.sh
# lo detecto de inmediato: escribe tres overrides distintos seguidos y recibia siempre el primero.
# Un cache que sirve datos viejos despues de una edicion no es una optimizacion, es un bug.
#
# El truco para que siga sin costar procesos: `-nt` es un operador BUILTIN de bash que compara
# fechas de modificacion. No hace falta `stat` para saber si la fuente cambio; alcanza con
# preguntar si es mas nueva que el propio archivo de cache.
#
# LA CLAVE INCLUYE EL ARCHIVO FUENTE, Y NO ES UN DETALLE (2026-08-04). Antes la entrada se
# llamaba solo "src.<clave>", asi que dos procesos que consultaban la MISMA clave apuntando a
# archivos DISTINTOS compartian celda. Eso paso de verdad y en silencio:
# tests/test-modelos-override.sh consulta los roles 'reason' y 'extract' contra overrides
# temporales (incluido uno inexistente, a proposito), y mentis-mejorar.sh corre ese test en su
# rutina. El test escribio "vacio" en src.override.reason y src.override.extract del cache REAL,
# con fecha posterior a la del modelos-override.json de verdad.
#
# Como la invalidacion es por `-nt` contra la fuente, y la fuente era MAS VIEJA que el cache
# envenenado, esos vacios no vencian nunca. Desde el 2026-08-04 18:48 produccion corrio 'reason'
# y 'extract' con el modelo por default en vez del override -- justo el deepseek-v4-pro que la
# revision del 2026-08-02 habia sacado por contestar 1 de cada 3 veces. El override seguia
# escrito en el JSON, asi que al mirarlo parecia aplicado.
#
# El test que verifica que los overrides funcionan era el que los rompia.
#
# La sanitizacion es por expansion de bash (sin forks, igual que el resto del archivo) y se queda
# con los ultimos 60 caracteres: lo que distingue dos rutas casi siempre esta al final, y un
# nombre de archivo no puede crecer sin limite.
nv_cache_src() {
  local clave="$1" fuente="$2"; shift 2
  local dir; dir="$(nv_memo_dir)" || { "$@"; return $?; }
  # El truncado va CONDICIONADO a que sobre largo. `${id: -60}` sobre una cadena de menos de 60
  # caracteres NO devuelve la cadena entera: devuelve VACIO (medido en bash 5.3.15 de este MSYS,
  # ${#v}=45 -> ""). Sin el test de longitud, toda ruta corta -- o sea todas -- daba id vacio y
  # el nombre de la celda volvia a ser el de antes, con lo cual el arreglo no arreglaba nada.
  local id="${fuente//[^a-zA-Z0-9]/_}"
  [ ${#id} -gt 60 ] && id="${id: -60}"
  local f="$dir/src.$clave.$id"
  if [ -f "$f" ] && [ ! "$fuente" -nt "$f" ]; then
    printf '%s' "$(<"$f")"
    return 0
  fi
  local salida rc
  salida="$("$@")"; rc=$?
  if [ $rc -eq 0 ]; then
    printf '%s' "$salida" > "$dir/.tmp.$$" 2>/dev/null && mv -f "$dir/.tmp.$$" "$f" 2>/dev/null
    printf '%s' "$salida"
  fi
  return $rc
}

# Se vacia cuando algo cambia de verdad (por ejemplo, al escribir un override): asi el TTL no
# tiene que ser corto para tapar ediciones, y puede ser generoso.
nv_memo_limpiar() {
  local d; d="$(nv_memo_dir)" || return 0
  rm -f "$d"/ttl.* "$d"/src.* 2>/dev/null
  return 0
}
nv_override_rol() {
  local rol="$1"
  [ -n "$rol" ] || return 0
  [ -f "$NV_OVERRIDE_FILE" ] || return 0
  if [ "${NV_MEMO_OFF:-0}" != "1" ]; then
    # Por FUENTE y no por TTL: el archivo de overrides se puede editar a mano, y con una
    # ventana de tiempo ese cambio no se sentiria hasta que venza. Atado al archivo, cualquier
    # edicion invalida el cache en el acto y sin costar un solo proceso.
    nv_cache_src "override.$rol" "$NV_OVERRIDE_FILE" _nv_override_rol_real "$rol"
    return $?
  fi
  _nv_override_rol_real "$rol"
}

_nv_override_rol_real() {
  local rol="$1"
  [ -n "$rol" ] || return 0
  [ -f "$NV_OVERRIDE_FILE" ] || return 0
  NVO_ROL="$rol" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
r = (d.get("roles") or {}).get(os.environ["NVO_ROL"])
if not isinstance(r, dict):
    sys.exit(0)
m = (r.get("modelo") or "").strip()
# Sin modelo no hay override: una entrada a medias no puede dejar al rol sin nada a que llamar.
if not m:
    sys.exit(0)
print("|".join([m, (r.get("fallback") or "").strip(), (r.get("fallback2") or "").strip()]))
' "$(nv_winpath "$NV_OVERRIDE_FILE")" 2>/dev/null || true
}

# --- nv_nombre_ia ---------------------------------------------------------------------------
# Como se llama la IA para ESTA persona. Devuelve "Mentis" si no se configuro otra cosa.
#
# POR QUE EXISTE (2026-08-06): Mentis pasa a usarlo mas gente y cada uno elige el nombre. Pero el
# nombre no puede ser solo una etiqueta en la ventana: si el prompt del sistema sigue diciendo "Sos
# Mentis", la IA se va a presentar como Mentis por mas que en pantalla diga otra cosa, y esa
# contradiccion es peor que no dejar cambiarlo.
#
# Se lee de mentis-settings.json (apariencia.nombre), que es donde lo escribe la app. NO se cachea
# a proposito: se lee una vez por turno y el cambio tiene que sentirse en el turno siguiente, sin
# reiniciar nada.
nv_nombre_ia() {
  local archivo="${MENTIS_SETTINGS_FILE:-}"
  if [ -z "$archivo" ]; then
    local raiz; raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    archivo="$raiz/mentis-settings.json"
  fi
  if [ ! -f "$archivo" ]; then printf 'Mentis'; return 0; fi
  local n
  n="$(python3 -c '
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    print(((d.get("apariencia") or {}).get("nombre") or "").strip())
except Exception:
    pass
' "$(nv_winpath "$archivo" 2>/dev/null || printf '%s' "$archivo")" 2>/dev/null | tr -d '\r\n')"
  printf '%s' "${n:-Mentis}"
}

# --- nv_pide_documento <texto> --------------------------------------------------------------
# ¿Este pedido espera que se GENERE un documento? Devuelve 0 (si) o 1 (no).
#
# Vive aca y no dentro de nv-agent.sh porque una deteccion enterrada en el medio de un bucle solo
# se puede probar con grep sobre el codigo, y un test que hace grep sobre codigo pasa aunque la
# logica este mal (paso: tres tests del 2026-08-03 daban verde mirando comentarios). Como funcion
# se le pueden tirar frases y ver que contesta.
#
# Hacen falta LAS DOS cosas -- verbo de creacion y sustantivo de documento -- porque "leeme este
# pdf" o "que dice el informe" hablan de documentos sin pedir ninguno.
#
# Alternancias explicitas para los acentos: en este entorno grep compara byte a byte, asi que un
# rango tipo [eé] no matchea de forma confiable letras multibyte (mismo motivo por el que la
# guarda anti-alucinacion de nv-agent.sh escribe "(cree|creé)" en vez de "cre[eé]").
nv_pide_documento() {
  local txt="$1"
  printf '%s' "$txt" | grep -qiE "(documento|informe|word|docx|pdf|presentacion|presentación|pptx|planilla|excel|xlsx|reporte)" || return 1
  printf '%s' "$txt" | grep -qiE "(hace|hacé|haceme|hacme|arma|armá|armame|genera|generá|generame|crea|creá|creame|escribi|escribí|escribime|prepara|prepará|preparame|exporta|exportá|converti|convertí|pasa(me)? a|pasalo a)" || return 1
  return 0
}

# --- GUARD DE PRIVACIDAD (#12): enmascara antes de que NADA salga al endpoint ---
# Conservador en falsos positivos: solo patrones de alto riesgo y baja ambiguedad.
#   - claves/tokens: nvapi-, sk-, ghp_, Bearer <token>, AWS AKIA...
#   - emails
#   - identificadores fiscales/bancarios AR: CUIT/CUIL (NN-NNNNNNNN-N), CBU (22 digitos)
# Si NV_REDACT=0 se desactiva (bypass explicito con -P en el helper).
# Reporta a stderr cuantos reemplazos hizo (sin mostrar el dato), para trazabilidad.
nv_redact() {
  if [ "${NV_REDACT:-1}" = "0" ]; then cat; return 0; fi
  python3 -c '
import sys,re
# errors="replace" NO es cosmetico (bug real 2026-07-27): esta funcion esta en el camino de TODO
# lo que sale al modelo, asi que un solo byte mal codificado en cualquier archivo que termine
# dentro del prompt mataba a Mentis ENTERO. Pasaba de verdad: history.jsonl tenia tres lineas
# guardadas en cp1252 (un "¿" quedo como 0xbf suelto), python moria con UnicodeDecodeError,
# ask-nvidia devolvia vacio, y el agente reportaba "el modelo no devolvio JSON valido" -- un
# mensaje que apuntaba al modelo cuando el modelo nunca llego a ser consultado.
# Ahora un byte roto se degrada a un caracter y la conversacion sigue.
sys.stdin.reconfigure(encoding="utf-8", errors="replace")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
t=sys.stdin.read(); n=0
pats=[
 (r"nvapi-[A-Za-z0-9_\-]{8,}","[NVAPI_KEY]"),
 (r"sk-[A-Za-z0-9_\-]{12,}","[SK_KEY]"),
 (r"ghp_[A-Za-z0-9]{20,}","[GH_TOKEN]"),
 (r"AKIA[0-9A-Z]{16}","[AWS_KEY]"),
 (r"(?i)bearer\s+[A-Za-z0-9._\-]{12,}","Bearer [TOKEN]"),
 (r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}","[EMAIL]"),
 (r"\b\d{2}-\d{8}-\d\b","[CUIT]"),
 (r"\b\d{22}\b","[CBU]"),
]
for rx,rep in pats:
    t,k=re.subn(rx,rep,t); n+=k
if n: sys.stderr.write("PRIVACIDAD: %d dato(s) sensible(s) enmascarado(s) antes del envio.\n"%n)
sys.stdout.write(t)
'
}

# --- TELEMETRIA (#4): append JSONL. Recibe pares clave=valor sueltos y arma la linea.
# Uso: nv_log rol="$ROLE" modelo="$m" latencia_ms="$ms" exit="$rc" fallback="$fb" intentos="$a" veredicto=
# veredicto queda vacio -> null (el verificador no existe hasta Tanda 2).
nv_log() {
  mkdir -p "$NV_LOGDIR" 2>/dev/null || true
  NV_TS="$(date +%Y-%m-%dT%H:%M:%S%z)" python3 -c '
import json,os,sys
d={"ts":os.environ.get("NV_TS","")}
for a in sys.argv[1:]:
    if "=" not in a: continue
    k,v=a.split("=",1)
    if v=="": d[k]=None
    elif v.lower() in ("true","false"): d[k]=(v.lower()=="true")
    elif v.lstrip("-").isdigit(): d[k]=int(v)
    else: d[k]=v
print(json.dumps(d,ensure_ascii=False))
' "$@" >> "$NV_LOGFILE" 2>/dev/null || true
}

nv_now_ms() { date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))'; }

# nv_ahora_texto: fecha y hora LOCALES en castellano, listas para meter en un prompt.
# (2026-07-28) Ningun prompt de Mentis llevaba la hora -- ni el rol 'fast' ni el TASK que arma
# mentis-chat.sh. El modelo no tiene forma de saberla, asi que la INVENTA con total aplomo
# ("Son las 14:45, el usuario" cuando eran las 14:32). La ubicacion ya se inyectaba medida de verdad;
# el tiempo era el agujero que quedaba.
# Bash puro a proposito (ERR-086): un solo `date`, cero arranques de python3 (~1,5 s cada uno)
# en un camino que corre en CADA turno del chat. Los nombres de dia/mes van hardcodeados porque
# el locale es_AR no esta garantizado en Git Bash (%A/%B saldrian en ingles o vacios).
nv_ahora_texto() {
  local dias=(domingo lunes martes miercoles jueves viernes sabado)
  local meses=(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre)
  local dow d mnum y hm
  read -r dow d mnum y hm <<< "$(date '+%w %-d %-m %Y %H:%M')"
  printf '%s %s de %s de %s, %s' "${dias[$dow]}" "$d" "${meses[$((mnum-1))]}" "$y" "$hm"
}

# --- CONTRATO ESTRUCTURADO (#11): el modelo responde con secciones delimitadas (no JSON,
# para evitar escaping fragil en codigo). El system prompt vive en ask-nvidia.sh (SYS_STRUCT).
# Delimitadores: lineas exactas ===RESULTADO=== / ===CONFIANZA=== / ===SUPUESTOS=== / ===RIESGOS===
NV_DELIMS="RESULTADO CONFIANZA SUPUESTOS RIESGOS"

# nv_parse_structured: lee la respuesta cruda de stdin, imprime en stdout:
#   STRUCT_OK=1|0   (1 si encontro al menos el marcador RESULTADO)
#   y los campos como bloques entre <<<campo y campo>>> para reensamblar sin perder saltos.
# Tolerante: si no hay marcadores, devuelve STRUCT_OK=0 y todo el texto como RESULTADO.
nv_parse_structured() {
  python3 -c '
import sys,re
t=sys.stdin.read()
delims=["RESULTADO","CONFIANZA","SUPUESTOS","RIESGOS"]
# localizar cada marcador ===X===
pos={}
for d in delims:
    m=re.search(r"^[ \t]*===%s===[ \t]*$"%re.escape(d), t, re.M)
    if m: pos[d]=(m.start(),m.end())
ok = 1 if "RESULTADO" in pos else 0
fields={}
if ok:
    order=sorted(pos.items(), key=lambda kv: kv[1][0])
    for i,(d,(s,e)) in enumerate(order):
        nxt = order[i+1][1][0] if i+1 < len(order) else len(t)
        fields[d]=t[e:nxt].strip()
else:
    fields["RESULTADO"]=t.strip()
print("STRUCT_OK=%d"%ok)
for d in delims:
    v=fields.get(d,"")
    sys.stdout.write("<<<%s\n%s\n%s>>>\n"%(d,v,d))
'
}

# nv_summarize: RESUMEN DETERMINISTA (#3). No usa modelo: formatea los campos ya parseados.
# Lee de stdin la salida de nv_parse_structured. Con NV_QUIET=1 acorta RESULTADO a preview.
nv_summarize() {
  NV_QUIET="${NV_QUIET:-0}" NV_PREVIEW="${NV_PREVIEW:-12}" python3 -c '
import sys,os,re
raw=sys.stdin.read()
ok = "STRUCT_OK=1" in raw.splitlines()[0] if raw else False
fields={}
for m in re.finditer(r"<<<(\w+)\n(.*?)\n\1>>>", raw, re.S):
    fields[m.group(1)]=m.group(2)
conf=(fields.get("CONFIANZA","") or "desconocida").strip().splitlines()[0][:20]
res=fields.get("RESULTADO","").strip()
quiet=os.environ.get("NV_QUIET")=="1"
if quiet:
    lines=res.splitlines()
    pv=int(os.environ.get("NV_PREVIEW","12"))
    if len(lines)>pv:
        res="\n".join(lines[:pv])+("\n...[%d lineas mas]"%(len(lines)-pv))
print("[CONFIANZA: %s]"%conf)
print(res)
for k in ("SUPUESTOS","RIESGOS"):
    v=fields.get(k,"").strip()
    if v and v.lower() not in ("ninguno","ninguna","n/a","none","-"):
        print("\n%s: %s"%(k.capitalize(), v))
'
}

# === Tanda 2: SANDBOX DE EJECUCION (temp aislado + timeout) =====================
# nv_sandbox_run <lang> <codefile>: ejecuta el archivo en un dir temporal descartable
# con timeout duro; imprime la salida combinada (stdout+stderr, acotada) y RETORNA el
# exit code real del programa (124 = timeout). NO aisla red/FS: pensado para codigo del
# propio flujo (decision del usuario: riesgo bajo). lang: python | node | bash.
NV_SANDBOX_TO="${NV_SANDBOX_TO:-15}"     # timeout de ejecucion (s)
NV_SANDBOX_MAXOUT="${NV_SANDBOX_MAXOUT:-8000}"  # cota de bytes de salida capturada
nv_sandbox_run() {
  local lang="$1" src="$2" dir rc out ext binpath=""
  local -a run=() env_extra=()
  case "$lang" in
    python) ext=py ;;
    node|js) ext=js ;;
    bash|sh) ext=sh ;;
    *) echo "nv_sandbox_run: lenguaje no soportado: $lang" >&2; return 99 ;;
  esac
  dir="$(mktemp -d 2>/dev/null)" || { echo "nv_sandbox_run: no pude crear temp" >&2; return 98; }
  cp "$src" "$dir/prog.$ext" 2>/dev/null || { rm -rf "$dir"; return 98; }

  # --- bloqueo de red (#4 exquisito): stubs de herramientas de red al frente del PATH ---
  if [ "${NV_SANDBOX_NONET:-1}" = "1" ]; then
    mkdir -p "$dir/bin"
    local t
    for t in curl wget nc ncat ssh scp telnet; do
      printf '#!/usr/bin/env bash\necho "red bloqueada en sandbox nv-verify" >&2\nexit 1\n' > "$dir/bin/$t"
      chmod +x "$dir/bin/$t" 2>/dev/null || true
    done
    binpath="$dir/bin:"
  fi

  # --- comando por lenguaje + guard de red PRECARGADO (no concatenado -> no desplaza lineas) ---
  case "$lang" in
    python)
      run=(python3 "prog.$ext")
      if [ "${NV_SANDBOX_NONET:-1}" = "1" ]; then
        printf 'import socket\ndef _b(*a,**k): raise OSError("red bloqueada en sandbox nv-verify")\nsocket.socket=_b\nsocket.create_connection=_b\n' > "$dir/sitecustomize.py"
        env_extra=("PYTHONPATH=$dir")   # python auto-importa sitecustomize.py al arrancar
      fi ;;
    node|js)
      if [ "${NV_SANDBOX_NONET:-1}" = "1" ]; then
        printf "try{const n=require('net');n.connect=n.createConnection=()=>{throw new Error('red bloqueada en sandbox nv-verify')};}catch(e){}\ntry{const h=require('http'),s=require('https');h.request=s.request=h.get=s.get=()=>{throw new Error('red bloqueada')};}catch(e){}\n" > "$dir/netguard.js"
        run=(node --require "$dir/netguard.js" "prog.$ext")
      else
        run=(node "prog.$ext")
      fi ;;
    bash|sh)
      # chequeo de sintaxis barato antes de ejecutar (no cuenta como fallo de runtime)
      if ! bash -n "$dir/prog.$ext" 2>"$dir/synerr"; then
        out="$(head -c "$NV_SANDBOX_MAXOUT" "$dir/synerr")"; rm -rf "$dir"
        printf '%s\n' "$out"; return 2
      fi
      run=(bash "prog.$ext") ;;
  esac

  # endurecido (#4): credenciales vaciadas (el codigo no ve las keys), HOME al temp, red bloqueada.
  out="$(cd "$dir" && env NVIDIA_API_KEY= NVIDIA_API_KEY_NEMOTRON= HOME="$dir" PATH="${binpath}$PATH" "${env_extra[@]}" timeout "$NV_SANDBOX_TO" "${run[@]}" 2>&1)"; rc=$?
  out="$(printf '%s' "$out" | head -c "$NV_SANDBOX_MAXOUT")"
  rm -rf "$dir" 2>/dev/null || true
  printf '%s' "$out"
  return $rc
}

# === Tanda 3: ROUTER POR SALUD (auto-tuning desde telemetria) ====================
# nv_model_health <modelo>: mira las ultimas llamadas de ESE modelo en nv.jsonl y dice
# "ok" o "degraded". Corrige el fallo de auto-confirmacion (exploracion vs explotacion):
#   - ventana temporal: solo cuentan las ultimas NV_HEALTH_WINDOW llamadas dentro de NV_HEALTH_HOURS.
#   - REPRUEBA: si el ultimo dato del modelo es mas viejo que la ventana, devuelve "ok" (otra chance).
#   - EXPLORACION: con probabilidad NV_EXPLORE devuelve "ok" aunque este degradado (lo reprueba).
# degraded si: tasa de exito < 0.5  O  latencia mediana > NV_HEALTH_SLOWMS (timeouteando).
NV_HEALTH_WINDOW="${NV_HEALTH_WINDOW:-12}"
NV_HEALTH_HOURS="${NV_HEALTH_HOURS:-6}"
NV_HEALTH_SLOWMS="${NV_HEALTH_SLOWMS:-45000}"
NV_EXPLORE="${NV_EXPLORE:-0.2}"
nv_model_health() {
  local model="$1"
  [ -f "$NV_LOGFILE" ] || { echo ok; return 0; }
  if [ "${NV_MEMO_OFF:-0}" != "1" ]; then
    # La clave lleva el nombre del modelo saneado: dos modelos distintos no pueden pisarse.
    nv_cache_ttl "salud.$(printf '%s' "$model" | tr -c 'A-Za-z0-9._-' '_')" \
                 "${NV_HEALTH_TTL:-30}" _nv_model_health_real "$model"
    return $?
  fi
  _nv_model_health_real "$model"
}

_nv_model_health_real() {
  local model="$1"
  [ -f "$NV_LOGFILE" ] || { echo ok; return 0; }
  NVH_MODEL="$model" NVH_FILE="$NV_LOGFILE" NVH_WIN="$NV_HEALTH_WINDOW" NVH_HRS="$NV_HEALTH_HOURS" \
  NVH_SLOW="$NV_HEALTH_SLOWMS" NVH_EXP="$NV_EXPLORE" python3 -c '
import json,os,sys,time,random
from datetime import datetime
model=os.environ["NVH_MODEL"]; win=int(os.environ["NVH_WIN"]); hrs=float(os.environ["NVH_HRS"])
slow=float(os.environ["NVH_SLOW"]); exp=float(os.environ["NVH_EXP"])
now=time.time(); rows=[]
try:
    with open(os.environ["NVH_FILE"],encoding="utf-8") as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: d=json.loads(ln)
            except Exception: continue
            if d.get("modelo")!=model: continue
            ts=d.get("ts","")
            try: age=now-datetime.strptime(ts,"%Y-%m-%dT%H:%M:%S%z").timestamp()
            except Exception: age=0
            rows.append((age,d))
    rows.sort(key=lambda r:r[0])              # mas reciente primero
    recent=[d for age,d in rows[:win] if age<=hrs*3600]
    if not rows or rows[0][0]>hrs*3600:        # sin datos o ultimo muy viejo -> REPRUEBA
        print("ok"); sys.exit(0)
    if not recent:
        print("ok"); sys.exit(0)
    succ=sum(1 for d in recent if d.get("exit")==0)/len(recent)
    lats=sorted(d.get("latencia_ms") or 0 for d in recent)
    med=lats[len(lats)//2] if lats else 0
    degraded = (succ<0.5) or (med>slow)
    if degraded and random.random()<exp:       # EXPLORACION: reprueba periodica
        print("ok"); sys.exit(0)
    print("degraded" if degraded else "ok")
except Exception:
    print("ok")
'
}

# === Tanda 4: ROUTER POR CALIDAD (#3) — alimentado por nv-eval ====================
# nv_role_quality <rol> <lang>: passrate mas reciente de ese rol×lang en eval/quality.jsonl,
# o vacio si no hay datos. nv_rank_roles "<roles>" <lang>: ordena los roles por passrate desc
# (los sin datos quedan al final, manteniendo su orden de entrada -> arranque sin datos = orden original).
NV_QSTORE="${NV_QSTORE:-$NV_HOME/eval/quality.jsonl}"
NV_Q_PRIOR_A="${NV_Q_PRIOR_A:-1}"   # prior Beta(a,b): a=b=1 -> media 0.5, suave (regulariza pocas muestras)
NV_Q_PRIOR_B="${NV_Q_PRIOR_B:-1}"
# helper interno: agrega TODAS las corridas de un rol|lang (pass y n totales) con suavizado bayesiano.
# Score = (PASS + a) / (N + a + b). Reconstruye 'pass' de lineas viejas que solo tienen passrate.
_nv_q_py='
import json,os,sys
A=float(os.environ.get("NVQ_A","1")); B=float(os.environ.get("NVQ_B","1"))
agg={}  # (rol,lang) -> [pass,n]
f=os.environ["NVQ_FILE"]
if os.path.exists(f):
    with open(f,encoding="utf-8") as fh:
        for ln in fh:
            try: d=json.loads(ln)
            except Exception: continue
            rol=d.get("rol"); lang=d.get("lang"); n=d.get("n") or 0
            if not rol or not lang or not n: continue
            p=d.get("pass")
            if p is None: p=round((d.get("passrate") or 0)*n)
            a=agg.setdefault((rol,lang),[0,0]); a[0]+=p; a[1]+=n
def score(rol,lang):
    if (rol,lang) not in agg: return None
    P,N=agg[(rol,lang)]
    return (P+A)/(N+A+B) if (N+A+B)>0 else None
'
nv_role_quality() {
  [ -f "$NV_QSTORE" ] || return 0
  NVQ_ROL="$1" NVQ_LANG="$2" NVQ_FILE="$NV_QSTORE" NVQ_A="$NV_Q_PRIOR_A" NVQ_B="$NV_Q_PRIOR_B" \
  python3 -c "$_nv_q_py"'
s=score(os.environ["NVQ_ROL"],os.environ["NVQ_LANG"])
if s is not None: print("%.3f"%s)
'
}
nv_rank_roles() {
  NVQ_FILE="$NV_QSTORE" NVQ_A="$NV_Q_PRIOR_A" NVQ_B="$NV_Q_PRIOR_B" NVR_ROLES="$1" NVR_LANG="$2" \
  python3 -c "$_nv_q_py"'
roles=os.environ["NVR_ROLES"].split(); lang=os.environ["NVR_LANG"]
# orden estable: score bayesiano desc; sin dato = -1 (al final, conservando orden de entrada)
def sc(r):
    v=score(r,lang); return v if v is not None else -1
order=sorted(range(len(roles)), key=lambda i:(-sc(roles[i]), i))
print(" ".join(roles[i] for i in order))
'
}
# nv_record_quality <rol> <lang> <pass:0|1>: agrega UN intento real a eval/quality.jsonl
# (pedido del usuario, 2026-07-18: nv_role_quality/nv_rank_roles llevaban meses leyendo un archivo
# que nadie escribia -- el router por calidad arrancaba siempre en blanco). Una linea por
# intento (n=1); nv_role_quality/nv_rank_roles ya agregan todas las lineas al leer.
nv_record_quality() {
  local rol="$1" lang="$2" ok="$3"
  mkdir -p "$(dirname "$NV_QSTORE")"
  NVQ_ROL="$rol" NVQ_LANG="$lang" NVQ_PASS="$ok" python3 -c '
import json, os, sys, datetime
d = {"rol": os.environ["NVQ_ROL"], "lang": os.environ["NVQ_LANG"], "n": 1,
     "pass": int(os.environ["NVQ_PASS"]), "ts": datetime.datetime.now().isoformat()}
print(json.dumps(d, ensure_ascii=False))
' >> "$NV_QSTORE" 2>/dev/null
}

# nv_eco_interno <texto> -> 0 (verdadero) si ese texto es ECO DEL ANDAMIAJE, no una respuesta.
#
# EL BUG QUE LO TRAJO (2026-08-15, reportado por el usuario con captura). Pidio un brazalete con modulos
# intercambiables. El turno hizo 15 'task create' identicos, nunca genero el documento, y la
# respuesta que el usuario LEYO en pantalla fue esta:
#
#   "No puedo generar un documento sin contenido. Si ya tenes el contenido, generalo AHORA con
#    "tool":"gen","action":"doc","format":"docx","content":"..." y recien despues cerra con 'done'."
#
# Eso no se lo escribio nadie al usuario: es la OBSERVACION que la guarda de documento le inyecto al
# MODELO. El modelo la devolvio como su respuesta final, y la guarda de "segunda vez" la envolvio
# en "Esto es lo que tenia preparado para adentro:" y se la mostro. el usuario termino leyendo
# instrucciones dirigidas a otro.
#
# POR QUE ES UNA FAMILIA Y NO UN CASO. Hay 102 puntos en nv-agent.sh que le inyectan texto al
# modelo, y TRES guardas que arman la respuesta final concatenando lo que el modelo devolvio.
# Cualquier combinacion de esas dos cosas produce el mismo sintoma. Taparlo caso por caso es
# perseguir 306 combinaciones; esto pregunta una sola cosa, del lado de la salida: ¿esto que estoy
# por mostrar es texto mio?
#
# LOS MARCADORES SON DE ALTA PRECISION A PROPOSITO. Ninguno aparece en una respuesta escrita para
# una persona: el protocolo JSON crudo, las ordenes de cierre que solo tienen sentido para el loop,
# y los prefijos AVISO:/ERROR: con los que arrancan las observaciones. Se prefiere dejar pasar un
# eco raro antes que censurar una respuesta legitima -- por eso no alcanza con que la respuesta
# hable de documentos o mencione una herramienta.
nv_eco_interno() {
  local t="${1:-}"
  [ -n "${t// }" ] || return 1
  # El protocolo crudo: una respuesta para el usuario nunca trae el JSON de una tool.
  case "$t" in
    *'"tool":"'*|*'"tool": "'*) return 0 ;;
  esac
  # Ordenes de cierre del loop. Solo tienen sentido dichas AL MODELO.
  # Alternancias explicitas y NO "[eé]": en este entorno grep trata los acentos byte a byte y un
  # bracket-expression con una letra acentuada no matchea de forma confiable. Ya esta documentado
  # arriba de la guarda de documento en nv-agent.sh, y volvio a morder aca al escribir esta funcion.
  printf '%s' "$t" | grep -qiE "(responde|respondé|contesta|contestá|cerra|cerrá|termina|terminá) (con |el turno con )?.?done" && return 0
  printf '%s' "$t" | grep -qiE "(recien|recién) (despues|después|ahi|ahí) (cerra|cerrá|termina|terminá)" && return 0
  # Los prefijos con los que arrancan TODAS las observaciones de guarda.
  case "$t" in
    AVISO:*|ERROR:*|"AVISO :"*|"ERROR :"*) return 0 ;;
  esac
  # Plantillas literales del protocolo, tal como se le muestran al modelo.
  case "$t" in
    *"'!img <que buscar>'"*|*"'!img <qué buscar>'"*|*"'!imgfile <ruta"*) return 0 ;;
  esac
  return 1
}

# nv_sin_eco <texto> -> imprime el texto si es una respuesta de verdad, y NADA si es eco.
# Azucar para los tres lugares que arman la respuesta final concatenando lo que devolvio el modelo.
nv_sin_eco() {
  nv_eco_interno "${1:-}" && return 1
  printf '%s' "${1:-}"
}

# nv_eco_procedencia <texto> -> 0 si ese texto es ECO DE LO QUE ESTE TURNO le dijo al modelo.
#
# LA SEGUNDA CAPA, Y LA QUE NO ENVEJECE. nv_eco_interno (arriba) pregunta si el texto SE PARECE a
# algo interno, con una lista de marcadores que hay que mantener a mano. Esto pregunta si SALIO DE
# ACA: compara contra el registro de observaciones que el motor fue anotando durante el turno
# (NVA_OBS_LOG). Cubre tambien las guardas que se escriban manana.
#
# Medido antes de encenderlo (eval/eco-procedencia/): 0 falsos positivos sobre las 75 respuestas
# reales del historial del usuario, y detecta el caso de la captura del brazalete con 0,43 de
# cobertura contra un umbral de 0,30. La separacion entre lo legitimo y el eco es total.
#
# Si no hay registro (un llamador que no lo activo), devuelve "no es eco" y se queda callado: esta
# guarda no puede ser el motivo de que un turno falle.
nv_eco_procedencia() {
  local t="${1:-}"
  [ -n "${t// }" ] || return 1
  [ "${MENTIS_ECO_PROCEDENCIA_OFF:-0}" = "1" ] && return 1
  [ -n "${NVA_OBS_LOG:-}" ] && [ -s "${NVA_OBS_LOG:-/dev/null}" ] || return 1
  local det="${NVDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/nv_eco_procedencia.py"
  [ -f "$det" ] || return 1
  local tmp; tmp="$(mktemp -t nva-final-XXXXXX 2>/dev/null)" || return 1
  printf '%s' "$t" > "$tmp"
  local salida
  salida="$(python3 "$(cygpath -w "$det" 2>/dev/null || printf '%s' "$det")" \
                    "$(cygpath -w "$NVA_OBS_LOG" 2>/dev/null || printf '%s' "$NVA_OBS_LOG")" \
                    "$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")" 2>/dev/null)"
  local codigo=$?
  rm -f "$tmp" 2>/dev/null
  [ "$codigo" -eq 0 ] && echo "[nv-lib] eco por procedencia: $salida" >&2
  return "$codigo"
}
