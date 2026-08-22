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

# La ruta se saca SIN subshell (2026-08-20). `$(cd "$(dirname...)" && pwd)` son dos procesos mas,
# medidos en 60 ms en esta maquina, y aca no hace falta la ruta absoluta: el unico uso es abrir
# hooks.json, y para eso una relativa sirve igual. El caso "se invoco sin barra" (bash
# mentis-hooks.sh) hay que atenderlo aparte, porque ${x%/*} sobre algo sin barra devuelve el
# nombre entero en vez del directorio.
HERE="${BASH_SOURCE[0]%/*}"
[ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
HOOKS_FILE="$HERE/hooks.json"
EVENT="${1:-}"
[ -z "$EVENT" ] && { echo "Uso: mentis-hooks.sh <evento>" >&2; exit 1; }
[ -f "$HOOKS_FILE" ] || exit 0

# SALIDA TEMPRANA SIN PAGAR PYTHON (2026-08-20). El archivo puede no tener NINGUN hook -- que es
# el caso hoy: los tres eventos estan vacios -- y aun asi se arrancaba python3 para descubrirlo.
# Medido en esta maquina: 439 ms por llamada. Se invoca dos veces por turno (UserPromptSubmit y
# Stop) mas una al arrancar la sesion, o sea 878 ms por turno tirados para no hacer nada. Es el
# mismo error que el clasificador de 515 ms: el costo no estaba en el trabajo sino en arrancar el
# proceso que decide que no hay trabajo.
#
# El grep falla hacia el lado SEGURO: si aparece la palabra en cualquier lado del archivo, se
# sigue al parser de verdad. Lo unico que atrapa es el caso "no hay un solo comando registrado",
# que es exactamente cuando no hay nada que ejecutar.
# Se lee con bash puro y no con grep por lo mismo que arriba: un grep es otro proceso (60 ms) y
# el archivo pesa 93 bytes. `$(<archivo)` lo lee sin lanzar nada.
_MH_RAW="$(<"$HOOKS_FILE")"
case "$_MH_RAW" in
  *'"command"'*) : ;;
  *) exit 0 ;;
esac

# Cada comando corre con timeout 10s y su fallo se ignora -- un hook roto no debe frenar a
# Mentis. Solo se imprime lo que el hook mando a STDOUT (no stderr, para no ensuciar el
# contexto inyectado con ruido de debug de los propios hooks).
python3 -c '
import json, sys, subprocess, os

# SIN \r (2026-08-20, lo destapo el test nuevo). El python de Windows escribe en modo texto y
# convierte cada \n en \r\n. Lo que sale de aca se INYECTA EN EL PROMPT del modelo, asi que cada
# hook metia un retorno de carro invisible en el contexto. reconfigure(newline="\n") apaga la
# traduccion; se hace defensivo porque no existe antes de Python 3.7.
try:
    sys.stdout.reconfigure(newline="\n")
except Exception:
    pass

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
