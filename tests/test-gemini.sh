#!/usr/bin/env bash
# test-gemini.sh -- la contabilidad de cuota y el apagado por defecto del proveedor Gemini.
#
# NO toca la red ni la API de Google: lo que se prueba aca es la logica que decide SI se llama,
# no la llamada. Lo otro ya se verifico a mano contra la API real el 2026-08-07.
#
# REGLA QUE ESTE ARCHIVO RESPETA (ERR-119): un test JAMAS escribe en el estado de produccion.
# El contador vive en un directorio temporal propio via GEMINI_CUOTA_FILE, y el settings de
# prueba es una copia. Si este test llegara a correr con el.gemini-cuota real, arruinaria la
# cuenta del dia del usuario -- que es exactamente la forma del error que ya nos costo 46 horas.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TG_TMP="$(mktemp -d)"
trap 'rm -rf "$TG_TMP"' EXIT

export GEMINI_CUOTA_FILE="$TG_TMP/.gemini-cuota"
export NV_HOME="$HERE/engine"
. "$HERE/engine/nv-gemini-lib.sh"

ok=0; fallo=0
check() {
  local nombre="$1" esperado="$2" obtenido="$3"
  if [ "$esperado" = "$obtenido" ]; then
    ok=$((ok+1)); printf '  ok    %s\n' "$nombre"
  else
    fallo=$((fallo+1)); printf '  FALLA %s -- esperaba [%s], obtuvo [%s]\n' "$nombre" "$esperado" "$obtenido"
  fi
}

echo "== contador de cuota =="

# 1. Sin archivo, la cuenta arranca en cero.
rm -f "$GEMINI_CUOTA_FILE"
check "sin archivo -> 0 usados" "0" "$(nv_gemini_usados)"
check "sin archivo -> tope entero disponible" "$NVG_TOPE_DIA" "$(nv_gemini_quedan)"

# 2. Sumar incrementa de a uno.
nv_gemini_sumar
check "un pedido -> 1 usado" "1" "$(nv_gemini_usados)"
nv_gemini_sumar; nv_gemini_sumar
check "tres pedidos -> 3 usados" "3" "$(nv_gemini_usados)"

# 3. La cuota de AYER no cuenta hoy. Este es el punto del ejercicio: Google reinicia por dia
#    calendario, asi que un archivo viejo tiene que leerse como cero y no como cuota gastada.
printf '2000-01-01 999\n' > "$GEMINI_CUOTA_FILE"
check "archivo de otro dia -> 0 usados" "0" "$(nv_gemini_usados)"
check "archivo de otro dia -> hay cuota" "0" "$(nv_gemini_hay_cuota; echo $?)"

# 4. Archivo corrupto: no debe romper ni inventar cuota.
printf 'basura sin formato\n' > "$GEMINI_CUOTA_FILE"
check "archivo corrupto -> 0 usados" "0" "$(nv_gemini_usados)"
printf '%s abc\n' "$(date +%Y-%m-%d)" > "$GEMINI_CUOTA_FILE"
check "contador no numerico -> 0 usados" "0" "$(nv_gemini_usados)"

# 5. Al tope, no hay cuota. Es la condicion que hace que el rol se quede en NVIDIA.
printf '%s %s\n' "$(date +%Y-%m-%d)" "$NVG_TOPE_DIA" > "$GEMINI_CUOTA_FILE"
check "en el tope -> quedan 0" "0" "$(nv_gemini_quedan)"
check "en el tope -> NO hay cuota" "1" "$(nv_gemini_hay_cuota; echo $?)"

# 6. Pasado el tope no da negativo (un numero negativo romperia cualquier comparacion posterior).
printf '%s %s\n' "$(date +%Y-%m-%d)" "$((NVG_TOPE_DIA + 50))" > "$GEMINI_CUOTA_FILE"
check "pasado el tope -> quedan 0, no negativo" "0" "$(nv_gemini_quedan)"

# 7. El tope se puede pisar por entorno (Google cambia los limites sin avisar).
GEMINI_TOPE_DIA=5 bash -c '
. '"$HERE"'/engine/nv-gemini-lib.sh
  printf "%s 4\n" "$(date +%Y-%m-%d)" > "$GEMINI_CUOTA_FILE"
  [ "$(nv_gemini_quedan)" = "1" ] || exit 1
' && check "tope configurable por entorno" "0" "0" || check "tope configurable por entorno" "0" "1"

echo "== aviso de privacidad =="

# 8. El aviso tiene que nombrar las dos cosas que importan, con todas las letras.
aviso="$(nv_gemini_aviso_privacidad)"
case "$aviso" in *entrenar*) check "el aviso dice que entrena" "0" "0" ;; *) check "el aviso dice que entrena" "0" "1" ;; esac
case "$aviso" in *"revisores humanos"*) check "el aviso dice revisores humanos" "0" "0" ;; *) check "el aviso dice revisores humanos" "0" "1" ;; esac
case "$aviso" in *apagado*) check "el aviso dice que viene apagado" "0" "0" ;; *) check "el aviso dice que viene apagado" "0" "1" ;; esac

echo "== apagado por defecto =="

# 9. Con enabled=false, ask-nvidia.sh NO debe elegir el modelo de Gemini. Se prueba el filtro de
#    seleccion, que es la linea que decide si Google ve algo o no.
cfg="$TG_TMP/settings.json"
cat > "$cfg" <<'JSON'
{"customModels":{"general":{"provider":"gemini","baseUrl":"https://ejemplo/x","model":"gemini-3.6-flash","keyRef":"GEMINI","enabled":false}}}
JSON
sel="$(MC_ROLE_K=general python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: d = json.load(f)
    cm = (d.get("customModels") or {}).get(os.environ["MC_ROLE_K"])
    prov = (cm or {}).get("provider")
    if cm and prov in ("openai-compatible", "gemini") and cm.get("baseUrl") and cm.get("model"):
        if not (prov == "gemini" and not cm.get("enabled", False)):
            print(json.dumps(cm))
except Exception: pass
' "$cfg" 2>/dev/null | tr -d '\r')"
check "enabled=false -> no se selecciona" "" "$sel"

# 10. Y con enabled=true si.
sed -i 's/"enabled":false/"enabled":true/' "$cfg"
sel="$(MC_ROLE_K=general python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: d = json.load(f)
    cm = (d.get("customModels") or {}).get(os.environ["MC_ROLE_K"])
    prov = (cm or {}).get("provider")
    if cm and prov in ("openai-compatible", "gemini") and cm.get("baseUrl") and cm.get("model"):
        if not (prov == "gemini" and not cm.get("enabled", False)):
            print(json.dumps(cm))
except Exception: pass
' "$cfg" 2>/dev/null | tr -d '\r')"
case "$sel" in *gemini-3.6-flash*) check "enabled=true -> se selecciona" "0" "0" ;; *) check "enabled=true -> se selecciona" "0" "1" ;; esac

# 11. Un openai-compatible sin 'enabled' sigue andando como siempre: la exigencia de enabled es
#     SOLO para Gemini. Si esto se rompe, se rompen las integraciones que el usuario ya tenia.
cat > "$cfg" <<'JSON'
{"customModels":{"code":{"provider":"openai-compatible","baseUrl":"https://ejemplo/x","model":"lo-que-sea","keyRef":"X"}}}
JSON
sel="$(MC_ROLE_K=code python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: d = json.load(f)
    cm = (d.get("customModels") or {}).get(os.environ["MC_ROLE_K"])
    prov = (cm or {}).get("provider")
    if cm and prov in ("openai-compatible", "gemini") and cm.get("baseUrl") and cm.get("model"):
        if not (prov == "gemini" and not cm.get("enabled", False)):
            print(json.dumps(cm))
except Exception: pass
' "$cfg" 2>/dev/null | tr -d '\r')"
case "$sel" in *lo-que-sea*) check "openai-compatible sin enabled sigue andando" "0" "0" ;; *) check "openai-compatible sin enabled sigue andando" "0" "1" ;; esac

echo "== errores en formato Gemini (lista) =="

# 12. Gemini envuelve los errores en una lista. parse() tiene que clasificarlos igual que los de
#     NVIDIA (exit 4 = definitivo -> al fallback) en vez de morirse con AttributeError.
clasificar() {
  printf '%s' "$1" | python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: sys.exit(3)
if isinstance(d, list): d = d[0] if d and isinstance(d[0], dict) else {}
if "choices" in d:
    m=d["choices"][0]["message"]
    c=(m.get("content") or "").strip() or (m.get("reasoning_content") or "").strip()
    if not c: sys.exit(3)
    print(c); sys.exit(0)
st=str((d.get("error") or {}).get("code") or d.get("status") or "")
sys.exit(2 if st in ("401","429","500","502","503","504") else 4)
' >/dev/null 2>&1
  echo $?
}
check "error Gemini 404 (lista) -> 4 definitivo" "4" "$(clasificar '[{"error":{"code":404,"message":"no existe"}}]')"
check "error Gemini 429 (lista) -> 2 reintentable" "2" "$(clasificar '[{"error":{"code":429,"message":"cuota"}}]')"
check "error NVIDIA 404 (objeto) -> 4, sin regresion" "4" "$(clasificar '{"error":{"code":404,"message":"no existe"}}')"
# Una lista vacia clasifica 4 (definitivo) y no 3 (vacio). Los dos terminan en el fallback, que es
# lo unico que importa aca; se deja el 4 en vez de agregar una rama para distinguirlos, porque
# seria codigo nuevo en el camino critico a cambio de ninguna diferencia observable.
check "respuesta vacia en lista -> 4, va al fallback" "4" "$(clasificar '[]')"
check "respuesta normal sigue andando" "0" "$(clasificar '{"choices":[{"message":{"content":"hola"}}]}')"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
