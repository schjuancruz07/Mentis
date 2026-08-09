# CAPABILITY: /programar | programa una tarea puntual o diaria (Windows Task Scheduler) que corre Mentis y avisa con un popup al terminar
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="$HERE/scheduled-runs"
mkdir -p "$RUNS_DIR"
ARGS="$1"
ROOT_DEF="${ROOT:-$HERE/workspace}"

_slug() { printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '-' | cut -c1-40 | sed 's/^-*//;s/-*$//'; }

if [ -z "${ARGS// }" ]; then
  echo "Uso:"
  echo "  /programar en <N> <m|h> <tarea>       -- una vez, dentro de N minutos/horas"
  echo "  /programar diario <HH:MM> <tarea>     -- todos los dias a esa hora"
  echo "  /programar listar                     -- ver tareas programadas"
  echo "  /programar cancelar <nombre>          -- borrar una tarea programada"
  exit 0
fi

if [ "$ARGS" = "listar" ]; then
  # Bug real (2026-07-17, encontrado en skill-tests): schtasks.exe /TN NO soporta wildcards --
  # "Mentis\*" se interpretaba como un nombre de tarea LITERAL (con el asterisco incluido), que
  # nunca existe, así que /Query siempre caía al mensaje de error y listar() reportaba "(sin
  # tareas programadas)" SIEMPRE, aunque hubiera tareas reales creadas. Get-ScheduledTask sí
  # soporta filtrar por carpeta (-TaskPath), que es donde Register-ScheduledTask las crea de
  # verdad (ver más abajo, TASKNAME="Mentis\$NOMBRE").
  OUT="$(powershell.exe -NoProfile -NonInteractive -Command "
\$ErrorActionPreference = 'SilentlyContinue'
\$tasks = Get-ScheduledTask -TaskPath '\Mentis\'
if (-not \$tasks) { Write-Output '(sin tareas programadas)'; exit }
foreach (\$t in \$tasks) {
  \$info = \$t | Get-ScheduledTaskInfo
  Write-Output (\"\$(\$t.TaskName) -- estado: \$(\$t.State) -- proxima corrida: \$(\$info.NextRunTime)\")
}
" 2>&1)"
  printf '%s\n' "$OUT"
  exit 0
fi

if [[ "$ARGS" == cancelar\ * ]]; then
  NOMBRE="${ARGS#cancelar }"
  if MSYS2_ARG_CONV_EXCL='*' schtasks.exe /Delete /TN "Mentis\\$NOMBRE" /F >/dev/null 2>&1; then
    echo "Cancelada: $NOMBRE"
  else
    echo "No encontre una tarea programada llamada '$NOMBRE' (usa /programar listar para ver los nombres)"
  fi
  exit 0
fi

TAREA=""
if [[ "$ARGS" == en\ * ]]; then
  REST="${ARGS#en }"
  N="$(printf '%s' "$REST" | awk '{print $1}')"
  UNIT="$(printf '%s' "$REST" | awk '{print $2}')"
  TAREA="$(printf '%s' "$REST" | cut -d' ' -f3-)"
  case "$UNIT" in
    m|min|minutos) DUNIT="minutes" ;;
    h|hs|horas) DUNIT="hours" ;;
    *) echo "Unidad invalida: '$UNIT'. Usa 'm' (minutos) o 'h' (horas)."; exit 0 ;;
  esac
  if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    echo "N tiene que ser un numero. Uso: /programar en <N> <m|h> <tarea>"
    exit 0
  fi
  # OJO: NO usar schtasks /sd con una fecha armada a mano (ej. %m/%d/%Y) -- schtasks la
  # interpreta con el formato de fecha del LOCALE del sistema (en este equipo, DD/MM/YYYY),
  # asi que "07/12" (12 de julio en formato US) se leia como "7 de diciembre". Por eso la
  # creacion de la tarea se hace con PowerShell (Register-ScheduledTask), que no tiene esa
  # ambiguedad porque labura con objetos DateTime, no con strings de fecha.
  SCHED_MODE="once"
  if [ "$DUNIT" = "hours" ]; then TOTAL_MIN=$((N * 60)); else TOTAL_MIN=$N; fi
elif [[ "$ARGS" == diario\ * ]]; then
  REST="${ARGS#diario }"
  WHEN="$(printf '%s' "$REST" | awk '{print $1}')"
  TAREA="$(printf '%s' "$REST" | cut -d' ' -f2-)"
  if ! [[ "$WHEN" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    echo "Hora invalida: '$WHEN'. Formato HH:MM (24hs). Uso: /programar diario <HH:MM> <tarea>"
    exit 0
  fi
  SCHED_MODE="daily"
else
  echo "No entendi. Uso:"
  echo "  /programar en <N> <m|h> <tarea>"
  echo "  /programar diario <HH:MM> <tarea>"
  echo "  /programar listar"
  echo "  /programar cancelar <nombre>"
  exit 0
fi

if [ -z "${TAREA// }" ]; then
  echo "Falta la tarea. Ej: /programar en 30 m recordame revisar el mail"
  exit 0
fi

TS="$(date +%s)"
NOMBRE="$(_slug "$TAREA")-$TS"
HIST="$RUNS_DIR/$NOMBRE.jsonl"
OUTFILE="$RUNS_DIR/$NOMBRE.out"

WIN_RUNONCE="$(cygpath -w "$HERE/mentis-run-once.sh")"
WIN_ENVDIR="$(cygpath -w "$HERE")"
WIN_ROOT="$(cygpath -w "$ROOT_DEF")"
WIN_HIST="$(cygpath -w "$HIST")"
WIN_OUT="$(cygpath -w "$OUTFILE")"
WIN_BASH="$(cygpath -w "$(command -v bash)")"

# schtasks /TR tiene un limite de 261 caracteres -- el comando completo (bash + rutas + tarea)
# lo supera facil, asi que lo escribimos a un.cmd corto y /TR solo apunta a ese archivo.
CMDFILE="$RUNS_DIR/$NOMBRE.cmd"
{
  printf '@echo off\r\n'
  printf '"%s" "%s" "%s" "%s" "%s" "%s" "%s"\r\n' "$WIN_BASH" "$WIN_RUNONCE" "$WIN_ENVDIR" "$WIN_ROOT" "$WIN_HIST" "$WIN_OUT" "$TAREA"
} > "$CMDFILE"
WIN_CMDFILE="$(cygpath -w "$CMDFILE")"
TASKNAME="Mentis\\$NOMBRE"

if [ "$SCHED_MODE" = "once" ]; then
  PS_TRIGGER='New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes([int]$env:MRO_MINUTES)'
else
  PS_TRIGGER='New-ScheduledTaskTrigger -Daily -At $env:MRO_TIME'
fi

if MRO_MINUTES="${TOTAL_MIN:-0}" MRO_TIME="${WHEN:-00:00}" MRO_TASKNAME="$TASKNAME" MRO_EXEC="$WIN_CMDFILE" \
   powershell.exe -NoProfile -NonInteractive -Command "
\$ErrorActionPreference = 'Stop'
\$action = New-ScheduledTaskAction -Execute \$env:MRO_EXEC
\$trigger = $PS_TRIGGER
Register-ScheduledTask -TaskName \$env:MRO_TASKNAME -Action \$action -Trigger \$trigger -Force | Out-Null
" >/dev/null 2>&1; then
  echo "Programado como '$NOMBRE'. Cuando corra te aviso con un popup. Para cancelarla: /programar cancelar $NOMBRE"
else
  echo "ERROR: no pude crear la tarea programada."
fi
