#!/usr/bin/env bash
# mentis-delegar.sh -- darle una tarea larga a alguien mas y despegarse.
#
# POR QUE EXISTE (pedido del usuario, 2026-08-08): "un equipo avanzado para tareas muy largas o muy
# dificiles que no dependan directamente de Mentis". La palabra que manda es DEPENDAN: no se trata
# de que Mentis piense mejor, sino de que una tarea de veinte minutos deje de ocupar la
# conversacion. Mientras corre, el usuario sigue usando Mentis para otra cosa.
#
# EL CONTRATO, que es lo unico que hay que decidir una sola vez:
#   ENTRA:  una tarea en texto, una carpeta donde trabajar, un tope de pasos.
#   SALE:   un resultado, un registro de que hizo, y un veredicto (termino / se quedo sin margen
#           / fallo).
# Con eso, sumar el septimo agente es media hora. Sin eso, cada agente es una integracion nueva --
# que es exactamente en lo que se convierte una lista de doce frameworks sin diseño en el medio.
#
# EL PRIMER "AGENTE" ES EL DE CASA, A PROPOSITO. Se arranca con nv-agent.sh, que ya existe, ya
# esta probado y no necesita instalar nada. Asi el mecanismo entero -- lanzar, seguir, avisar,
# guardar el resultado -- queda verificado ANTES de meter una dependencia externa. Si el contrato
# tuviera un error de diseño, aparece ahora y no cuando ya haya cuatro frameworks colgando de el.
# (OpenHands era el primer candidato externo, pero necesita Docker y en esta maquina no esta
# instalado; ver docs. El contrato no depende de esa decision.)
#
# COMO AVISA: escribe el estado en MENTIS_DELEGACIONES_DIR. La app vigila esa carpeta y, cuando
# una tarea pasa a 'terminada', muestra la notificacion nativa que ya existia para las
# generaciones largas (notifyIfUnfocused en main.js). No se invento un canal nuevo.
#
# Uso:
#   mentis-delegar.sh "la tarea"            # lanza y devuelve el id, sin bloquear
#   mentis-delegar.sh -l                    # lista las tareas y su estado
#   mentis-delegar.sh -v <id>               # ver el resultado de una
#   mentis-delegar.sh -c <id>               # cancelar una que este corriendo
# Opciones: -d <carpeta>  -i <pasos, default 25>  -a <agente, default 'casa'>

set -uo pipefail
MD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_DIR="${MENTIS_DELEGACIONES_DIR:-$MD_HERE/delegaciones}"
mkdir -p "$MD_DIR" 2>/dev/null || true

MD_CARPETA=""; MD_PASOS=25; MD_AGENTE="casa"; MD_ACCION="lanzar"; MD_ID=""
while getopts ":d:i:a:lv:c:h" opt; do
  case "$opt" in
    d) MD_CARPETA="$OPTARG" ;;
    i) MD_PASOS="$OPTARG" ;;
    a) MD_AGENTE="$OPTARG" ;;
    l) MD_ACCION="listar" ;;
    v) MD_ACCION="ver"; MD_ID="$OPTARG" ;;
    c) MD_ACCION="cancelar"; MD_ID="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "opcion invalida: -$OPTARG" >&2; exit 64 ;;
  esac
done
shift $((OPTIND-1))

_md_json_esc() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null; }

# --- listar ---------------------------------------------------------------------------------
if [ "$MD_ACCION" = "listar" ]; then
  n=0
  printf '%-22s %-11s %-6s %s\n' "ID" "ESTADO" "PASOS" "TAREA"
  printf '%s\n' "----------------------------------------------------------------------------"
  for f in "$MD_DIR"/*.json; do
    [ -f "$f" ] || continue
    n=$((n+1))
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print("%-22s %-11s %-6s %s" % (d.get("id","?"), d.get("estado","?"), d.get("pasos",""), (d.get("tarea","") or "")[:44]))
' "$f" 2>/dev/null
  done
  [ "$n" -eq 0 ] && echo "(no hay tareas delegadas todavia)"
  exit 0
fi

# --- ver ------------------------------------------------------------------------------------
if [ "$MD_ACCION" = "ver" ]; then
  f="$MD_DIR/$MD_ID.json"
  [ -f "$f" ] || { echo "no existe la tarea '$MD_ID'. Miralas con -l" >&2; exit 1; }
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print("tarea   :", d.get("tarea"))
print("estado  :", d.get("estado"), "| pasos:", d.get("pasos"), "| carpeta:", d.get("carpeta"))
print("empezo  :", d.get("inicio"), "| termino:", d.get("fin") or "-")
print()
print(d.get("resultado") or "(sin resultado todavia)")
' "$f" 2>/dev/null
  exit 0
fi

# --- cancelar -------------------------------------------------------------------------------
if [ "$MD_ACCION" = "cancelar" ]; then
  f="$MD_DIR/$MD_ID.json"
  [ -f "$f" ] || { echo "no existe la tarea '$MD_ID'" >&2; exit 1; }
  pid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("pid") or "")' "$f" 2>/dev/null)"
  if [ -n "$pid" ]; then
    # Se mata el ARBOL, no el proceso: nv-agent.sh deja nietos (curl, python) que sobreviven a un
    # kill del padre. Es la misma leccion que ERR-034.
    taskkill //PID "$pid" //T //F >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null || true
  fi
  python3 - "$f" <<'PY'
import json,sys,datetime
p=sys.argv[1]
d=json.load(open(p,encoding="utf-8"))
d["estado"]="cancelada"; d["fin"]=datetime.datetime.now().isoformat(timespec="seconds")
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
  echo "cancelada: $MD_ID"
  exit 0
fi

# --- lanzar ---------------------------------------------------------------------------------
MD_TAREA="$*"
[ -n "$MD_TAREA" ] || { echo "Uso: mentis-delegar.sh \"la tarea\"  (o -l para listar)" >&2; exit 64; }

MD_ID="del-$(date +%s)-$$"
[ -n "$MD_CARPETA" ] || MD_CARPETA="$MD_HERE/workspace-delegado/$MD_ID"
mkdir -p "$MD_CARPETA" 2>/dev/null || true
MD_EST="$MD_DIR/$MD_ID.json"
MD_LOG="$MD_DIR/$MD_ID.log"

MD_TAREA_ESC="$(printf '%s' "$MD_TAREA" | _md_json_esc)"
cat > "$MD_EST" <<JSON
{
  "id": "$MD_ID",
  "agente": "$MD_AGENTE",
  "tarea": "$MD_TAREA_ESC",
  "carpeta": "$MD_CARPETA",
  "estado": "corriendo",
  "inicio": "$(date +%Y-%m-%dT%H:%M:%S)",
  "fin": null,
  "pasos": 0,
  "resultado": null,
  "pid": null
}
JSON

# El trabajo va a un subshell en segundo plano con nohup: tiene que sobrevivir a que se cierre la
# conversacion que lo lanzo. Delegar y despegarse quiere decir exactamente eso.
(
  case "$MD_AGENTE" in
    casa)
      # La carpeta va en -d, no en -r: -r no existe en nv-agent.sh y el agente moria al arrancar
      # con "opción inválida" (visto en la primera corrida real). Sin -g, -s, -V ni -c: una tarea
      # que corre sola, sin nadie mirando, no puede sacar fotos ni manejar el mouse. Delegar no
      # es dar mas permisos, es dar los mismos con menos supervision -- asi que se dan MENOS.
      bash "$MD_HERE/engine/nv-agent.sh" -w -b -i "$MD_PASOS" -d "$MD_CARPETA" "$MD_TAREA" \
        > "$MD_LOG.out" 2> "$MD_LOG" ; rc=$?
      ;;
    *)
      # Los agentes externos entran por aca, cada uno con su propio entorno. Ninguno se importa
      # dentro de Mentis: se los invoca como proceso aparte para que si explota, muera solo.
      if [ -x "$MD_HERE/agentes/$MD_AGENTE/correr.sh" ]; then
        bash "$MD_HERE/agentes/$MD_AGENTE/correr.sh" "$MD_CARPETA" "$MD_PASOS" "$MD_TAREA" \
          > "$MD_LOG.out" 2> "$MD_LOG" ; rc=$?
      else
        echo "ERROR: no existe el agente '$MD_AGENTE' (falta agentes/$MD_AGENTE/correr.sh)" > "$MD_LOG"
        rc=127
      fi
      ;;
  esac

  # OJO CON `grep -c`: cuando no encuentra nada imprime "0" Y ADEMAS sale con codigo 1. Con un
  # `|| echo 0` al lado, el resultado quedaba siendo "0\n0" -- dos lineas -- y el int() de mas
  # abajo reventaba. Como todo esto corre en un subshell con la salida a /dev/null, el error no
  # se veia en ningun lado: la tarea terminaba de verdad, el aviso se escribia, y el estado se
  # quedaba en "corriendo" para siempre. Se usa `|| true`, que deja pasar el "0" que grep ya
  # imprimio, y se recorta por las dudas.
  pasos="$(grep -cE '^\[nv-agent\] iter [0-9]+:' "$MD_LOG" 2>/dev/null | head -1 || true)"
  pasos="$(printf '%s' "${pasos:-0}" | tr -cd '0-9')"
  [ -n "$pasos" ] || pasos=0
  # rc=0 no alcanza para decir "termino bien": nv-agent.sh sale 4 cuando no llego a una respuesta
  # final. Se distingue, porque "no pudo" y "fallo" son cosas distintas para quien lo lee.
  case "$rc" in
    0) estado="terminada" ;;
    4) estado="sin_terminar" ;;
    *) estado="fallo" ;;
  esac
  # El resultado se pasa por ARCHIVO y no como argumento. La primera version lo escapaba a mano
  # para meterlo en la linea de comandos y el python moria en silencio -- el estado quedaba en
  # "corriendo" para siempre aunque la tarea hubiera terminado. Una salida con comillas, saltos
  # de linea o acentos rompe cualquier escape hecho a mano; leer el archivo no rompe nunca.
  python3 - "$MD_EST" "$estado" "$pasos" "$MD_LOG.out" "$MD_LOG" <<'PY'
import json, sys, datetime, os
est, estado, pasos, salida, registro = sys.argv[1:6]
def leer(p, n=4000):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()[-n:]
    except Exception:
        return ""
res = leer(salida).strip()
if not res:
    # Sin salida util, sirve el final del registro: es lo que explica POR QUE no hubo salida.
    res = "(sin respuesta final) " + leer(registro, 1200).strip()[-1200:]
try:
    d = json.load(open(est, encoding="utf-8"))
except Exception:
    d = {}
d["estado"] = estado
d["pasos"] = int(pasos or 0)
d["fin"] = datetime.datetime.now().isoformat(timespec="seconds")
d["resultado"] = res or "(sin salida)"
tmp = est + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, est)   # atomico: nadie puede leer un estado a medio escribir
PY
  # La marca que mira la app. Se escribe AL FINAL y en un archivo aparte: asi la app no puede
  # avisar de una tarea a medio escribir, que seria avisar de algo que todavia no esta.
  printf '%s\n' "$estado" > "$MD_DIR/$MD_ID.aviso"
) </dev/null >/dev/null 2>&1 &

MD_PID=$!
python3 - "$MD_EST" "$MD_PID" <<'PY'
import json,sys
p,pid=sys.argv[1],sys.argv[2]
d=json.load(open(p,encoding="utf-8")); d["pid"]=int(pid)
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY

echo "$MD_ID"
echo "Tarea delegada. Segui con lo tuyo: Mentis te avisa cuando termine." >&2
echo "  ver estado:  mentis-delegar.sh -l" >&2
echo "  ver el resultado:  mentis-delegar.sh -v $MD_ID" >&2
