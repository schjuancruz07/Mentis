#!/usr/bin/env bash
# mentis-camara.sh -- prender y apagar la cámara por voz, sin tocar ningún menú.
#
# POR QUE EXISTE:
#   La cámara arranca APAGADA a propósito (ERR-103: durante un tiempo estuvo encendida por defecto
#   pese a tres comentarios que juraban lo contrario, y eso no se puede repetir). Pero prenderla
#   exigía ir a Directorio -> Conectores en la app, que es justo lo que uno no quiere hacer cuando
#   está con las manos ocupadas mostrándole algo a la cámara.
#
#   Esto lo vuelve una frase. El interruptor sigue siendo el MISMO que el de la app -- el conector
#   'local:webcam' de mentis-settings.json -- así que no hay dos verdades sobre si la cámara está
#   prendida: hay una sola, y se puede cambiar desde los dos lados.
#
# Uso:
#   mentis-camara.sh prender | apagar | estado
set -uo pipefail
export PYTHONIOENCODING=utf-8

MC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_SETTINGS="${MENTIS_SETTINGS_FILE:-$MC_HERE/mentis-settings.json}"
MC_CONECTOR="local:webcam"

_mc_estado() {
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
print("1" if (d.get("connectorsEnabled") or {}).get(sys.argv[2]) else "0")
' "$(cygpath -w "$MC_SETTINGS" 2>/dev/null || printf '%s' "$MC_SETTINGS")" "$MC_CONECTOR" 2>/dev/null || echo 0
}

_mc_poner() {
  MCP_VAL="$1" python3 -c '
import json, os, sys
ruta, clave = sys.argv[1], sys.argv[2]
try:
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d.setdefault("connectorsEnabled", {})
d["connectorsEnabled"][clave] = os.environ["MCP_VAL"] == "1"
# Escritura atomica: este archivo lo lee la app en vivo, y pescarlo a medio escribir la dejaria
# sin configuracion.
tmp = ruta + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.replace(tmp, ruta)
' "$(cygpath -w "$MC_SETTINGS" 2>/dev/null || printf '%s' "$MC_SETTINGS")" "$MC_CONECTOR" 2>/dev/null
}

case "${1:-estado}" in
  prender|encender|prende|abri|abrir)
    if [ "$(_mc_estado)" = "1" ]; then echo "La camara ya estaba prendida."; exit 0; fi
    _mc_poner 1 || { echo "No pude cambiar la configuracion." >&2; exit 1; }
    [ "$(_mc_estado)" = "1" ] || { echo "El cambio no quedo guardado." >&2; exit 1; }
    echo "Camara PRENDIDA. Se apaga diciendo 'apaga la camara'."
    ;;
  apagar|apaga|cerra|cerrar)
    if [ "$(_mc_estado)" = "0" ]; then echo "La camara ya estaba apagada."; exit 0; fi
    _mc_poner 0 || { echo "No pude cambiar la configuracion." >&2; exit 1; }
    [ "$(_mc_estado)" = "0" ] || { echo "El cambio no quedo guardado." >&2; exit 1; }
    echo "Camara APAGADA."
    ;;
  estado)
    [ "$(_mc_estado)" = "1" ] && echo "La camara esta PRENDIDA." || echo "La camara esta APAGADA."
    ;;
  *)
    echo "Uso: mentis-camara.sh prender|apagar|estado" >&2; exit 2 ;;
esac
