#!/usr/bin/env bash
# test-instancia-unica.sh -- el candado de instancia unica de nv_stt_server.py (2026-08-03).
#
# QUE SE PRUEBA Y POR QUE ASI:
#   El 2026-08-03 se encontraron DOS servidores de transcripcion vivos a la vez, arrancados con
#   casi 5 horas de diferencia, cada uno con su modelo cargado: 3.236 MB de commit, la mitad
#   desperdiciados en una maquina con 2.651 MB de margen. La deteccion de "ya hay uno" era por
#   ARCHIVO (un curl de 3 s contra /salud, mas el archivo de estado), y por eso fallaba de dos
#   formas: si el servidor estaba vivo pero lento, y si el archivo de estado desaparecia.
#
#   Este test NO comprueba que la funcion exista. Reproduce los dos escenarios que crearon el
#   huerfano y comprueba que despues de cada uno quede UN SOLO proceso vivo. Esa es la unica
#   afirmacion que importa; todo lo demas es andamio.
#
#   Los servidores de prueba usan --modelo tiny (75 MB y ya esta en cache) en vez de base
#   (1,6 GB). Levantar dos 'base' para probar una fuga de memoria seria comico.
set -uo pipefail
TIU_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIU_ROOT="$(cd "$TIU_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TIU_OK=0; TIU_MAL=0
_ok()  { TIU_OK=$((TIU_OK+1));  echo "  OK   $1"; }
_mal() { TIU_MAL=$((TIU_MAL+1)); echo "  MAL  $1  ($2)"; }

TIU_TMP="$(mktemp -d)"

# ASSERT DE SEGURIDAD, NO DECORACION. Este test arranca servidores y los mata. Si por un error de
# ruta apuntara al estado REAL de Mentis, mataria el servidor de voz que el usuario esta usando y le
# borraria el archivo de estado. Ya paso algo asi con history.jsonl (ERR-109): un test escribio
# sobre datos de produccion porque la variable apuntaba donde no debia. Se aborta antes de nada.
case "$TIU_TMP" in
  "$TIU_ROOT"|"$TIU_ROOT"/*) echo "ABORTA: el temporal cae dentro de Mentis ($TIU_TMP)" >&2; exit 1 ;;
esac
[ -n "$TIU_TMP" ] && [ -d "$TIU_TMP" ] || { echo "ABORTA: no hay temporal" >&2; exit 1; }

SERVIDOR="$TIU_ROOT/engine/nv_stt_server.py"
[ -f "$SERVIDOR" ] || { echo "ABORTA: no existe $SERVIDOR" >&2; exit 1; }

# --- utilidades -------------------------------------------------------------------------------

# Los PID que maneja este test son PID de WINDOWS (los escribe el propio servidor en su archivo
# de estado), no los de MSYS que devuelve $!. Mezclarlos da falsos negativos silenciosos, asi que
# la vida se pregunta con tasklist, que habla el mismo idioma.
#
# MSYS_NO_PATHCONV=1 NO ES OPCIONAL. Sin eso, Git Bash ve el "/FI" y lo traduce a una ruta:
# tasklist recibe "C:/Program Files/Git/FI" y contesta "argumento no valido". El comando falla,
# el grep no encuentra nada y _vive devuelve "esta muerto" para TODO. Es el ERR-004/006 otra vez.
#
# Y NO SE USA UNA TUBERIA HACIA grep -q. Con 'set -o pipefail' activo, grep -q cierra la tuberia
# apenas encuentra la linea, tasklist muere de SIGPIPE y el pipeline entero devuelve error --
# JUSTO en el caso en que el proceso SI estaba. Da "muerto" para todo, igual que el bug anterior
# y por un motivo completamente distinto. La salida se captura primero y se mira despues.
_vive() {
  local pid="$1" salida
  [ -n "$pid" ] || return 1
  salida="$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" /NH /FO CSV 2>/dev/null)"
  case "$salida" in
    *"\"$pid\""*) return 0 ;;
    *)            return 1 ;;
  esac
}

_matar() { [ -n "${1:-}" ] && MSYS_NO_PATHCONV=1 taskkill /F /PID "$1" >/dev/null 2>&1; return 0; }

# EL DETECTOR SE PRUEBA A SI MISMO ANTES DE USARLO.
#
# En la primera corrida de este test, _vive estaba roto y devolvia "muerto" siempre. El chequeo
# "el huerfano fue dado de baja" APROBO -- no porque el huerfano hubiera muerto, sino porque el
# detector no veia a nadie. Una guarda escrita como ausencia ("ya no esta") da verde cuando lo
# que se rompio es la forma de mirar. Si el detector no distingue un proceso vivo de uno muerto,
# este test no tiene derecho a opinar sobre nada.
_autoverificar_detector() {
  local vivo muerto=999999
  # Los tres DEVNULL no son prolijidad. Sin ellos el proceso de control hereda el stdout de esta
  # sustitucion de comando, y $( ) espera a que se cierre esa tuberia: se queda colgada los 30
  # segundos que vive el proceso y devuelve el PID recien cuando el proceso YA MURIO. Despues
  # _vive dice, con toda la razon, que ese PID no existe -- y el test aborta culpando al detector.
  vivo="$(python3 -c "
import subprocess, sys
print(subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL).pid)
" 2>/dev/null | tr -d '\r\n ')"
  [ -n "$vivo" ] || { echo "ABORTA: no se pudo crear el proceso de control" >&2; exit 1; }
  if ! _vive "$vivo"; then
    _matar "$vivo"
    echo "ABORTA: _vive dice que un proceso VIVO ($vivo) esta muerto. El test mentiria." >&2
    exit 1
  fi
  if _vive "$muerto"; then
    _matar "$vivo"
    echo "ABORTA: _vive dice que un PID inexistente esta vivo. El test mentiria." >&2
    exit 1
  fi
  _matar "$vivo"
}

_pid_estado() { grep -oE '"pid"[: ]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+$'; }
_puerto_estado() { grep -oE '"puerto"[: ]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+$'; }

# Arranca un servidor y devuelve su PID de Windows por stdout. Mismo patron de nohup que usa
# mentis-transcribe.sh en produccion (ERR-027: no se inventa una forma nueva de mandar algo al
# fondo, se usa la que ya se probo).
_arrancar() {
  local estado="$1" log="$2"
  ( cd "$TIU_TMP" || exit 1
    nohup python3 "$SERVIDOR" --puerto 0 --estado "$estado" --modelo tiny \
      >/dev/null 2>>"$log" & ) 2>/dev/null
  local i
  for i in $(seq 1 60); do
    [ -f "$estado" ] && { _pid_estado "$estado"; return 0; }
    sleep 0.25
  done
  return 1
}

TIU_A_LIMPIAR=""
_limpiar() {
  local p
  for p in $TIU_A_LIMPIAR; do _matar "$p"; done
  # Windows no deja borrar un archivo que algun proceso tiene abierto, y el candado esta abierto
  # justamente hasta que el servidor muere. Sin esta espera, el rm -rf falla con "Device or
  # resource busy" y deja basura en /tmp en cada corrida.
  for _ in $(seq 1 20); do
    rm -rf "$TIU_TMP" 2>/dev/null && break
    sleep 0.25
  done
}
trap _limpiar EXIT

echo "== nv_stt_server.py: instancia unica =="
_autoverificar_detector
echo "   (detector de procesos verificado)"

# --- A. El candado, sin servidor y sin modelo ---------------------------------------------------
# Se prueban las piezas sueltas antes que el conjunto: si falla algo aca, el diagnostico es
# inmediato en vez de "los servidores hicieron algo raro".

echo "-- A. el candado suelto"
python3 - "$TIU_ROOT" "$TIU_TMP" <<'PY' > "$TIU_TMP/a.out" 2>&1
import os, subprocess, sys, time
raiz, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(raiz, "engine"))
import nv_stt_server as S

res = []
def chequeo(nombre, ok, detalle=""):
    res.append((nombre, bool(ok), detalle))

lock = os.path.join(tmp, "a.lock")

# A1: un proceso ajeno toma el candado y este NO puede.
guion = (
    "import msvcrt,os,sys,time\n"
    "f=open(sys.argv[1],'r+b')\n"
    "f.seek(4096); msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)\n"
    "f.seek(0); f.write(('%d'%os.getpid()).ljust(64).encode()); f.flush()\n"
    "print('listo', flush=True)\n"
    "time.sleep(8)\n"
)
open(lock, "wb").write(b" " * 64)
p = subprocess.Popen([sys.executable, "-c", guion, lock], stdout=subprocess.PIPE, text=True)
p.stdout.readline()                       # esperar a que confirme que lo tomo
f = S._abrir_candado(lock)
chequeo("A1 el candado ajeno se ve ocupado", S._tomar_candado(f) is False)

# A2: la trampa del buffer. Leer el PID con el candado tomado por otro.
chequeo("A2 se lee el PID del dueno con el candado puesto", S._leer_pid(lock) == p.pid,
        "leido=%s esperado=%s" % (S._leer_pid(lock), p.pid))

# A3: _es_python reconoce a un python de verdad.
chequeo("A3 _es_python(python vivo) = True", S._es_python(p.pid) is True)

# A4: y NO se deja enganar por un proceso que no es python (guarda contra reuso de PID).
q = subprocess.Popen(["cmd.exe", "/c", "ping -n 6 127.0.0.1 >NUL"])
time.sleep(0.4)
chequeo("A4 _es_python(cmd.exe) = False", S._es_python(q.pid) is False)
q.kill()

# A5: PID inexistente.
chequeo("A5 _es_python(pid inexistente) = False", S._es_python(999999) is False)

# A6: al morir el dueno, el candado queda libre solo.
f.close()
p.kill(); p.wait()
time.sleep(0.5)
f2 = S._abrir_candado(lock)
chequeo("A6 al morir el dueno el candado se libera", S._tomar_candado(f2) is True)
f2.close()

for nombre, ok, det in res:
    print("%s|%s|%s" % ("OK" if ok else "MAL", nombre, det))
PY

while IFS='|' read -r estado nombre detalle; do
  [ "$estado" = "OK" ] && _ok "$nombre"
  [ "$estado" = "MAL" ] && _mal "$nombre" "${detalle:-falso}"
done < <(grep -E '^(OK|MAL)\|' "$TIU_TMP/a.out")
grep -qE '^(OK|MAL)\|' "$TIU_TMP/a.out" || _mal "A. el candado suelto" "$(tail -3 "$TIU_TMP/a.out" | tr '\n' ' ')"

# --- B. Servidores de verdad --------------------------------------------------------------------

echo "-- B. servidores de verdad"
EST1="$TIU_TMP/uno-state.json"
LOG1="$TIU_TMP/uno.log"

PID1="$(_arrancar "$EST1" "$LOG1")"
TIU_A_LIMPIAR="$TIU_A_LIMPIAR $PID1"
if [ -n "$PID1" ] && _vive "$PID1"; then _ok "B1 arranca y anota su PID ($PID1)"
else _mal "B1 arranca y anota su PID" "pid='$PID1'"; fi

if [ -f "$TIU_TMP/uno-state.lock" ]; then _ok "B2 crea el archivo de candado"
else _mal "B2 crea el archivo de candado" "no existe uno-state.lock"; fi

# B3: EL ESCENARIO DEL BUG. Se borra el archivo de estado con el servidor VIVO -- que es
# exactamente lo que hacen _encender() y --apagar() cuando el curl falla -- y se arranca otro.
# Antes de este arreglo, aca quedaban dos servidores con el modelo cargado.
rm -f "$EST1"
EST2="$TIU_TMP/uno-state.json"          # mismo estado => mismo candado
PID2="$(_arrancar "$EST2" "$TIU_TMP/dos.log")"
TIU_A_LIMPIAR="$TIU_A_LIMPIAR $PID2"

if [ -n "$PID2" ] && [ "$PID2" != "$PID1" ]; then _ok "B3 el segundo arranca con PID propio ($PID2)"
else _mal "B3 el segundo arranca con PID propio" "pid2='$PID2' pid1='$PID1'"; fi

# El primero tiene que haber muerto. Se le da margen: matar y soltar el candado no es instantaneo.
MURIO=0
for _ in $(seq 1 20); do _vive "$PID1" || { MURIO=1; break; }; sleep 0.25; done
if [ "$MURIO" = "1" ]; then _ok "B4 el huerfano fue dado de baja"
else _mal "B4 el huerfano fue dado de baja" "el pid $PID1 sigue vivo"; fi

if _vive "$PID2"; then _ok "B5 el nuevo sigue vivo despues de tomar el lugar"
else _mal "B5 el nuevo sigue vivo despues de tomar el lugar" "murio el $PID2"; fi

# B6: y ademas funciona -- no alcanza con que exista el proceso.
PUERTO2="$(_puerto_estado "$EST2")"
if [ -n "$PUERTO2" ] && curl -s -m 5 "http://127.0.0.1:$PUERTO2/salud" | grep -q '"modelo"'; then
  _ok "B6 el nuevo contesta /salud"
else
  _mal "B6 el nuevo contesta /salud" "puerto='$PUERTO2'"
fi

# B7: el mensaje queda escrito. Un arreglo que actua en silencio es imposible de diagnosticar
# despues; el log tiene que decir que se dio de baja a alguien.
if grep -q "se lo da de baja" "$TIU_TMP/dos.log" 2>/dev/null; then
  _ok "B7 deja rastro en el log de por que mato al anterior"
else
  _mal "B7 deja rastro en el log" "$(tail -2 "$TIU_TMP/dos.log" 2>/dev/null | tr '\n' ' ')"
fi

# B8: el candado NO es global. Dos Mentis con estados distintos (por ejemplo, un test corriendo
# mientras el usuario dicta) tienen que poder convivir, o el arreglo seria peor que el problema.
EST3="$TIU_TMP/otro-state.json"
PID3="$(_arrancar "$EST3" "$TIU_TMP/tres.log")"
TIU_A_LIMPIAR="$TIU_A_LIMPIAR $PID3"
sleep 1
if [ -n "$PID3" ] && _vive "$PID3" && _vive "$PID2"; then
  _ok "B8 dos estados distintos conviven (el candado no es global)"
else
  _mal "B8 dos estados distintos conviven" "pid2 vivo=$(_vive "$PID2" && echo si || echo no) pid3='$PID3'"
fi

# B9: apagado limpio -> se va el estado y se va el candado.
curl -s -m 5 -X POST "http://127.0.0.1:$(_puerto_estado "$EST3")/apagar" >/dev/null 2>&1
IDO=0
for _ in $(seq 1 20); do _vive "$PID3" || { IDO=1; break; }; sleep 0.25; done
if [ "$IDO" = "1" ] && [ ! -f "$TIU_TMP/otro-state.lock" ] && [ ! -f "$EST3" ]; then
  _ok "B9 el apagado limpio borra estado y candado"
else
  _mal "B9 el apagado limpio borra estado y candado" \
       "murio=$IDO lock=$([ -f "$TIU_TMP/otro-state.lock" ] && echo queda || echo no) estado=$([ -f "$EST3" ] && echo queda || echo no)"
fi

echo
echo "== $TIU_OK OK, $TIU_MAL MAL =="
[ "$TIU_MAL" -eq 0 ]
