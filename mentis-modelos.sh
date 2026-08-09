#!/usr/bin/env bash
# mentis-modelos.sh — chequeo de salud REAL de los modelos que Mentis tiene configurados.
#
# Uso:
#   mentis-modelos.sh            # prueba todos los modelos (principales + fallbacks)
#   mentis-modelos.sh -p         # solo los PRINCIPALES (mas rapido, es lo que importa a diario)
#   mentis-modelos.sh -r reason  # solo los modelos de un rol
#   mentis-modelos.sh -q         # silencioso: sin tabla, solo el resumen y el exit code
#   mentis-modelos.sh -t [-d 7]  # NO llama a nadie: lee la telemetria de los ultimos N dias y
#                                #   dice que roles vienen cayendo al fallback (= principal caido)
#   mentis-modelos.sh -m id1,id2 # prueba modelos SUELTOS antes de wirearlos a un rol
#
# Sale con 0 si todos los PRINCIPALES estan vivos, 1 si alguno esta muerto/sin acceso.
# (Los fallbacks caidos se reportan pero no cambian el exit code: no rompen el dia a dia.)
#
# POR QUE EXISTE: el catalogo de NVIDIA MIENTE (ERR-003: modelos listados que dan "Not found
# for account") y los modelos se MUEREN sin aviso. Paso dos veces con el mismo sintoma:
#   ERR-082 -- qwen3.5-397b llego a su fin de vida (410 Gone) y el rol 'extract' tardaba 3
#              MINUTOS por turno: agotaba el intento contra el muerto antes de caer al fallback.
#   ERR-084 -- Mentis se convencio de que "no podia" hacer algo y la creencia se cumplia sola.
# El fallback tapa la falla lo suficiente para que nadie la vea, pero se paga en cada llamada.
# Un "AVISO: usando fallback" repetido en los logs SIEMPRE significa "el principal esta muerto".
#
# Esto NO reemplaza al router por salud de nv-lib.sh (nv_model_health): ese mira la telemetria
# de lo que ya paso y es probabilistico (reprueba, explora). Esto PREGUNTA AL ENDPOINT ahora
# mismo, que es la unica forma de distinguir "no lo usamos hace rato" de "esta muerto".
set -uo pipefail

MENTIS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVDIR="$MENTIS_ENV_DIR/engine"
ASKFILE="$NVDIR/ask-nvidia.sh"
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"
# shellcheck source=/dev/null
source "$NVDIR/nv-modelos-lib.sh"

URL="${NV_URL:-https://integrate.api.nvidia.com/v1/chat/completions}"
SETTINGS="$HOME/.claude/settings.json"
TIMEOUT="${MM_TIMEOUT:-45}"      # s por modelo; un modelo sano contesta un ping en <10
SLOW_MS="${MM_SLOW_MS:-15000}"   # arriba de esto se marca LENTO (vivo, pero molesto)

# --- revertir: deshacer un cambio automatico de modelo -------------------------------------------
# Va ANTES del getopts porque es un subcomando, no una opcion: "mentis-modelos.sh revertir fast".
# Deshacer tiene que ser mas facil que el cambio que deshace -- si revertir fuera complicado, el
# reemplazo automatico dejaria de ser reversible en la practica, que es lo unico que lo hace
# aceptable. Por eso cada entrada del override guarda su "anterior".
MM_OVERRIDE="${NV_OVERRIDE_FILE:-$MENTIS_ENV_DIR/modelos-override.json}"
if [ "${1:-}" = "revertir" ]; then
  MM_QUE="${2:-}"
  if [ -z "$MM_QUE" ]; then
    echo "Uso: mentis-modelos.sh revertir <rol>   |   mentis-modelos.sh revertir --todo" >&2
    exit 2
  fi
  if [ ! -f "$MM_OVERRIDE" ]; then
    echo "No hay ningun cambio automatico que deshacer (no existe $MM_OVERRIDE)."
    exit 0
  fi
  # Los defaults REALES del case de ask-nvidia.sh. Hacen falta aca porque borrar la entrada del
  # override NO devuelve el rol a lo que dice "anterior": lo devuelve al default. Si esos dos no
  # coinciden, este comando promete una cosa y hace otra (ver el comentario de abajo).
  MMR_DEFAULTS="$(nv_tabla_roles "$ASKFILE")" \
  MMR_QUE="$MM_QUE" python3 -c '
import json, os, sys
ruta = sys.argv[1]
que = os.environ["MMR_QUE"]

# EL DEFAULT NO ES SIEMPRE LO ANTERIOR (bug real, 2026-08-06). Esto borraba la entrada del
# override y anunciaba "vuelve a <anterior>". Pero el rol no vuelve a "anterior": vuelve al
# default del case. Medido en vivo con "revertir": informo "vuelve a z-ai/glm-5.2" y dejo
# a con deepseek-v4-pro -- 52 s hasta el primer token, el peor modelo de la tabla, en el
# rol con consecuencia medica. El comando de deshacer dejaba el sistema PEOR que antes de tocarlo,
# y decia lo contrario mientras lo hacia.
#
# Ahora, si "anterior" no coincide con el default, se REESCRIBE la entrada con esos valores en vez
# de borrarla. Deshacer tiene que devolver el sistema a donde estaba, no a donde arranco.
defaults = {}
for linea in (os.environ.get("MMR_DEFAULTS") or "").splitlines():
    p = linea.split()
    if len(p) >= 2:
        defaults[p[0]] = [x if x != "-" else "" for x in (p[1:4] + ["", ""])[:3]]
try:
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    print("ERROR: no pude leer el override: %s" % e); sys.exit(1)
roles = d.get("roles") or {}
if que == "--todo":
    objetivo = list(roles.keys())
else:
    if que not in roles:
        print("El rol \"%s\" no tiene ningun cambio automatico vigente." % que)
        print("Roles con cambio: %s" % (", ".join(roles) if roles else "(ninguno)"))
        sys.exit(0)
    objetivo = [que]
for r in objetivo:
    ent = roles.get(r) or {}
    ant = ent.get("anterior") or {}
    ant_cadena = [ (ant.get("modelo") or "").strip(),
                   (ant.get("fallback") or "").strip(),
                   (ant.get("fallback2") or "").strip() ]
    porde = defaults.get(r, ["", "", ""])

    if ant_cadena[0] and ant_cadena != porde:
        # Lo de antes NO era el default: hay que reescribirlo, no borrarlo.
        roles[r] = {
            "modelo": ant_cadena[0], "fallback": ant_cadena[1], "fallback2": ant_cadena[2],
            "desde": ent.get("desde", ""),
            "motivo": "revertido a mano el %s; se restaura la cadena anterior (borrar la entrada "
                      "habria dejado el rol con el default de ask-nvidia.sh, que no es lo que "
                      "habia)" % __import__("datetime").date.today().isoformat(),
        }
        print("  %s: %s  ->  vuelve a  %s" % (r, ent.get("modelo", "?"), ant_cadena[0]))
    else:
        # Lo de antes ERA el default: borrar la entrada es exactamente volver ahi, y ademas deja
        # el camino normal sin costo.
        destino = porde[0] or "(el de la tabla)"
        print("  %s: %s  ->  vuelve a  %s" % (r, ent.get("modelo", "?"), destino))
        del roles[r]
# Si no queda ningun rol con override, se BORRA el archivo entero en vez de dejarlo vacio: asi el
# camino normal vuelve a costar cero (la lectura del override arranca con un test de existencia).
if not roles:
    os.remove(ruta)
    print("  (no quedan cambios automaticos; se borro el archivo de override)")
else:
    d["roles"] = roles
    tmp = ruta + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, ruta)
' "$(nv_winpath "$MM_OVERRIDE")"
  MM_RC=$?
  # El override quedo distinto: se vacia la memoria corta de nv-lib.sh para que el cambio valga
  # YA y no dentro de un TTL. Sin esto, revertir un modelo parecia no hacer nada por 10 minutos.
  nv_memo_limpiar 2>/dev/null || true
  exit $MM_RC
fi

SOLO_PRINCIPALES=0; SOLO_ROL=""; QUIET=0; CANDIDATOS=""; TELEMETRIA=0; TEL_DIAS=7
while getopts ":pr:qm:td:" opt; do
  case "$opt" in
    p) SOLO_PRINCIPALES=1 ;;
    t) TELEMETRIA=1 ;;
    d) TEL_DIAS="$OPTARG" ;;
    r) SOLO_ROL="$OPTARG" ;;
    q) QUIET=1 ;;
    # -m <id,id,...>: probar modelos SUELTOS que todavia no estan wireados. Es el protocolo
    # obligatorio antes de meter un modelo nuevo en ask-nvidia.sh -- el catalogo miente
    # (ERR-003) y "figura listado" no es lo mismo que "responde", ni "responde" que "responde
    # rapido" (minimax-m3 esta vivo y es lentisimo).
    m) CANDIDATOS="$OPTARG" ;;
    *) echo "ERROR: opcion invalida -$OPTARG" >&2; exit 2 ;;
  esac
done

KEY="${NVIDIA_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SETTINGS" ]; then KEY="$(nv_read_setting NVIDIA_API_KEY)"; fi
[ -z "$KEY" ] && { echo "ERROR: falta NVIDIA_API_KEY (ni en env ni en settings.json)" >&2; exit 2; }
# El rol 'ultra' usa una key dedicada (ver ask-nvidia.sh). Si no esta, cae a la principal --
# igual que el propio ask-nvidia.sh, para que este chequeo pruebe lo que de verdad va a pasar.
KEY_NEMOTRON="${NVIDIA_API_KEY_NEMOTRON:-}"
if [ -z "$KEY_NEMOTRON" ] && [ -f "$SETTINGS" ]; then KEY_NEMOTRON="$(nv_read_setting NVIDIA_API_KEY_NEMOTRON)"; fi
[ -z "$KEY_NEMOTRON" ] && KEY_NEMOTRON="$KEY"

# --- de donde salen los modelos y como se prueban: engine/nv-modelos-lib.sh -----------------
# Estas dos funciones vivian aca adentro. Se mudaron a la libreria el 2026-08-01, cuando el
# reparador automatico (mentis-modelos-reparar.sh) empezo a necesitar exactamente las mismas dos.
# Tenerlas duplicadas habria garantizado que un dia divergieran justo en la decision mas cara del
# sistema: confundir MUERTO con SATURADO. Los nombres viejos se conservan como envoltorios para
# no tocar el resto de este script.
# OJO (2026-08-04): la tabla del `case` de ask-nvidia.sh es el DEFAULT, no lo que se usa. Cuando
# un rol tiene entrada en modelos-override.json, produccion corre con ESA cadena (ask-nvidia.sh:242)
# y esta la ignoraba -- asi que el chequeo de salud auditaba modelos que el rol no usa.
#
# 'deepseek-v4-pro' VIVO y rotulaba 'glm-5.2' como fallback LENTO. Al reves: glm-5.2 era el
# PRINCIPAL (por override) y estaba sin emitir primer token, y deepseek-v4-flash -- el fallback
# real, el que estaba atendiendo todos los turnos -- no se probaba nunca. El chequeo daba "OK:
# todos los principales responden" sobre un rol con consecuencia medica cuyo principal no atendia.
#
# ask-nvidia.sh, mentis-modelos-reparar.sh y mentis-mejorar.sh ya leian el override; este era el
# unico de los cuatro que no. Un chequeo de salud que mira otra cosa que produccion es peor que no
# tener chequeo: certifica sano lo que esta roto.
_mm_tabla_roles() {
  nv_tabla_roles "$ASKFILE" | while read -r rol pri fb fb2; do
    local ovr o_pri o_fb o_fb2
    ovr="$(NV_OVERRIDE_FILE="$MM_OVERRIDE" nv_override_rol "$rol" 2>/dev/null || true)"
    if [ -n "$ovr" ]; then
      IFS='|' read -r o_pri o_fb o_fb2 <<< "$ovr"
      [ -n "$o_pri" ] && pri="$o_pri"
      # Un override con fallback vacio (multimodal) tiene que salir como "-", no como cadena
      # vacia: el lector de esta tabla es `read -r rol pri fb fb2` y un campo vacio le correria
      # las columnas.
      fb="${o_fb:--}"; fb2="${o_fb2:--}"
    fi
    printf '%s %s %s %s\n' "$rol" "$pri" "$fb" "$fb2"
  done
}

# Que roles vienen del override. Se imprime ARRIBA de la tabla y no como columna extra: el lector
# es `read -r rol pri fb fb2`, y una quinta columna se le pegaria a fb2.
_mm_roles_con_override() {
  [ -f "$MM_OVERRIDE" ] || return 0
  nv_tabla_roles "$ASKFILE" | while read -r rol _pri _fb _fb2; do
    [ -n "$(NV_OVERRIDE_FILE="$MM_OVERRIDE" nv_override_rol "$rol" 2>/dev/null || true)" ] && printf '%s ' "$rol"
  done
}

# Ver el comentario de arriba: la implementacion esta en engine/nv-modelos-lib.sh.
_mm_probar() { NVM_TIMEOUT="$TIMEOUT" NVM_SLOW_MS="$SLOW_MS" NVM_URL="$URL" nv_probar_modelo "$1" "$2"; }

# --- recorrido -------------------------------------------------------------------------------
declare -A YA_PROBADO=()   # un modelo repetido entre roles se prueba UNA vez (deepseek esta en 4)
MUERTOS_PRINCIPALES=0; MUERTOS_FALLBACK=0; LENTOS=0; VIVOS=0; SATURADOS=0
RESUMEN=""; SAT_RESUMEN=""

# Modo telemetria: no llama a nadie, lee lo que YA paso (logs/nv.jsonl). El sintoma que el usuario
# pidio vigilar -- "un AVISO: usando fallback repetido = principal muerto" -- ya esta registrado
# ahi en cada llamada; nadie lo estaba mirando. Esto es la revision "periodica" barata: cuesta
# cero llamadas y responde al instante.
if [ "$TELEMETRIA" = "1" ]; then
  LOG="${NV_LOGFILE:-$NVDIR/logs/nv.jsonl}"
  [ -f "$LOG" ] || { echo "No hay telemetria todavia ($LOG no existe)."; exit 0; }
  NVT_FILE="$LOG" NVT_DIAS="$TEL_DIAS" python3 -c '
import json, os, time
from datetime import datetime
dias=float(os.environ["NVT_DIAS"]); now=time.time(); corte=now-dias*86400
por_rol={}
for ln in open(os.environ["NVT_FILE"], encoding="utf-8"):
    ln=ln.strip()
    if not ln: continue
    try: d=json.loads(ln)
    except Exception: continue
    try: ts=datetime.strptime(d.get("ts",""),"%Y-%m-%dT%H:%M:%S%z").timestamp()
    except Exception: continue
    if ts<corte: continue
    # Solo cuentan las lineas que SON una llamada a un modelo: nv_log lo usan tambien otros
    # subsistemas (nv-verify, el indexador) que loguean sin 'exit' ni latencia. Contarlas como
    # fallo daba un 100% de fallas falso para roles que ni siquiera llaman a un modelo.
    if d.get("exit") in (None,"") or not d.get("latencia_ms"): continue
    rol=d.get("rol") or "?"
    r=por_rol.setdefault(rol,{"n":0,"fb":0,"fallos":0,"lat":[]})
    r["n"]+=1
    if d.get("fallback") in (True,"true"): r["fb"]+=1
    if str(d.get("exit")) != "0": r["fallos"]+=1
    r["lat"].append(d["latencia_ms"])
if not por_rol:
    print("Sin llamadas registradas en los ultimos %g dias." % dias); raise SystemExit(0)
print("%-12s %7s %14s %10s %12s" % ("ROL","LLAMADAS","AL FALLBACK","FALLIDAS","LAT.MEDIANA"))
print("-"*60)
alertas=[]
for rol,r in sorted(por_rol.items(), key=lambda kv:-kv[1]["n"]):
    pfb = 100.0*r["fb"]/r["n"]
    pfa = 100.0*r["fallos"]/r["n"]
    lat = sorted(r["lat"]); med = lat[len(lat)//2] if lat else 0
    print("%-12s %7d %13.0f%% %9.0f%% %10.1fs" % (rol, r["n"], pfb, pfa, med/1000.0))
    # 30%: por debajo puede ser el router explorando (NV_EXPLORE=0.2 reprueba a proposito).
    if pfb >= 30: alertas.append("  rol %s: %.0f%% de sus llamadas terminaron en el FALLBACK -- el principal no esta atendiendo." % (rol,pfb))
    if med > 60000: alertas.append("  rol %s: latencia mediana de %.0fs -- algo esta encolado." % (rol,med/1000.0))
print()
if alertas:
    print("SENALES DE QUE UN PRINCIPAL NO ESTA BIEN:")
    for a in alertas: print(a)
    print()
    print("Confirmalo preguntandole al endpoint ahora: bash mentis-modelos.sh -p")
else:
    print("Sin senales de degradacion: los principales vienen atendiendo.")
'
  exit 0
fi

# Modo candidatos: probar IDs sueltos y salir (no toca la tabla de roles).
if [ -n "$CANDIDATOS" ]; then
  printf '%-46s %-12s %8s  %s\n' "MODELO CANDIDATO" "ESTADO" "MS" "DETALLE"
  printf '%s\n' "--------------------------------------------------------------------------------"
  vivos=0
  IFS=',' read -ra _cands <<< "$CANDIDATOS"
  for c in "${_cands[@]}"; do
    c="$(printf '%s' "$c" | tr -d ' ')"; [ -z "$c" ] && continue
    read -r estado ms detalle <<< "$(_mm_probar "$c" "$KEY")"
    [ "$estado" = "VIVO" ] && vivos=$((vivos+1))
    printf '%-46s %-12s %8s  %s\n' "$c" "$estado" "$ms" "$detalle"
  done
  echo
  echo "$vivos candidato(s) VIVO(s). Recordá: vivo y rapido no es lo mismo que BUENO --"
  echo "antes de wirear un rol, medilo contra problemas reales con respuesta verificable."
  exit 0
fi

if [ "$QUIET" = "0" ]; then
  _mm_ovr_roles="$(_mm_roles_con_override)"
  if [ -n "${_mm_ovr_roles// }" ]; then
    echo "Cadena tomada de modelos-override.json (no del default de ask-nvidia.sh) para: ${_mm_ovr_roles% }"
    echo
  fi
fi
[ "$QUIET" = "0" ] && printf '%-11s %-12s %-42s %-11s %8s  %s\n' "ROL" "PAPEL" "MODELO" "ESTADO" "MS" "DETALLE"
[ "$QUIET" = "0" ] && printf '%s\n' "-------------------------------------------------------------------------------------------------------------"

while read -r rol pri fb fb2; do
  [ -n "$SOLO_ROL" ] && [ "$rol" != "$SOLO_ROL" ] && continue
  papeles=("principal:$pri")
  if [ "$SOLO_PRINCIPALES" = "0" ]; then
    [ "$fb"  != "-" ] && papeles+=("fallback:$fb")
    [ "$fb2" != "-" ] && papeles+=("fallback2:$fb2")
  fi
  for entrada in "${papeles[@]}"; do
    papel="${entrada%%:*}"; modelo="${entrada#*:}"
    key="$KEY"; [ "$rol" = "ultra" ] && key="$KEY_NEMOTRON"
    clave="$modelo|$key"
    if [ -n "${YA_PROBADO[$clave]:-}" ]; then
      read -r estado ms detalle <<< "${YA_PROBADO[$clave]}"
      detalle="(ya probado en otro rol)"
    else
      res="$(_mm_probar "$modelo" "$key")"
      YA_PROBADO[$clave]="$res"
      read -r estado ms detalle <<< "$res"
    fi
    # nv_model_health mira la telemetria: un modelo VIVO pero marcado degradado significa que
    # viene fallando/tardando en uso real aunque el ping salga bien. Vale la pena decirlo.
    if [ "$estado" = "VIVO" ] && [ "$(nv_model_health "$modelo")" = "degraded" ]; then
      detalle="ping ok, pero la telemetria lo da DEGRADADO en uso real"
    fi
    case "$estado" in
      VIVO)  VIVOS=$((VIVOS+1)) ;;
      LENTO) LENTOS=$((LENTOS+1)) ;;
      SATURADO)
             SATURADOS=$((SATURADOS+1))
             [ "$papel" = "principal" ] && SAT_RESUMEN="${SAT_RESUMEN}  rol '$rol': $modelo -- $detalle"$'\n' ;;
      *)     if [ "$papel" = "principal" ]; then MUERTOS_PRINCIPALES=$((MUERTOS_PRINCIPALES+1))
             RESUMEN="${RESUMEN}  rol '$rol': el PRINCIPAL $modelo esta $estado -- $detalle"$'\n'
             else MUERTOS_FALLBACK=$((MUERTOS_FALLBACK+1))
             RESUMEN="${RESUMEN}  rol '$rol': el $papel $modelo esta $estado"$'\n'
             fi ;;
    esac
    [ "$QUIET" = "0" ] && printf '%-11s %-12s %-42s %-11s %8s  %s\n' "$rol" "$papel" "$modelo" "$estado" "$ms" "$detalle"
  done
done < <(_mm_tabla_roles)

echo
if [ "$MUERTOS_PRINCIPALES" -gt 0 ]; then
  echo "PROBLEMA: $MUERTOS_PRINCIPALES modelo(s) PRINCIPAL(es) caido(s). Cada llamada a esos roles"
  echo "gasta el timeout completo contra el muerto antes de caer al fallback (paso en ERR-082: 3 minutos por turno)."
  printf '%s' "$RESUMEN"
  echo "Que hacer: promover el fallback (que ya viene respondiendo) a principal en engine/ask-nvidia.sh,"
  echo "y buscarle un fallback nuevo -- probandolo de verdad con este script, no confiando en el catalogo."
  exit 1
fi

if [ "$SATURADOS" -gt 0 ]; then
  echo "ATENCION: $SATURADOS modelo(s) SATURADO(s) -- vivos, pero el free tier no los esta atendiendo ahora."
  [ -n "$SAT_RESUMEN" ] && { echo "Principales afectados:"; printf '%s' "$SAT_RESUMEN"; }
  echo "NO cambies el modelo por esto: la saturacion se va sola y la eleccion actual costo mediciones."
  echo "Lo que SI importa es que un principal saturado no 'falla', se cuelga -- y el fallback solo salta"
  echo "cuando el principal FALLA, no cuando tarda. Por eso los roles conversacionales tienen NVTO finito."
  echo "Si el mismo modelo aparece saturado varios dias seguidos, ahi si conviene mover el principal."
fi
echo "OK: todos los principales responden o estan encolados. ($VIVOS vivos, $LENTOS lentos, $SATURADOS saturados, $MUERTOS_FALLBACK fallback(s) caido(s))"
[ "$MUERTOS_FALLBACK" -gt 0 ] && { echo "Fallbacks caidos (no urgente, pero es la red de seguridad):"; printf '%s' "$RESUMEN"; }
[ "$LENTOS" -gt 0 ] && echo "Nota: 'LENTO' = vivo pero tardo mas de $((SLOW_MS/1000))s en un ping trivial."
[ "$SATURADOS" -gt 0 ] && exit 3
exit 0
