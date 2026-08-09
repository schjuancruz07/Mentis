#!/usr/bin/env bash
# mentis-tts-eleven.sh -- voz por ElevenLabs, con la cuota contada a mano (2026-08-03, D del plan).
#
# POR QUE EXISTE: medido contra la misma frase en español, ElevenLabs Flash entrega el primer byte
# de audio en 390 ms y termina en 491 ms. El TTS actual (NVIDIA Magpie) tarda entre 2.399 y
# 3.465 ms. Son 5 a 7 veces mas rapido, y en una conversacion hablada eso es la diferencia entre
# contestar y hacer esperar.
#
# POR QUE NO REEMPLAZA AL ACTUAL: la cuota gratuita son 10.000 creditos por mes. Flash cuesta
# 0,5 creditos por caracter (medido: 30 caracteres -> cabecera 'character-cost: 15'), o sea
# 20.000 caracteres mensuales. El volumen real de voz del usuario es de 48.681 caracteres por mes.
# Alcanza para el 41%. Por eso esto es SELECTIVO: las frases cortas -- avisos, confirmaciones, lo
# que se escucha mientras uno espera -- por aca; los textos largos por NVIDIA, que es gratis e
# ilimitado.
#
# LA CUENTA SE LLEVA ACA Y NO SE CONSULTA A LA API, y no es por gusto: esta API key no tiene los
# permisos 'user_read' ni 'voices_read' (verificado: contesta 'missing_permissions'). No hay forma
# de preguntarle a ElevenLabs cuanto queda. Pero SI devuelve 'character-cost' en cada respuesta,
# asi que se suma lo gastado en un archivo local con reinicio mensual. Si la cuenta local se
# desincroniza, el peor caso es que ElevenLabs devuelva 401 y se caiga a NVIDIA -- que es
# exactamente lo que pasa cuando se acaba la cuota de verdad.
#
# Uso:
#   mentis-tts-eleven.sh "texto" [salida.mp3]   -> genera el audio (imprime la ruta)
#   mentis-tts-eleven.sh --cuota                -> cuanto se lleva gastado este mes
#   mentis-tts-eleven.sh --voces                -> las voces que sirven en el plan gratuito
#   mentis-tts-eleven.sh --probar               -> genera una muestra con cada voz para elegir
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

CUOTA_ARCHIVO="${MENTIS_EL_CUOTA:-$HERE/eleven-cuota.json}"
# 9.000 y no 10.000: si la cuenta local se corre un poco, mejor que sobre. Quedarse sin voz a
# mitad de mes por haber apurado el ultimo 10% no vale la pena.
PRESUPUESTO="${MENTIS_EL_PRESUPUESTO:-9000}"
MODELO="${MENTIS_EL_MODELO:-eleven_flash_v2_5}"
# Sarah. Se puede cambiar con MENTIS_EL_VOZ; --probar genera una muestra de cada una para elegir.
VOZ="${MENTIS_EL_VOZ:-EXAVITQu4vr4xnSDxMaL}"

# Las tres que funcionan en el plan gratuito (probadas una por una: el resto da
# 'paid_plan_required' porque son de la biblioteca compartida).
VOCES_LIBRES="EXAVITQu4vr4xnSDxMaL:Sarah pNInz6obpgDQGcFmaJgB:Adam ErXwobaYiN019PkySvjV:Antoni"

_key() {
  [ -n "${ELEVENLABS_API_KEY:-}" ] && { printf '%s' "$ELEVENLABS_API_KEY"; return 0; }
  local f="$HERE/.secrets.env"
  [ -f "$f" ] && grep -oE 'ELEVENLABS_API_KEY=[^"]*' "$f" 2>/dev/null | head -1 | cut -d= -f2- && return 0
  python3 -c '
import json, os, sys
p = os.path.expanduser("~/.claude/settings.json")
try:
    with open(p, encoding="utf-8") as f:
        print((json.load(f).get("env") or {}).get("ELEVENLABS_API_KEY", ""), end="")
except Exception:
    pass' 2>/dev/null
}

_gastado() {
  python3 - "$(cygpath -w "$CUOTA_ARCHIVO" 2>/dev/null || printf '%s' "$CUOTA_ARCHIVO")" <<'PY'
import json, sys, datetime, os
ruta = sys.argv[1]
mes = datetime.date.today().strftime("%Y-%m")
try:
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
print(int(d.get(mes, 0)))
PY
}

_sumar() {
  python3 - "$(cygpath -w "$CUOTA_ARCHIVO" 2>/dev/null || printf '%s' "$CUOTA_ARCHIVO")" "$1" <<'PY'
import json, sys, datetime
ruta, costo = sys.argv[1], int(sys.argv[2])
mes = datetime.date.today().strftime("%Y-%m")
try:
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
d[mes] = int(d.get(mes, 0)) + costo
# Se guardan solo los ultimos 6 meses: es un contador, no un historial.
for k in sorted(d)[:-6]:
    del d[k]
with open(ruta, "w", encoding="utf-8") as f:
    json.dump(d, f)
print(d[mes])
PY
}

case "${1:-}" in
  --cuota)
    G="$(_gastado)"
    echo "Creditos de ElevenLabs usados en $(date +%Y-%m): $G de $PRESUPUESTO"
    echo "Equivale a unos $(( (PRESUPUESTO - G) * 2 )) caracteres que todavia se pueden decir con esta voz."
    echo "(el plan gratuito da 10.000 por mes; el presupuesto local deja margen a proposito)"
    exit 0 ;;
  --voces)
    for par in $VOCES_LIBRES; do printf '  %s  %s\n' "${par%%:*}" "${par#*:}"; done
    echo "Elegí una con MENTIS_EL_VOZ=<id>. Las demas voces de ElevenLabs son de la biblioteca"
    echo "compartida y el plan gratuito no las deja usar por API (dan 402)."
    exit 0 ;;
  --probar) : ;;
  ""|-h|--help)
    sed -n '2,26p' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

KEY="$(_key)"
if [ -z "$KEY" ]; then
  echo "ERROR: falta ELEVENLABS_API_KEY (env,.secrets.env o settings.json)." >&2
  exit 1
fi

# --probar: una muestra por voz, para que el usuario elija con el oido y no con la descripcion.
if [ "${1:-}" = "--probar" ]; then
  DEST="${2:-$HOME/Documents/Mentis/Voz-pruebas}"
  mkdir -p "$DEST"
  TXT="Hola el usuario. Ya guardé el archivo en tu carpeta de documentos, y el respaldo de hoy terminó bien."
  for par in $VOCES_LIBRES; do
    ID="${par%%:*}"; NOM="${par#*:}"
    OUT="$DEST/muestra-$NOM.mp3"
    if MENTIS_EL_VOZ="$ID" bash "$0" "$TXT" "$OUT" >/dev/null 2>&1; then
      echo "  $NOM -> $(cygpath -w "$OUT" 2>/dev/null || printf '%s' "$OUT")"
    else
      echo "  $NOM -> fallo"
    fi
  done
  echo
  echo "Escuchalas y decime cual. Se fija con MENTIS_EL_VOZ=<id> (--voces lista los ids)."
  exit 0
fi

TEXTO="${1:-}"
SALIDA="${2:-}"
if [ -z "${TEXTO// }" ]; then
  echo "ERROR: no hay texto que decir." >&2
  exit 2
fi

# Freno de cuota ANTES de llamar. El costo se estima con la regla medida (0,5 creditos por
# caracter en flash) y se compara con lo que queda; asi nunca se pasa por un pelo.
LARGO=${#TEXTO}
COSTO_EST=$(( (LARGO + 1) / 2 ))
GASTADO="$(_gastado)"
if [ $(( GASTADO + COSTO_EST )) -gt "$PRESUPUESTO" ]; then
  echo "SIN_CUOTA: quedan $(( PRESUPUESTO - GASTADO )) creditos y esta frase necesita ~$COSTO_EST." >&2
  exit 3
fi

[ -n "$SALIDA" ] || SALIDA="$(mktemp -u).mp3"
CAB="$(mktemp)"

# El JSON se arma con python y no interpolando en bash: una tilde en el texto rompe el UTF-8 del
# cuerpo y ElevenLabs contesta 'invalid_unicode'. Paso de verdad probando esto -- y la respuesta
# de error pesa 95 bytes, o sea que un chequeo por tamaño la habria dado por buena.
CUERPO="$(mktemp)"
MENTIS_EL_TXT="$TEXTO" MENTIS_EL_MOD="$MODELO" python3 -c '
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")
print(json.dumps({"text": os.environ["MENTIS_EL_TXT"], "model_id": os.environ["MENTIS_EL_MOD"]}))
' > "$CUERPO"

HTTP="$(curl -s -m 60 -w '%{http_code}' -o "$SALIDA" -D "$CAB" \
  -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOZ/stream" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  --data-binary "@$CUERPO")"
rm -f "$CUERPO"

if [ "$HTTP" != "200" ]; then
  echo "ERROR: ElevenLabs contesto $HTTP. $(head -c 200 "$SALIDA" 2>/dev/null | tr -d '\0')" >&2
  rm -f "$CAB" "$SALIDA"
  exit 4
fi

# El costo REAL sale de la cabecera, no de la estimacion: es el unico dato firme que da esta API
# con los permisos que tiene la key.
COSTO="$(grep -i '^character-cost:' "$CAB" 2>/dev/null | tr -d '\r' | awk '{print $2}')"
[ -n "$COSTO" ] || COSTO="$COSTO_EST"
rm -f "$CAB"
TOTAL="$(_sumar "$COSTO")"

printf '%s\n' "$SALIDA"
echo "[eleven] $LARGO caracteres, $COSTO creditos. Van $TOTAL de $PRESUPUESTO este mes." >&2
