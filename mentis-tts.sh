#!/usr/bin/env bash
# mentis-tts.sh -- la voz de Mentis (2026-07-26). Genera un.wav con los modelos TTS de NVIDIA.
#
# Reemplaza a speechSynthesis de Windows, que era la voz "Microsoft Helena" -- robotica y con
# una sola entonacion. El modelo magpie-tts-multilingual da 74 voces en español CON emociones
# (Isabela, Diego, Louise, Pascal x Neutral/Calm/Happy/Sad/Angry/...). el usuario escucho tres
# muestras y eligio la voz elegida.
#
# Va por gRPC (protocolo Riva), NO por REST: estos modelos no se sirven desde
# integrate.api.nvidia.com -- probado, 404 en todos los endpoints REST.
#
# Uso:
#   mentis-tts.sh "texto a decir" [archivo.wav]     -> genera el wav (imprime la ruta)
#   mentis-tts.sh --voces                            -> lista las voces en español
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/engine/nv-lib.sh"

# Igual que en mentis-backup.sh: si esto lo dispara Electron o una tarea programada, el PATH
# puede venir sin /usr/bin.
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

MENTIS_VOZ="${MENTIS_VOZ:-Magpie-Multilingual.ES-US.Isabela.Happy}"
export NVIDIA_KEY_VOZ_PARLANCHIN="${NVIDIA_KEY_VOZ_PARLANCHIN:-}"

if [ "${1:-}" = "--voces" ]; then
  python3 "$HERE/engine/nv_tts.py" --listar-voces --modelo magpie --prefijo-idioma ES
  exit $?
fi

TEXTO="${1:-}"
if [ -z "${TEXTO// }" ]; then
  echo "Uso: mentis-tts.sh \"texto\" [salida.wav]" >&2
  exit 2
fi

SALIDA="${2:-}"
if [ -z "$SALIDA" ]; then
  SALIDA="$(mktemp -u)-mentis-voz.wav"
fi

# El texto puede traer saltos de linea y markdown: el TTS los lee literal ("asterisco asterisco").
# Se limpia lo mas grosero antes de mandarlo.
TEXTO_LIMPIO="$(printf '%s' "$TEXTO" | python3 -c '
import sys, re
sys.stdin.reconfigure(encoding="utf-8"); sys.stdout.reconfigure(encoding="utf-8", newline="")
t = sys.stdin.read()
t = re.sub(r"```.*?```", " ", t, flags=re.S)      # bloques de codigo: no se leen
t = re.sub(r"[*_`#>|]+", " ", t)                   # marcas de markdown sueltas
t = re.sub(r"\[(.*?)\]\(.*?\)", r"\1", t)          # links: se deja el texto, no la URL
t = re.sub(r"\s+", " ", t).strip()
print(t[:1200], end="")                             # tope: frases larguisimas cortan la sintesis
')"

# --- ELEVENLABS PARA LAS FRASES CORTAS (2026-08-03, D del plan) ---------------------------------
#
# Medido sobre la misma frase en español: ElevenLabs Flash empieza a entregar audio a los 408 ms
# y termina en 987 ms de punta a punta; NVIDIA tarda 2.469 ms. Son 2,4 veces mas rapido, y en una
# conversacion hablada eso es la diferencia entre contestar y hacer esperar.
#
# ES SELECTIVO Y NO UN REEMPLAZO, por una razon de cuota medida y no opinable: el plan gratuito da
# 10.000 creditos al mes, flash cuesta 0,5 creditos por caracter (30 caracteres -> cabecera
# 'character-cost: 15'), o sea 20.000 caracteres mensuales. El volumen real de voz del usuario es de
# 48.681 caracteres por mes. Alcanza para el 41%. Gastarla en los textos largos seria quedarse sin
# voz rapida justo para los avisos cortos, que son los que se escuchan esperando.
#
# TRES CONDICIONES, y las tres tienen su motivo:
#   1. Que el usuario haya ELEGIDO una voz (MENTIS_EL_VOZ). Arranca apagado: cual voz suena bien es una
#      decision de oido, no algo que yo pueda medir. 'mentis-tts-eleven.sh --probar' hace las
#      muestras.
#   2. Que la frase sea CORTA. El umbral protege la cuota.
#   3. Que NADIE haya pedido un archivo de salida concreto. Si el llamador dijo "dejalo en x.wav",
#      es porque espera un wav; ElevenLabs devuelve mp3 y meter mp3 adentro de un archivo.wav es
#      pedirle a alguien que lo reproduzca de casualidad. En el camino conversacional -- que es el
#      que importa para la latencia -- la app NO pasa ruta: usa la que se le devuelve.
# Si algo falla o no hay cuota, sigue de largo por NVIDIA sin decir nada: quedarse sin voz por
# ahorrar medio segundo seria un mal negocio.
MENTIS_EL_MAXCHARS="${MENTIS_EL_MAXCHARS:-220}"
# LA VOZ ELEGIDA SE GUARDA, NO SE EXPORTA A MANO (2026-08-08).
# La condición 1 de acá abajo pide que exista MENTIS_EL_VOZ, pero NADIE la exportaba: ni la app,
# ni mentis-chat.sh, ni un archivo de arranque. O sea que ElevenLabs estaba integrado, probado y
# documentado, y en la práctica no se usó nunca -- siempre se caía por NVIDIA sin decir nada,
# que es justo lo que este script hace cuando algo falla. Un apagado silencioso es indistinguible
# de un "todavía no elegí".
# Ahora, si la variable no viene del entorno, se lee de mentis-settings.json. Sigue arrancando
# apagado (si nadie eligió, el campo no existe y no pasa nada), y la elección sobrevive al
# reinicio. Va en settings y no en el código porque es una preferencia de cada persona: el
# archivo NO viaja en las copias, así que cada uno elige su voz.
# De qué archivo sale la config. Se respeta MENTIS_SETTINGS_FILE, que es la convención que ya usa
# ask-nvidia.sh, por un motivo concreto: sin eso, los tests leen el settings REAL del usuario y prueban
# lo que él tenga configurado hoy en vez del comportamiento del script. Pasó apenas se guardó la
# voz de Lily: el caso "sin voz elegida debe salir por NVIDIA" empezó a fallar, no porque el
# ruteo estuviera mal sino porque ya había una voz elegida de verdad. Un test atado al estado de
# producción es ERR-119 otra vez.
MENTIS_TTS_SETTINGS="${MENTIS_SETTINGS_FILE:-$HERE/mentis-settings.json}"
if [ -z "${MENTIS_EL_VOZ:-}" ] && [ -f "$MENTIS_TTS_SETTINGS" ]; then
  MENTIS_EL_VOZ="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        print(((json.load(f).get("voz") or {}).get("elevenVozId") or "").strip())
except Exception:
    pass
' "$MENTIS_TTS_SETTINGS" 2>/dev/null | tr -d "\r")"
fi
if [ -n "${MENTIS_EL_VOZ:-}" ] && [ -z "${2:-}" ] \
   && [ "${#TEXTO_LIMPIO}" -le "$MENTIS_EL_MAXCHARS" ] \
   && [ -f "$HERE/engine/eleven_tts.py" ]; then
  EL_OUT="$(mktemp -u)-mentis-voz.mp3"
  # La voz va como ARGUMENTO explícito, no confiando en el entorno. eleven_tts.py la toma de
  # `os.environ.get("MENTIS_EL_VOZ", <Sarah>)`, y acá arriba MENTIS_EL_VOZ se define como variable
  # del script, sin export: el intérprete no la heredaba y usaba Sarah SIEMPRE, ignorando la voz
  # elegida. Y no se notaba, porque igual generaba un mp3 perfecto -- sólo que con la voz que no
  # era. Un bug que "funciona" es el que más tarda en aparecer.
  if MENTIS_EL_TEXTO="$TEXTO_LIMPIO" python3 "$HERE/engine/eleven_tts.py" \
        --texto "$TEXTO_LIMPIO" --salida "$EL_OUT" --voz "$MENTIS_EL_VOZ" 2>/dev/null | grep -q. && [ -s "$EL_OUT" ]; then
    printf '%s\n' "$EL_OUT"
    exit 0
  fi
  rm -f "$EL_OUT" 2>/dev/null
fi

if [ -z "${TEXTO_LIMPIO// }" ]; then
  echo "ERROR: no quedo nada para decir despues de limpiar el texto" >&2
  exit 1
fi

# SERVIDOR DE VOZ SIEMPRE ENCENDIDO (2026-07-27).
# Medido: armar todo de cero costaba 2,70 s incluso para decir "Hola." -- 0,33 s de arrancar
# python, 0,54 s de importar la libreria y el resto en autenticar y abrir gRPC. Ese costo fijo
# es lo que impedia que Mentis hablara por frases sin huecos entre oracion y oracion.
# Con el servidor levantado la conexion ya esta abierta y sintetizar es un curl.
# Si el servidor no esta o falla, se cae al camino de siempre: la voz nunca se pierde por esto.
_tts_puerto() {
  [ -f "$TTS_ESTADO" ] || return 1
  grep -oE '"puerto"[: ]+[0-9]+' "$TTS_ESTADO" 2>/dev/null | grep -oE '[0-9]+$'
}
_tts_vivo() {
  local p; p="$(_tts_puerto)" || return 1
  [ -n "$p" ] || return 1
  curl -s -m 3 "http://127.0.0.1:$p/salud" 2>/dev/null | grep -q '"ok": *true'
}
# Mata el servidor anterior antes de levantar otro (2026-07-28). Sin esto, cada vez que el
# chequeo de salud fallaba -- y falla por poco: 3 s de timeout alcanzan para dar un falso
# negativo si la maquina esta cargada -- se borraba el archivo de estado y se arrancaba un
# servidor NUEVO, dejando el anterior vivo y huerfano, con su conexion gRPC abierta y su modelo
# de voz en memoria. Medido hoy: DOS servidores corriendo a la vez (PIDs 8628 y 20280). El
# archivo de estado guarda el pid justamente para esto; nadie lo estaba usando.
_tts_matar_anterior() {
  local pid
  if [ -f "$TTS_ESTADO" ]; then
    pid="$(grep -oE '"pid"[: ]+[0-9]+' "$TTS_ESTADO" 2>/dev/null | grep -oE '[0-9]+$')"
    if [ -n "$pid" ]; then
      # El pid lo escribe python, que es nativo de Windows: es un PID de Windows, no de MSYS.
      # La doble barra es el idioma de Git Bash para que no convierta /F en una ruta (ERR-004).
      taskkill //F //PID "$pid" >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null || true
      echo "[mentis-tts] servidor de voz anterior (pid $pid) dado de baja antes de levantar el nuevo" >&2
    fi
  fi
  # Barrido de HUERFANOS: matar el pid del archivo de estado alcanza para no acumular de acá en
  # adelante, pero no limpia los que ya quedaron dando vueltas de sesiones anteriores (medido:
  # 3 servidores vivos, cada uno con su modelo de voz en memoria y su conexión gRPC abierta).
  # Como esto corre justo ANTES de levantar el nuevo, en este momento no hay ninguno que valga
  # la pena conservar: se barren todos y queda uno solo.
  powershell.exe -NoProfile -NonInteractive -Command "
    Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" |
      Where-Object { \$_.CommandLine -like '*nv_tts_server*' } |
      ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
  " >/dev/null 2>&1 || true
}

_tts_encender() {
  _tts_vivo && return 0
  _tts_matar_anterior
  rm -f "$TTS_ESTADO" 2>/dev/null
  local key fid
  key="${NVIDIA_KEY_VOZ_PARLANCHIN:-$(nv_read_setting NVIDIA_KEY_VOZ_PARLANCHIN 2>/dev/null)}"
  fid="$(nv_read_setting MENTIS_VOZ_FUNCTION_ID 2>/dev/null)"
  [ -n "${key// }" ] || return 1
  [ -n "${fid// }" ] || fid="877104f7-e885-42b9-8de8-f6e4c6303969"   # magpie-tts-multilingual
  # El 'cd' NO es cosmetico (ERR-106): sin el, el servidor hereda como cwd la carpeta desde la que
  # lo llamaron -- que cuando lo prende la app es la carpeta de la app -- y Windows no deja
  # borrar/reemplazar un directorio que algun proceso tiene abierto como cwd. Resultado: empaquetar
  # fallaba con EBUSY y no habia forma de saber por que. El servidor no usa rutas relativas para
  # nada (solo abre lo que recibe por argumento, todo absoluto), asi que mudarlo no le afecta.
  ( cd "${HOME:-/}" 2>/dev/null || cd /
    nohup python3 "$HERE/engine/nv_tts_server.py" --puerto 0 --estado "$TTS_ESTADO" \
      --api-key "$key" --function-id "$fid" --voz "$MENTIS_VOZ" \
      >/dev/null 2>>"$HERE/tts-server.log" & ) 2>/dev/null
  local i
  for i in $(seq 1 40); do
    _tts_vivo && return 0
    sleep 0.25
  done
  return 1
}

TTS_ESTADO="${MENTIS_TTS_ESTADO:-$HERE/tts-server-state.json}"

if [ "${MENTIS_TTS_SERVIDOR:-1}" = "1" ] && _tts_encender; then
  TTS_PUERTO="$(_tts_puerto)"
  # La ruta de salida va en formato WINDOWS (2026-07-28). Del otro lado hay un python nativo que
  # no entiende rutas MSYS: mandándole "/c/Users/..." creaba el archivo en "C:\c\Users\..." --
  # medido, el.wav aparecía ahí y nadie lo encontraba. El script no veía el archivo, daba el
  # servidor por fallado y se caía al camino directo, que es 1,2 s más lento POR FRASE. Es decir:
  # el servidor de voz estaba entregando su trabajo en una carpeta fantasma cada vez que a
  # mentis-tts.sh lo llamaba un script (tareas programadas, disparadores, consola). Desde la app no
  # pasaba, porque main.js ya le pasa rutas de Windows -- por eso nunca se notó. (ERR-004/006)
  TTS_SALIDA_WIN="$(nv_winpath "$SALIDA")"
  # Sin JSON y sin python: ruta en la primera linea, texto en el resto. Armar el JSON del pedido
  # costaba un arranque de interprete (~1,5 s en Windows) y se comia buena parte de lo que el
  # servidor venia a ahorrar.
  TTS_RES="$(printf '%s\n%s' "$TTS_SALIDA_WIN" "$TEXTO_LIMPIO" \
             | curl -s -m 60 -X POST "http://127.0.0.1:$TTS_PUERTO/decir-plano" \
                    --data-binary @- 2>/dev/null)"
  if printf '%s' "$TTS_RES" | grep -q '"ok": *true' && [ -s "$SALIDA" ]; then
    printf '%s\n' "$SALIDA"
    exit 0
  fi
  echo "AVISO: el servidor de voz no respondio bien, uso el camino directo" >&2
fi

RES="$(python3 "$HERE/engine/nv_tts.py" --texto "$TEXTO_LIMPIO" --voz "$MENTIS_VOZ" \
        --modelo magpie --salida "$SALIDA" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$RES" >&2
  exit "$RC"
fi
printf '%s\n' "$SALIDA"
