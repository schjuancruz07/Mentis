#!/usr/bin/env bash
# comparar-verificador.sh -- ¿el ensemble MEJORA la respuesta, o solo la cambia? (2026-08-03)
#
# POR QUE EXISTE. El 2026-08-03 se apago por defecto el paso de verificacion por ensemble
# (3 modelos + juez) de mentis-chat.sh. El motivo fue de COSTO, medido: bloqueaba el turno
# 26,8 / 138,4 / 198,9 segundos DESPUES de que el agente ya tenia la respuesta escrita, sobre
# turnos que duran ~37 s en total.
#
# Pero el motivo del costo no dice nada sobre el beneficio, y eso nunca se midio. Lo unico que
# se sabe es que cambio la respuesta en 3 de 3 turnos -- y "cambio" no es "mejoro": en uno de
# esos casos convirtio una funcion de 270 caracteres en una de 1.598.
#
# Este script junta la evidencia que falta: corre los mismos pedidos por los dos caminos y deja
# las dos respuestas lado a lado, en un archivo, para leerlas. NO decide nada solo: quien juzga
# cual es mejor es el usuario. Un juez automatico aca seria pedirle a un modelo que arbitre entre dos
# modelos, que es exactamente el sesgo autor=verificador que el ensemble venia a evitar.
#
# Uso:  bash tests/comparar-verificador.sh [archivo-con-pedidos]
#       Sin argumento usa una lista corta de pedidos representativos.
set -uo pipefail
CV_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CV_ROOT="$(cd "$CV_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

CV_SALIDA="$CV_ROOT/docs/comparacion-verificador-$(date +%Y%m%d-%H%M).md"

if [ -n "${1:-}" ] && [ -f "$1" ]; then
  mapfile -t PEDIDOS < "$1"
else
  PEDIDOS=(
    "Escribi una funcion python que invierta una cadena"
    "Explicame en dos lineas por que el cielo es azul"
    "Cual es la diferencia entre un proceso y un hilo"
    "Escribi una funcion bash que cuente las lineas de un archivo"
  )
fi

_ultima_respuesta() {
  python3 - "$(cygpath -w "$1")" <<'PY'
import io, json, sys
ultima = ""
for l in io.open(sys.argv[1], encoding="utf-8", errors="replace"):
    l = l.strip()
    if not l:
        continue
    try:
        d = json.loads(l)
    except Exception:
        continue
    if (d.get("role") or d.get("rol")) not in ("user", "usuario"):
        ultima = d.get("text") or d.get("texto") or ""
sys.stdout.write(ultima)
PY
}

{
  echo "# ¿El verificador mejora la respuesta? — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "Dos corridas del MISMO pedido: una sin el ensemble (como quedó por defecto) y otra con él."
  echo "Los tiempos son de punta a punta, del turno completo."
  echo
} > "$CV_SALIDA"

echo "== comparando $((${#PEDIDOS[@]})) pedidos por los dos caminos =="
for p in "${PEDIDOS[@]}"; do
  [ -z "${p// }" ] && continue
  echo "-- $(printf '%s' "$p" | cut -c1-56)"

  H1="$(mktemp)"
  T0=$(date +%s%3N)
  printf '%s\n' "$p" | MENTIS_VERIFY_ESPERA=0 timeout 600 bash "$CV_ROOT/mentis-chat.sh" -H "$H1" >/dev/null 2>&1
  MS_SIN=$(( $(date +%s%3N) - T0 ))
  SIN="$(_ultima_respuesta "$H1")"
  rm -f "$H1"

  # Techo alto a proposito: aca se quiere ver QUE produce el ensemble, no cuanto tarda con un
  # presupuesto. El tiempo se mide igual y se reporta.
  H2="$(mktemp)"
  T0=$(date +%s%3N)
  printf '%s\n' "$p" | MENTIS_VERIFY_ESPERA=600 timeout 900 bash "$CV_ROOT/mentis-chat.sh" -H "$H2" >/dev/null 2>&1
  MS_CON=$(( $(date +%s%3N) - T0 ))
  CON="$(_ultima_respuesta "$H2")"
  rm -f "$H2"

  echo "   sin verificador: ${MS_SIN} ms (${#SIN} ch)  |  con verificador: ${MS_CON} ms (${#CON} ch)"

  {
    echo "---"
    echo
    echo "## $p"
    echo
    echo "| | tiempo | largo |"
    echo "|---|---|---|"
    echo "| sin verificador | ${MS_SIN} ms | ${#SIN} caracteres |"
    echo "| con verificador | ${MS_CON} ms | ${#CON} caracteres |"
    echo
    echo "### Sin verificador (lo que Mentis contesta hoy)"
    echo
    echo '```'
    printf '%s\n' "$SIN"
    echo '```'
    echo
    echo "### Con verificador (ensemble de 3 modelos + juez)"
    echo
    echo '```'
    printf '%s\n' "$CON"
    echo '```'
    echo
  } >> "$CV_SALIDA"
done

echo
echo "Comparacion escrita en:"
echo "  $CV_SALIDA"
echo
echo "Leelas y deci cual preferis. Si el ensemble gana claro, se vuelve a prender con"
echo "MENTIS_VERIFY_ESPERA=<segundos>; si no, queda apagado y el turno se ahorra 12 s y"
echo "tres llamadas a modelos."
