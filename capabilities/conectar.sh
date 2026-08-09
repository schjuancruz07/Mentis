# CAPABILITY: /conectar | Da de alta un conector MCP nuevo (paquete npm o URL remota) en mcp-servers.json, con reload en caliente si el puente ya está corriendo
#
# Pedido del usuario, 2026-07-13: una skill para que Mentis pueda "conectarse a X" cuando se lo
# piden por chat, en vez de que el usuario tenga que editar mcp-servers.json a mano. Límite honesto:
# NO inventa credenciales -- si el conector necesita autenticación, el usuario tiene que pasarla como
# VAR=valor en el mismo mensaje (se guarda separada del JSON, referenciada por ${VAR}, mismo
# patrón que el resto del bridge). Sin eso, deja el conector armado pero sin secreto, y lo dice.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$(cd "$DIR/.." && pwd)"
CONFIG="$MENTIS_ENV_DIR/mcp-bridge/mcp-servers.json"
SECRETS="$MENTIS_ENV_DIR/mcp-bridge/.secrets.env"
STATEFILE="$MENTIS_ENV_DIR/mcp-bridge-state.json"

read -r -a WORDS <<< "${1:-}"
NAME="${WORDS[0]:-}"
TARGET="${WORDS[1]:-}"

if [ -z "$NAME" ] || [ -z "$TARGET" ]; then
  echo "Uso: /conectar <nombre> <paquete-npm-o-url> [VARIABLE=valor...]"
  echo "Ejemplos:"
  echo "  /conectar supabase @supabase/mcp-server-supabase SUPABASE_ACCESS_TOKEN=sbp_xxx"
  echo "  /conectar mi-api https://api.example.com/mcp AUTH_TOKEN=xxx"
  exit 0
fi

VAR_ARGS=("${WORDS[@]:2}")

NAME="$NAME" TARGET="$TARGET" python3 - "$CONFIG" "$SECRETS" "${VAR_ARGS[@]}" <<'PYEOF'
import json, os, sys

config_path = sys.argv[1]
secrets_path = sys.argv[2]
var_args = sys.argv[3:]
name = os.environ["NAME"]
target = os.environ["TARGET"]

secrets = {}
if os.path.exists(secrets_path):
    for line in open(secrets_path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        secrets[k.strip()] = v.strip()

placeholders = {}
for arg in var_args:
    if "=" not in arg:
        continue
    var, value = arg.split("=", 1)
    var = var.strip()
    secrets[var] = value.strip()
    placeholders[var] = f"${{{var}}}"

if secrets:
    with open(secrets_path, "w", encoding="utf-8") as f:
        f.write("# Claves reales de conectores MCP -- NO se versiona.\n")
        for k, v in secrets.items():
            f.write(f"{k}={v}\n")

try:
    config = json.load(open(config_path, encoding="utf-8"))
except Exception:
    config = []

if any(s.get("name") == name for s in config):
    print(f"Ya existe un conector llamado '{name}'. Elegí otro nombre, o desactivalo/borralo primero desde Conectores.")
    sys.exit(0)

is_remote = target.startswith("http://") or target.startswith("https://")
entry = {"name": name, "enabled": True}
if is_remote:
    entry["type"] = "http"
    entry["url"] = target
    if placeholders:
        entry["headers"] = {"Authorization": f"Bearer {list(placeholders.values())[0]}"}
else:
    entry["type"] = "stdio"
    entry["command"] = "npx"
    entry["args"] = ["--yes", target]
    if placeholders:
        entry["env"] = placeholders

config.append(entry)
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print(f"Conector '{name}' agregado ({'remoto HTTP' if is_remote else 'proceso local via npx'}: {target}).")
if placeholders:
    print(f"Guardé {len(placeholders)} secreto(s) en mcp-bridge/.secrets.env, referenciados por variable -- no quedan en texto plano en el JSON compartible.")
else:
    print(f"No pasaste ningún secreto. Si '{name}' necesita autenticación, decime de nuevo con: /conectar {name} {target} VARIABLE=valor")
PYEOF

if [ -f "$STATEFILE" ]; then
  PORT="$(python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get('port',''), end='')
except Exception:
    print('', end='')" "$STATEFILE" 2>/dev/null)"
  if [ -n "$PORT" ]; then
    curl -s -m 4 -X POST "http://127.0.0.1:$PORT/reload" >/dev/null 2>&1 && echo "(puente MCP recargado en caliente, el cambio ya está activo en esta conversación)"
  fi
fi
