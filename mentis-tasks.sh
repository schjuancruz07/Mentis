#!/usr/bin/env bash
# mentis-tasks.sh -- tracking de tareas de una sesion larga, analogo a TaskCreate/TaskUpdate/
# TaskList de Claude Code. Un archivo JSON por directorio de trabajo (ROOT):.mentis-tasks.json
# vive DENTRO de ese ROOT (no en Mentis/, para que cada workspace tenga sus propias tareas y no
# se mezclen entre conversaciones con raices distintas).
#
# Uso:
#   mentis-tasks.sh create <root> "<subject>" "<description>"   -> crea, status=pending, imprime id
#   mentis-tasks.sh update <root> <id> <status>                  -> status: pending|in_progress|completed
#   mentis-tasks.sh list <root>                                  -> lista todas (id, status, subject)
set -uo pipefail

CMD="${1:-}"; ROOT="${2:-}"
[ -z "$CMD" ] || [ -z "$ROOT" ] && { echo "Uso: mentis-tasks.sh create|update|list <root>..." >&2; exit 1; }
[ -d "$ROOT" ] || { echo "ERROR: no existe el directorio raiz: $ROOT" >&2; exit 1; }
TASKS_FILE="$ROOT/.mentis-tasks.json"
[ -f "$TASKS_FILE" ] || printf '[]' > "$TASKS_FILE"

case "$CMD" in
  create)
    SUBJECT="${3:-}"; DESC="${4:-}"
    if [ -z "$SUBJECT" ]; then
      echo "ERROR: falta subject. Uso: mentis-tasks.sh create <root> \"<subject>\" \"<description>\"" >&2
      exit 1
    fi
    MC_TS_SUBJECT="$SUBJECT" MC_TS_DESC="$DESC" python3 -c '
import json, os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    tasks = json.load(f)
new_id = (max((t["id"] for t in tasks), default=0)) + 1
tasks.append({
    "id": new_id,
    "subject": os.environ.get("MC_TS_SUBJECT", ""),
    "description": os.environ.get("MC_TS_DESC", ""),
    "status": "pending",
})
with open(path, "w", encoding="utf-8") as f:
    json.dump(tasks, f, ensure_ascii=False, indent=2)
print(f"Tarea #{new_id} creada.")
' "$TASKS_FILE"
    ;;
  update)
    ID="${3:-}"; STATUS="${4:-}"
    if [[ ! "$ID" =~ ^[0-9]+$ ]]; then
      echo "ERROR: id invalido. Uso: mentis-tasks.sh update <root> <id> <status>" >&2
      exit 1
    fi
    if [[ ! "$STATUS" =~ ^(pending|in_progress|completed)$ ]]; then
      echo "ERROR: status invalido '$STATUS'. Usa pending|in_progress|completed." >&2
      exit 1
    fi
    MC_TS_ID="$ID" MC_TS_STATUS="$STATUS" python3 -c '
import json, os, sys
path = sys.argv[1]
target = int(os.environ["MC_TS_ID"])
status = os.environ["MC_TS_STATUS"]
with open(path, encoding="utf-8") as f:
    tasks = json.load(f)
found = False
for t in tasks:
    if t["id"] == target:
        t["status"] = status
        found = True
        break
if not found:
    print(f"ERROR: no existe la tarea #{target}")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    json.dump(tasks, f, ensure_ascii=False, indent=2)
print(f"Tarea #{target} -> {status}")
' "$TASKS_FILE"
    ;;
  list)
    python3 -c '
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    tasks = json.load(f)
if not tasks:
    print("(sin tareas)")
else:
    for t in tasks:
        marca = {"pending": "[ ]", "in_progress": "[~]", "completed": "[x]"}.get(t["status"], "[?]")
        tid, subj, stat = t["id"], t["subject"], t["status"]
        print(f"{marca} #{tid} {subj} ({stat})")
' "$TASKS_FILE"
    ;;
  *)
    echo "Uso: mentis-tasks.sh create|update|list <root>..." >&2
    exit 1
    ;;
esac
