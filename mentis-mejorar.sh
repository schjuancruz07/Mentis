#!/usr/bin/env bash
# mentis-mejorar.sh -- Mentis se actualiza y se repara sola (2026-08-03, F del plan).
#
# QUE ES: los dos primeros escalones de la auto-mejora que pidió el usuario. La idea suya fue "que solo
# me necesite a mí para saber cuándo, y a él para mejorarse".
#
#   actualizar  (escalón 1) -- revisa el catálogo de NVIDIA, prueba los modelos nuevos contra los
#               exámenes por rol que ya existen, y PROPONE un cambio si alguno gana de verdad.
#   reparar     (escalón 2) -- mira SUS PROPIAS señales de falla (telemetría, suites en rojo) y
#               propone qué hay que arreglar, con el diagnóstico hecho.
#
# NUNCA APLICA NADA SOLO. Decisión explícita del usuario (2026-08-03): "me lo pide siempre antes de
# aplicar". Las propuestas quedan en propuestas/*.json y se aplican con 'aplicar <id>'. Eso no es
# burocracia: un cambio de modelo aplicado solo, mientras el usuario mide otra cosa, le mueve el piso y
# convierte cualquier medición posterior en basura.
#
# LOS SEIS FALLOS QUE SE ENCONTRARON A LA IDEA ORIGINAL (2026-07-12) SIGUEN VIGENTES, y este
# script los respeta:
#   1. Autor != verificador: el que mide NO es el que propone. Acá el que mide es un examen
#      determinístico con respuestas verificables (nv-fixtures-roles.sh), no la opinión de otro
#      modelo. Es más fuerte que un juez independiente: no hay opinión en el medio.
#   2. No se promete perfección: la propuesta dice qué se midió y qué NO.
#   3. Hacían falta tests automatizados: hoy hay 40 suites. Ese bloqueo se disolvió.
#   4. Aislamiento: esto no escribe una sola línea de código. Escribe propuestas.
#   5. Sin modo "sin frenos".
#   6. Rondas acotadas: --max-candidatos existe y por defecto es chico.
#
# Y UNA CORRECCIÓN PROPIA DEL 2026-08-03: 'reparar' NO lee ~/.claude/bitacora-errores.md. Esa
# bitácora es de Claude Code y mezcla sus errores con los de Mentis; leerla la pondría a perseguir
# equivocaciones ajenas. Sus fuentes son propias: su telemetría y sus suites.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/engine/nv-lib.sh"
# nv-modelos-lib.sh ANTES que los fixtures: ahi vive nv_respuesta_modelo, que es lo que hace la
# llamada real. Sin esto la funcion no existe, cada prueba devuelve vacio, y el script concluye
# con total aplomo que "ninguno de los 76 candidatos contesto" -- un resultado que parece una
# medicion y es un error de carga. Lo delato que fuera implausible, no un mensaje de error.
# shellcheck source=/dev/null
source "$HERE/engine/nv-modelos-lib.sh"
# shellcheck source=/dev/null
source "$HERE/engine/nv-fixtures-roles.sh"

case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

PROPDIR="$HERE/propuestas"
mkdir -p "$PROPDIR" 2>/dev/null || true
MAX_CAND="${MENTIS_MEJORAR_MAX:-4}"
ROLES_VALIDOS="code reason deep ultra general extract multimodal fast"

_key() {
  local k="${NVIDIA_API_KEY:-}"
  [ -n "$k" ] || k="$(nv_read_setting NVIDIA_API_KEY)"
  printf '%s' "$k"
}

# Modelo actual de un rol: primero el override, si no la tabla de ask-nvidia.sh.
_modelo_de() {
  local rol="$1" o
  o="$(nv_override_rol "$rol" 2>/dev/null || true)"
  if [ -n "$o" ]; then printf '%s' "${o%%|*}"; return 0; fi
  grep -oE "^  $rol\)[^\"]*\"[^\"]+\"" "$HERE/engine/ask-nvidia.sh" 2>/dev/null \
    | head -1 | grep -oE '"[^"]+"$' | tr -d '"'
}

_todos_los_cableados() {
  local r
  for r in $ROLES_VALIDOS; do _modelo_de "$r"; done | sort -u | grep -v '^$'
}

_nueva_propuesta() {
  printf '%s/%s-%s.json' "$PROPDIR" "$(date +%Y%m%d-%H%M%S)" "$1"
}

# ==================================================================================================
case "${1:-}" in
  propuestas)
    N=0
    for f in "$PROPDIR"/*.json; do
      [ -e "$f" ] || continue
      N=$((N+1))
      python3 - "$(nv_winpath "$f")" <<'PY'
import json, sys, os
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
print("  [%s] %s" % (os.path.basename(sys.argv[1]).replace(".json", ""), d.get("titulo", "")))
print("      %s" % d.get("resumen", "")[:120])
if d.get("no_medido"):
    print("      NO se midio: %s" % d["no_medido"][:110])
PY
    done
    [ "$N" = "0" ] && echo "  (no hay propuestas pendientes)"
    echo
    echo "  Aplicar:  mentis-mejorar.sh aplicar <id>     Descartar: mentis-mejorar.sh descartar <id>"
    exit 0 ;;

  descartar)
    ID="${2:-}"; [ -n "$ID" ] || { echo "Uso: mentis-mejorar.sh descartar <id>" >&2; exit 2; }
    F="$PROPDIR/$ID.json"
    [ -f "$F" ] || { echo "ERROR: no existe la propuesta '$ID'." >&2; exit 1; }
    rm -f "$F" && echo "Descartada: $ID"
    exit 0 ;;

  aplicar)
    ID="${2:-}"; [ -n "$ID" ] || { echo "Uso: mentis-mejorar.sh aplicar <id>" >&2; exit 2; }
    F="$PROPDIR/$ID.json"
    [ -f "$F" ] || { echo "ERROR: no existe la propuesta '$ID'." >&2; exit 1; }
    TIPO="$(python3 -c "
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: print(json.load(f).get('tipo',''))" "$(nv_winpath "$F")" | tr -d '\r')"
    if [ "$TIPO" != "modelo" ]; then
      echo "Esta propuesta es de tipo '$TIPO': no se aplica sola, es un diagnostico para leer." >&2
      echo "Vela con: mentis-mejorar.sh propuestas" >&2
      exit 2
    fi
    # Se delega en el mecanismo que YA existe y que ya sabe guardar el 'anterior' para revertir.
    python3 - "$(nv_winpath "$F")" "$(nv_winpath "$HERE/modelos-override.json")" <<'PY'
import json, sys, datetime
prop, dest = sys.argv[1], sys.argv[2]
with open(prop, encoding="utf-8") as f:
    p = json.load(f)
try:
    with open(dest, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {"roles": {}}
d.setdefault("roles", {})
rol = p["rol"]
ent = d["roles"].get(rol, {})
anterior = {"modelo": ent.get("modelo", p.get("modelo_actual", "")),
            "fallback": ent.get("fallback", ""), "fallback2": ent.get("fallback2", "")}
ent.update({"modelo": p["modelo_propuesto"],
            "fallback": ent.get("fallback") or p.get("modelo_actual", ""),
            "fallback2": ent.get("fallback2", ""),
            "desde": datetime.date.today().isoformat(),
            "motivo": p.get("resumen", "propuesto por mentis-mejorar.sh"),
            "anterior": anterior})
d["roles"][rol] = ent
with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(rol)
PY
    nv_memo_limpiar 2>/dev/null || true
    rm -f "$F"
    echo "Aplicada. Para volver atras:  mentis-modelos.sh revertir <rol>"
    exit 0 ;;

  actualizar|reparar) : ;;
  ""|-h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit 0 ;;
  *)
    echo "ERROR: no conozco '$1'. Usa: actualizar | reparar | propuestas | aplicar | descartar" >&2
    exit 2 ;;
esac

# ==================================================================================================
# ESCALON 1 -- ACTUALIZARSE
# ==================================================================================================
if [ "$1" = "actualizar" ]; then
  ROL="${2:-}"
  if [ -z "$ROL" ] || ! printf '%s' " $ROLES_VALIDOS " | grep -q " $ROL "; then
    echo "Uso: mentis-mejorar.sh actualizar <rol>     (roles: $ROLES_VALIDOS)" >&2
    exit 2
  fi
  KEY="$(_key)"
  [ -n "$KEY" ] || { echo "ERROR: falta NVIDIA_API_KEY." >&2; exit 1; }

  ACTUAL="$(_modelo_de "$ROL")"
  echo "== Rol '$ROL' -- hoy usa: ${ACTUAL:-(ninguno)} =="

  CABLEADOS="$(_todos_los_cableados)"
  echo "-- buscando candidatos en el catalogo"
  CANDIDATOS="$(curl -s -m 40 -H "Authorization: Bearer $KEY" \
      "https://integrate.api.nvidia.com/v1/models" 2>/dev/null \
    | MENTIS_CABLEADOS="$CABLEADOS" python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ya = set(x.strip() for x in os.environ.get("MENTIS_CABLEADOS", "").splitlines() if x.strip())
# Lo que NO puede servir para un rol de chat, por mas que aparezca en el catalogo: embeddings,
# reranking, guardias de contenido, vision pura, texto-a-voz. Filtrarlos por nombre es tosco pero
# barato, y el examen real de mas abajo atrapa a cualquiera que se cuele.
FUERA = re.compile(r"(embed|rerank|safety|guard|ocr|paddle|riva|tts|stt|asr|clip|segment|"
                   r"depth|dlrm|molmim|esm|protein|diffusion|sdxl|flux|video|image)", re.I)
salida = []
for m in d.get("data", []):
    mid = m.get("id", "")
    if not mid or mid in ya or FUERA.search(mid):
        continue
    salida.append(mid)
print("\n".join(salida))
' | tr -d '\r')"

  N_TOTAL="$(printf '%s\n' "$CANDIDATOS" | grep -c. || true)"
  echo "   $N_TOTAL candidatos que no estan cableados hoy"
  [ "${N_TOTAL:-0}" -gt 0 ] || { echo "   nada nuevo que probar."; exit 0; }

  # EL CATALOGO MIENTE (ERR-003): modelos listados que dan "Not found for account". Cada
  # candidato se valida con una llamada REAL antes de gastarle un examen entero.
  echo "-- descartando los que no contestan (el catalogo lista modelos que no existen para esta cuenta)"
  VIVOS=""
  N=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$N" -ge "$MAX_CAND" ] && break
    R="$(nv_respuesta_modelo "$m" "$KEY" "Deci solamente: ok" 16 0 2>/dev/null || true)"
    if [ -n "${R// }" ]; then
      VIVOS="$VIVOS$m
"
      N=$((N+1))
      echo "   vivo: $m"
    fi
  done <<< "$CANDIDATOS"

  [ -n "${VIVOS// }" ] || { echo "   ninguno contesto. Nada que proponer."; exit 0; }

  echo "-- examen del rol '$ROL' (fixtures con respuesta verificable, no opinion de otro modelo)"
  BASE="$(nv_puntaje_modelo "$ACTUAL" "$KEY" "$ROL" 2>/dev/null || echo "0/0 0")"
  BASE_OK="${BASE%%/*}"; BASE_RESTO="${BASE#*/}"; BASE_TOT="${BASE_RESTO%% *}"; BASE_MS="${BASE##* }"
  echo "   actual  $ACTUAL: $BASE_OK/$BASE_TOT aciertos, ${BASE_MS} ms de promedio"

  MEJOR=""; MEJOR_OK=0; MEJOR_MS=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    P="$(nv_puntaje_modelo "$m" "$KEY" "$ROL" 2>/dev/null || echo "0/0 0")"
    OK="${P%%/*}"; MS="${P##* }"
    echo "   nuevo   $m: $OK/$BASE_TOT aciertos, ${MS} ms"
    # Gana si acierta MAS, o si empata en aciertos y es al menos 20% mas rapido. Empatar en
    # calidad y ser un poco mas rapido no justifica mover algo que costo mediciones.
    if [ "$OK" -gt "$BASE_OK" ] 2>/dev/null || \
       { [ "$OK" -eq "$BASE_OK" ] 2>/dev/null && [ "$MS" -gt 0 ] 2>/dev/null && \
         [ "$BASE_MS" -gt 0 ] 2>/dev/null && [ $(( MS * 100 / BASE_MS )) -lt 80 ]; }; then
      if [ "$OK" -gt "$MEJOR_OK" ] 2>/dev/null || [ -z "$MEJOR" ]; then
        MEJOR="$m"; MEJOR_OK="$OK"; MEJOR_MS="$MS"
      fi
    fi
  done <<< "$VIVOS"

  if [ -z "$MEJOR" ]; then
    echo
    echo "Ninguno le gana al que ya esta. No hay nada que proponer -- que es un resultado, no un fracaso."
    exit 0
  fi

  F="$(_nueva_propuesta "modelo-$ROL")"
  MENTIS_P_ROL="$ROL" MENTIS_P_ACT="$ACTUAL" MENTIS_P_NUE="$MEJOR" \
  MENTIS_P_BOK="$BASE_OK" MENTIS_P_BTOT="$BASE_TOT" MENTIS_P_BMS="$BASE_MS" \
  MENTIS_P_NOK="$MEJOR_OK" MENTIS_P_NMS="$MEJOR_MS" \
  python3 -c '
import json, os, sys, datetime
d = {
  "tipo": "modelo",
  "fecha": datetime.datetime.now().isoformat(timespec="seconds"),
  "rol": os.environ["MENTIS_P_ROL"],
  "modelo_actual": os.environ["MENTIS_P_ACT"],
  "modelo_propuesto": os.environ["MENTIS_P_NUE"],
  "titulo": "Cambiar el cerebro de %s" % os.environ["MENTIS_P_ROL"],
  "resumen": ("%s acerto %s de %s en el examen del rol (%s ms de promedio); el actual %s acerto "
              "%s de %s (%s ms)." % (os.environ["MENTIS_P_NUE"], os.environ["MENTIS_P_NOK"],
              os.environ["MENTIS_P_BTOT"], os.environ["MENTIS_P_NMS"], os.environ["MENTIS_P_ACT"],
              os.environ["MENTIS_P_BOK"], os.environ["MENTIS_P_BTOT"], os.environ["MENTIS_P_BMS"])),
  "no_medido": ("estabilidad en el tiempo (un modelo puede saturarse manana), comportamiento con "
                "prompts largos, y uso con herramientas dentro del loop del agente. El examen "
                "mide respuestas sueltas verificables, no un turno completo."),
}
sys.stdout.write(json.dumps(d, ensure_ascii=False, indent=2))
' > "$F"
  echo
  echo "PROPUESTA escrita: $(basename "$F".json)"
  echo "  Vela con:      mentis-mejorar.sh propuestas"
  echo "  Aplicala con:  mentis-mejorar.sh aplicar $(basename "$F".json)"
  echo "  (no se aplico nada solo)"
  exit 0
fi

# ==================================================================================================
# ESCALON 2 -- REPARARSE
# ==================================================================================================
if [ "$1" = "reparar" ]; then
  echo "== Buscando fallas propias =="
  HALLAZGOS=""

  # --- 1. Telemetria: roles que vienen cayendo al fallback = principal caido -------------------
  echo "-- telemetria (no gasta ninguna llamada)"
  TEL="$(python3 - "$(nv_winpath "$NV_LOGFILE")" "$(nv_winpath "$HERE/modelos-override.json")" <<'PY'
# SE CUENTAN TURNOS, NO INTENTOS (corregido 2026-08-04).
#
# nv_log escribe UNA LINEA POR ESLABON de la cadena (ask-nvidia.sh:416 y :468), no una por
# pregunta. Contando lineas, un turno que el fallback salvo deja si o si una linea con exit!=0 y
# otra con fallback=true -- o sea que un rol que NUNCA dejo de responder puede figurar con 50% de
# fallas, y cuanto mejor funciona su fallback, peor puntua.
#
# por turnos eran 11 turnos con 36% sin respuesta, y de esos, la mayoria de una configuracion de
# modelos que ya no existia. El numero no describia nada de lo que estaba pasando.
#
# Un turno = principal -> fallback -> fallback2 de UNA pregunta: lineas contiguas del mismo rol
# donde las siguientes traen fallback=true. El turno solo cuenta como FALLIDO si ningun eslabon
# devolvio exit 0; si alguno contesto, el usuario recibio su respuesta.
import json, io, sys, collections
from datetime import datetime
try:
    ahora = datetime.now().timestamp()
    corte = ahora - 3 * 24 * 3600

    # Un rol cuyo modelo cambio hace dos horas no puede juzgarse con lo que hizo el modelo
    # anterior. La fecha 'desde' del override marca a partir de cuando la medicion es del sistema
    # que existe hoy: sin esto, un rol recien reparado arrastra las fallas del que se reemplazo.
    desde = {}
    try:
        with io.open(sys.argv[2], encoding="utf-8") as f:
            for rol, ent in (json.load(f).get("roles") or {}).items():
                if isinstance(ent, dict) and ent.get("desde"):
                    desde[rol] = str(ent["desde"])[:10]
    except Exception:
        pass

    filas = []
    for l in io.open(sys.argv[1], encoding="utf-8", errors="replace"):
        l = l.strip()
        if not l:
            continue
        try:
            d = json.loads(l)
        except Exception:
            continue
        # nv_log lo usan tambien subsistemas que no llaman a ningun modelo (el indexador, las
        # tools). Sin 'exit' ni latencia no es una llamada y contarla falsea todo.
        if d.get("exit") in (None, "") or not d.get("latencia_ms"):
            continue
        rol = d.get("rol")
        if not rol:
            continue
        try:
            t = datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except Exception:
            continue
        if t < corte:
            continue
        if rol in desde and str(d["ts"])[:10] < desde[rol]:
            continue
        d["_t"] = t
        filas.append(d)
    filas.sort(key=lambda x: x["_t"])

    turnos = []
    abierto = {}
    for d in filas:
        rol = d["rol"]
        if d.get("fallback") and rol in abierto:
            abierto[rol].append(d)
        else:
            if rol in abierto:
                turnos.append(abierto[rol])
            abierto[rol] = [d]
    turnos.extend(abierto.values())

    por_rol = collections.defaultdict(lambda: [0, 0, 0])   # turnos, con_fallback, sin_respuesta
    for t in turnos:
        p = por_rol[t[0]["rol"]]
        p[0] += 1
        if len(t) > 1:
            p[1] += 1
        if not any(x.get("exit") == 0 for x in t):
            p[2] += 1

    for rol, (tot, fb, mal) in sorted(por_rol.items()):
        if tot < 5 or rol in ("?", "verify-gate"):
            continue
        if fb * 100 // tot >= 30:
            print("FALLBACK|%s|%d|%d" % (rol, fb * 100 // tot, tot))
        if mal * 100 // tot >= 30:
            print("FALLOS|%s|%d|%d" % (rol, mal * 100 // tot, tot))
except Exception as e:
    sys.stderr.write("no pude leer la telemetria: %s\n" % e)
PY
)"
  # python3 en Windows escribe CRLF y $( ) solo se come el salto de la ULTIMA linea: todas las
  # demas quedan con un \r pegado al final del ultimo campo. Como el ultimo campo aca es $tot, el
  # \r terminaba DENTRO del JSON del diagnostico ("ultimas 21\r llamadas"). Misma familia que
  # ERR-003, donde un \r invisible convirtio un catalogo entero en un cementerio.
  TEL="$(printf '%s' "$TEL" | tr -d '\r')"
  if [ -n "${TEL// }" ]; then
    while IFS='|' read -r tipo rol pct tot; do
      [ -n "$tipo" ] || continue
      if [ "$tipo" = "FALLBACK" ]; then
        echo "   el rol '$rol' cayo al fallback en el $pct% de $tot turnos -> su principal no esta atendiendo"
        HALLAZGOS="$HALLAZGOS
- El rol '$rol' uso el fallback en el $pct% de sus ultimos $tot turnos. El principal puede estar caido O vivo pero tardando mas que el presupuesto de primer token del rol, que para el usuario es lo mismo. Correr: mentis-modelos.sh -r $rol (ahora muestra la cadena real, con override) y, si esta vivo pero lento, mentis-modelos-reparar.sh -r $rol -n"
      else
        echo "   el rol '$rol' se quedo sin respuesta en el $pct% de $tot turnos"
        HALLAZGOS="$HALLAZGOS
- El rol '$rol' se quedo sin respuesta en el $pct% de sus ultimos $tot turnos (ningun eslabon de la cadena contesto)."
      fi
    done <<< "$TEL"
  else
    echo "   sin señales de alarma en los ultimos 3 dias"
  fi

  # --- 2. Las suites propias -------------------------------------------------------------------
  # Solo las RAPIDAS y deterministas: las que llaman a modelos tardan minutos y esto tiene que
  # poder correr programado sin comerse la cuota.
  echo "-- suites rapidas"
  ROJAS=""
  for t in test-memo test-verificador test-capacidades test-drive test-ilustrar test-modelos-override; do
    [ -f "$HERE/tests/$t.sh" ] || continue
    if ! timeout 180 bash "$HERE/tests/$t.sh" >/dev/null 2>&1; then
      echo "   EN ROJO: $t"
      ROJAS="$ROJAS $t"
      HALLAZGOS="$HALLAZGOS
- La suite '$t' esta en rojo. Correrla a mano para ver que chequeo falla: bash tests/$t.sh"
    fi
  done
  [ -z "${ROJAS// }" ] && echo "   todas en verde"

  # --- 3. Servidores duplicados (ERR-111) --------------------------------------------------------
  echo "-- procesos duplicados"
  DUP="$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "
    (@(Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" |
       Where-Object { \$_.CommandLine -like '*nv_stt_server*' })).Count" 2>/dev/null | tr -d '\r ')"
  if [ -n "$DUP" ] && [ "$DUP" -gt 1 ] 2>/dev/null; then
    echo "   hay $DUP servidores de transcripcion vivos (deberia haber 1)"
    HALLAZGOS="$HALLAZGOS
- Hay $DUP servidores de transcripcion vivos a la vez. Cada uno ocupa ~1,6 GB. Deberia haber uno solo (ERR-111). Reiniciarlo: bash mentis-transcribe.sh --apagar && bash mentis-transcribe.sh --encender"
  else
    echo "   uno solo, como corresponde"
  fi

  if [ -z "${HALLAZGOS// }" ]; then
    echo
    echo "No encontre nada roto. No hay propuesta que hacer."
    exit 0
  fi

  F="$(_nueva_propuesta "diagnostico")"
  MENTIS_D_TXT="$HALLAZGOS" python3 -c '
import json, os, sys, datetime
d = {
  "tipo": "diagnostico",
  "fecha": datetime.datetime.now().isoformat(timespec="seconds"),
  "titulo": "Cosas que parecen estar fallando",
  "resumen": os.environ["MENTIS_D_TXT"].strip(),
  "no_medido": ("esto detecta sintomas, no causas. Cada punto trae el comando para mirarlo de "
                "cerca; ninguno se arregla solo."),
}
sys.stdout.write(json.dumps(d, ensure_ascii=False, indent=2))
' > "$F"
  echo
  echo "DIAGNOSTICO escrito: $(basename "$F".json)"
  echo "  Velo con: mentis-mejorar.sh propuestas"
  exit 0
fi
