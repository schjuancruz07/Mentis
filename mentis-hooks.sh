#!/usr/bin/env bash
# mentis-hooks.sh -- motor de hooks de Mentis (analogo a los hooks de settings.json de Claude
# Code). Lee hooks.json, corre los comandos registrados para el evento pedido, y devuelve por
# stdout el texto que cada uno haya impreso (para que el llamador lo inyecte como contexto
# adicional). Fail-safe: un hook que falla, tarda de mas, o no existe NUNCA corta el turno de
# Mentis -- solo se pierde ese aviso puntual. MENTIS_HOOKS_OFF=1 desactiva todo el motor.
#
# Uso:
#   mentis-hooks.sh <evento>
#     Variables de entorno opcionales que los hooks pueden leer (segun el evento):
#       MENTIS_HOOK_MSG      -- mensaje nuevo del usuario (UserPromptSubmit)
#       MENTIS_HOOK_ANSWER   -- respuesta final de Mentis (Stop)
#       MENTIS_HOOK_ROOT     -- directorio raiz de trabajo de la conversacion
#
# Formato de hooks.json:
#   {"hooks": {"<Evento>": [{"command": "...", "description": "..."}]}}
#
# Eventos soportados: SessionStart, UserPromptSubmit, Stop.
set -uo pipefail
[ "${MENTIS_HOOKS_OFF:-0}" = "1" ] && exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_FILE="$HERE/hooks.json"
EVENT="${1:-}"
[ -z "$EVENT" ] && { echo "Uso: mentis-hooks.sh <evento>" >&2; exit 1; }
[ -f "$HOOKS_FILE" ] || exit 0

# Cada comando corre con timeout 10s y su fallo se ignora -- un hook roto no debe frenar a
# Mentis. Solo se imprime lo que el hook mando a STDOUT (no stderr, para no ensuciar el
# contexto inyectado con ruido de debug de los propios hooks).
python3 -c '
import json, sys, subprocess, os

hooks_file = sys.argv[1]
event = sys.argv[2]
try:
    with open(hooks_file, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

entries = (data.get("hooks") or {}).get(event) or []
outputs = []
for entry in entries:
    cmd = (entry or {}).get("command", "").strip()
    if not cmd:
        continue
    try:
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=10, env=os.environ)
        out = (r.stdout or "").strip()
        if out:
            outputs.append(out)
    except Exception:
        continue

if outputs:
    print("\n".join(outputs))
' "$HOOKS_FILE" "$EVENT"
