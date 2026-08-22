#!/usr/bin/env bash
# nv-modelos-lib.sh -- lo que hace falta para responder "¿este modelo está vivo?", en UN solo lugar.
#
# POR QUE EXISTE:
#   Estas dos funciones nacieron dentro de mentis-modelos.sh (el chequeo de salud a mano). Cuando
#   se sumó el reparador automático (mentis-modelos-reparar.sh) hacían falta las mismas dos, y
#   copiarlas habría garantizado que un día divergieran -- justo en la decisión más cara del
#   sistema: confundir MUERTO con SATURADO. Cambiar un modelo porque hoy está saturado tira a la
#   basura una elección que costó mediciones; dejar uno muerto cuesta un timeout en CADA llamada
#   (ERR-082: el rol 'extract' tardaba 3 MINUTOS por turno agotando el intento contra un muerto).
#
#   Así que la respuesta a "¿está vivo?" se define una vez y la usan los dos.
#
# Este archivo no imprime nada al hacerse source; sólo define funciones.

# Sin esto, python3 en Windows usa el codepage de la consola (cp1252 acá, medido) para stdout
# cuando la salida está redirigida o pipeada, y CUALQUIER tilde o ñ que devuelva un modelo sale
# como bytes rotos. No es cosmético: se detectó porque un modelo contestó "Sí" a una pregunta de
# verdadero/falso, llegó como "S?." y la prueba lo dio por REPROBADO -- es decir, un modelo bueno
# quedaba descalificado por un problema de codificación. El mismo fix ya estaba documentado en
# mentis-datos.sh desde el 2026-07-15; esta librería lo había reintroducido por no llevarlo.
export PYTHONIOENCODING=utf-8

# Valores por defecto: quien haga source puede pisarlos antes o después.
NVM_URL="${NV_URL:-https://integrate.api.nvidia.com/v1/chat/completions}"
NVM_CATALOGO_URL="${NV_CATALOGO_URL:-https://integrate.api.nvidia.com/v1/models}"
NVM_TIMEOUT="${MM_TIMEOUT:-45}"      # s por modelo; uno sano contesta un ping en <10
NVM_SLOW_MS="${MM_SLOW_MS:-15000}"   # arriba de esto se marca LENTO (vivo, pero molesto)

# --- nv_tabla_roles <ruta-a-ask-nvidia.sh> --------------------------------------------------
# De donde salen los modelos: del PROPIO ask-nvidia.sh, no de una lista aparte. Copiar la tabla
# garantizaría que un día queden desincronizadas y el chequeo termine certificando modelos que ya
# nadie usa. Se parsea el `case "$ROLE"` real.
# Formato de salida: "<rol> <principal> <fb|-> <fb2|->"
nv_tabla_roles() {
  awk '
    /^[[:space:]]*[a-z]+\)[[:space:]]*NVMODEL=/ {
      rol=$0; sub(/^[[:space:]]*/,"",rol); sub(/\).*/,"",rol)
      pri=""; fb="-"; fb2="-"
      if (match($0, /NVMODEL="[^"]+"/))  { pri=substr($0,RSTART+9,RLENGTH-10) }
      if (match($0, /[^2]FBMODEL="[^"]+"/)) { fb=substr($0,RSTART+10,RLENGTH-11) }
      if (match($0, /FB2MODEL="[^"]+"/)) { fb2=substr($0,RSTART+10,RLENGTH-11) }
      if (pri != "") print rol, pri, fb, fb2
    }
  ' "$1"
}

# --- nv_ttft_rol <rol> <ruta-a-ask-nvidia.sh> -----------------------------------------------
# Cuanto espera ESE rol el primer token antes de irse al fallback. Sale parseado del propio
# ask-nvidia.sh por el mismo motivo que la tabla de modelos: si se copiara el numero, un dia el
# reparador estaria midiendo contra un presupuesto que ya no es el que usa produccion.
nv_ttft_rol() {
  local rol="$1" ask="$2"
  awk -v rol="$rol" '
    # Etiqueta de rama sola en su linea: "  code|reason|deep|ultra)" o "  *)". El case de modelos
    # pone el cuerpo en la MISMA linea que la etiqueta, asi que no se confunden.
    /^[[:space:]]*[a-z*][a-z|*_-]*\)[[:space:]]*$/ {
      pat=$0; sub(/^[[:space:]]*/,"",pat); sub(/\)[[:space:]]*$/,"",pat); next
    }
    /NVTTFT=/ && pat != "" {
      if (match($0, /NV_TTFT:-[0-9]+/)) {
        val = substr($0, RSTART+9, RLENGTH-9)
        n = split(pat, arr, "|")
        for (i = 1; i <= n; i++) {
          if (arr[i] == rol) { print val; found=1; exit }
          if (arr[i] == "*")   def = val
        }
      }
    }
    END { if (!found && def != "") print def }
  ' "$ask"
}

# --- nv_probar_ttft <modelo> <key> <dir-del-motor> [techo_s] --------------------------------
# El TIEMPO HASTA EL PRIMER TOKEN, que es lo unico que decide si un rol abandona a su principal.
# Imprime los ms, o nada si el modelo nunca llego a emitir.
#
# POR QUE NO ALCANZA nv_probar_modelo: mide time_total, que suma "tardo en arrancar" y "tardo en
# escribir". Un modelo puede tardar 40 s en total y arrancar en 2 s (sano, sólo verborragico) o
# tardar 40 s en arrancar (inservible para un rol interactivo). Para el usuario son cosas
# opuestas y el estado LENTO las confundia en una sola.
#
# Se mide con un techo GENEROSO a proposito: con el presupuesto real (12 s) todo lo que se pase
# da el mismo resultado y no se puede distinguir 13 s de 40 s -- justo lo que hace falta para
# saber si conviene esperar un poco mas o cambiar el modelo.
nv_probar_ttft() {
  local modelo="$1" key="$2" nvdir="$3" techo="${4:-75}"
  local meta
  meta="$(NVMODEL="$modelo" NVPROMPT="Responde solo: ok" NVKEY="$key" \
          NVMAX=16 NVTEMP=0 NVEXTRA='{}' NVSYS="" NVSKILL="" NVIMAGES="" \
          NV_TTFT="$techo" NV_SILENCIO="$techo" NV_TECHO="$((techo + 30))" \
          NV_EMITIR=0 NV_META_STDERR=1 \
          python3 "$nvdir/nv_stream.py" 2>&1 >/dev/null | grep '^NVMETA' | head -1)"
  printf '%s' "$meta" | sed -nE 's/.*"ttft_ms":[[:space:]]*([0-9]+).*/\1/p'
}

# --- nv_probar_modelo <modelo> <key> [prompt] [max_tokens] ----------------------------------
# Una llamada REAL al endpoint. Imprime: "<estado> <ms> <detalle>"
# Estados: VIVO | LENTO | MUERTO | SIN-ACCESO | SATURADO | RARO | ERROR
#
# Payload armado con printf, NO con python (ERR-086: cada arranque del intérprete cuesta ~1,5 s en
# Windows, y acá se llama una vez por modelo).
#
# LA DISTINCION QUE IMPORTA: SATURADO != MUERTO. La señal que los separa es el TIEMPO DE
# RESPUESTA: un modelo muerto contesta su 404/410 en medio segundo; uno saturado no contesta.
nv_probar_modelo() {
  local modelo="$1" key="$2" prompt="${3:-ping}" maxtok="${4:-8}"
  local body code total ms estado detalle payload
  body="$(mktemp)"
  # El prompt se escapa para JSON con printf %s dentro de comillas: sólo se aceptan prompts
  # simples (sin comillas ni saltos), que es todo lo que estas pruebas necesitan.
  payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":0}' \
             "$modelo" "$prompt" "$maxtok")"
  read -r code total <<< "$(curl -s -o "$body" -w '%{http_code} %{time_total}' -m "$NVM_TIMEOUT" \
    -X POST "$NVM_URL" \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "$payload" 2>/dev/null || echo "000 0")"
  # time_total viene con coma o punto según locale; se normaliza a ms sin usar bc ni python.
  ms="$(printf '%s' "$total" | tr ',' '.' | awk '{printf "%d", $1*1000}')"
  detalle=""
  case "$code" in
    200)
      if grep -q '"content"' "$body" 2>/dev/null || grep -q '"choices"' "$body" 2>/dev/null; then
        if [ "$ms" -gt "$NVM_SLOW_MS" ]; then estado="LENTO"; else estado="VIVO"; fi
      else
        estado="RARO"; detalle="200 pero sin choices en la respuesta"
      fi
      ;;
    404) estado="MUERTO";     detalle="404 -- el modelo no existe (sacado del catalogo)" ;;
    410) estado="MUERTO";     detalle="410 Gone -- fin de vida" ;;
    401) estado="SIN-ACCESO"; detalle="401 -- la API key no sirve para este modelo" ;;
    403) estado="SIN-ACCESO"; detalle="403 -- la cuenta no tiene acceso" ;;
    429) estado="SATURADO";   detalle="429 -- limite de uso; vuelve solo" ;;
    503) estado="SATURADO";   detalle="503 -- el free tier esta lleno; vuelve solo" ;;
    000) estado="SATURADO";   detalle="sin respuesta en ${NVM_TIMEOUT}s -- encolado, no muerto (un muerto contesta 404 al instante)" ;;
    *)   estado="ERROR";      detalle="HTTP $code" ;;
  esac
  # El mensaje del endpoint suele ser más claro que el código ("Not found for account" con 404).
  if [ "$estado" != "VIVO" ] && [ "$estado" != "LENTO" ]; then
    local msg
    msg="$(tr -d '\n' < "$body" | sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]{1,90})".*/\1/p')"
    [ -n "$msg" ] && detalle="$detalle | $msg"
  fi
  rm -f "$body"
  printf '%s %s %s' "$estado" "$ms" "$detalle"
}

# --- nv_respuesta_modelo <modelo> <key> <prompt> <max_tokens> -------------------------------
# Como nv_probar_modelo pero devuelve el TEXTO que contestó (vacío si falló). Lo necesita el
# reparador para las pruebas con respuesta verificable: no alcanza con que el modelo conteste,
# tiene que contestar BIEN. "Vivo" y "sirve para este rol" son dos preguntas distintas.
nv_respuesta_modelo() {
  local modelo="$1" key="$2" prompt="$3" maxtok="${4:-256}" temp="${5:-0}"
  local body payload
  body="$(mktemp)"
  payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":%s}' \
             "$modelo" "$prompt" "$maxtok" "$temp")"
  curl -s -o "$body" -m "$NVM_TIMEOUT" -X POST "$NVM_URL" \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "$payload" >/dev/null 2>&1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        d = json.load(f)
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    # Algunos modelos de razonamiento devuelven el texto en reasoning_content y dejan content
    # vacío. Sin este fallback, un modelo perfectamente bueno puntuaría 0 en todas las pruebas.
    txt = (msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()
    print(txt)
except Exception:
    pass
' "$(nv_winpath "$body" 2>/dev/null || printf '%s' "$body")" 2>/dev/null | tr -d '\r'
  rm -f "$body"
}

# --- nv_catalogo <key> ----------------------------------------------------------------------
# Los ids de modelo que el endpoint dice tener. OJO (ERR-003): EL CATALOGO MIENTE. Lista modelos
# que después contestan "Not found for account". Esta lista sirve para DESCUBRIR candidatos;
# ninguno se puede usar sin pasar antes por nv_probar_modelo.
#
# EL `tr -d '\r'` NO ES OPCIONAL y costó un buen rato encontrarlo. python3 en Windows escribe
# CRLF: print("abc") sale como "abc\r\n". Cuando la salida es de UNA sola línea no se nota,
# porque $( ) se come el "\r\n" entero -- por eso nv_read_setting y nv_override_rol andan bien.
# Pero con VARIAS líneas sólo se limpia la última, y todas las demás quedan con un \r pegado al
# final. Medido: $(python3 -c "print('abc'); print('de')") devuelve 7 caracteres, "abc\r\nde".
#
# El efecto era demoledor y silencioso: cada id de modelo del catálogo llegaba como
# "nvidia/nemotron-3-nano-30b-a3b\r", NVIDIA respondía 404 porque ese modelo no existe, y el
# sistema concluía "está muerto". Con eso, un censo de los 102 modelos dio 102 MUERTOS incluidos
# deepseek-v4-pro y llama-3.1-8b, que estaban respondiendo perfecto. Un byte invisible convertía
# un catálogo entero en un cementerio.
nv_catalogo() {
  local key="$1" body
  body="$(mktemp)"
  curl -s -o "$body" -m 30 "$NVM_CATALOGO_URL" -H "Authorization: Bearer $key" >/dev/null 2>&1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        d = json.load(f)
    for m in d.get("data") or []:
        i = m.get("id")
        if i:
            print(i)
except Exception:
    pass
' "$(nv_winpath "$body" 2>/dev/null || printf '%s' "$body")" 2>/dev/null | tr -d '\r'
  rm -f "$body"
}

# --- nv_ttft_veredicto <t1> <t2> <lim_ms> <estado_endpoint> --------------------------------
# Decide si un principal esta FUERA del presupuesto de su rol, DENTRO, o si directamente NO SE
# PUDO MEDIR. Imprime una de esas tres palabras. Funcion pura: no llama a nadie, se testea sola.
#
# POR QUE EXISTE (2026-08-22, ERR-215). La version anterior vivia dentro del reparador y decia:
#   "Vacio = nunca emitio: peor que pasarse. Se cuenta como fuera de presupuesto."
# Ese razonamiento es falso. nv_probar_ttft devuelve vacio por CUALQUIERA de estas razones y no
# las distingue: el modelo acepto y nunca emitio (falla real), un 429 del free tier, un 503, un
# corte de red, o curl que se quedo sin tiempo. Las cuatro ultimas no son culpa del modelo.
#
# El dano medido: el 2026-08-21 el rol 'general' fue degradado de nemotron-3-nano-30b a
# muse-glimmer-30b, y el motivo que quedo escrito en modelos-override.json fue literalmente
#   "tarda sin-token/sin-token ms en el primer token"
# -- o sea, se cambio un modelo elegido con mediciones por DOS VALORES VACIOS. Es la misma
# leccion que ya estaba escrita tres veces en este repo (SATURADO != MUERTO), sin aplicar aca.
#
# LA REGLA:
#   - un solo sondeo que llegue a tiempo alcanza para probar que el modelo PUEDE -> DENTRO.
#     (si midio bien una vez, el otro sondeo vacio es sospecha, no evidencia)
#   - los dos midieron y los dos se pasaron -> FUERA, sin ambiguedad.
#   - hay algun vacio: solo cuenta como FUERA si el endpoint contesta sano (VIVO/LENTO), porque
#     ahi el silencio SI es del modelo. Con SATURADO, ERROR, RARO o sin dato -> NO-MEDIBLE.
nv_ttft_veredicto() {
  local t1="$1" t2="$2" lim="$3" est="${4:-}"
  local n1=0 n2=0
  case "$t1" in ''|*[!0-9]*) n1=0 ;; *) n1=1 ;; esac
  case "$t2" in ''|*[!0-9]*) n2=0 ;; *) n2=1 ;; esac

  if [ "$n1" = 1 ] && [ "$t1" -le "$lim" ]; then printf 'DENTRO'; return 0; fi
  if [ "$n2" = 1 ] && [ "$t2" -le "$lim" ]; then printf 'DENTRO'; return 0; fi
  if [ "$n1" = 1 ] && [ "$n2" = 1 ];          then printf 'FUERA';  return 0; fi

  case "$est" in
    VIVO|LENTO) printf 'FUERA' ;;
    *)          printf 'NO-MEDIBLE' ;;
  esac
}
