#!/usr/bin/env bash
# mentis-backup.sh -- red de seguridad de Mentis (pedido del usuario, 2026-07-26).
#
# Por que existe: el 2026-07-26 se borro el repo de git a pedido del usuario, y con el la unica
# forma de volver atras ante un borrado o un cambio malo. Esto lo reemplaza sin pedirle que
# aprenda ninguna herramienta: copias completas fechadas, rotando las ultimas N.
#
# Que respalda (medido: 5.2 MB + 1 MB, siete copias ~45 MB -- nada al lado de los 74 GB libres):
#   motor/  -> C:/Users/<usuario>\Mentis SIN node_modules (codigo, conversaciones, settings, keys)
#   datos/  -> C:/Users/<usuario>\Documents\Mentis (proyectos, boveda, creaciones)
# Se respaldan los DOS a proposito: el codigo solo no alcanza -- los proyectos y la boveda son
# irreemplazables y viven fuera de la carpeta del motor.
#
# Uso:
#   mentis-backup.sh                 -> respalda y rota (con autodescubrimiento de rutas)
#   mentis-backup.sh <envdir>        -> igual, con la carpeta de Mentis explicita
#   mentis-backup.sh --listar        -> muestra los respaldos existentes
#   mentis-backup.sh --restaurar <carpeta>  -> explica como restaurar (no toca nada solo)
#
# NO usa `set -e`: un fallo al copiar UN archivo (bloqueado por otro proceso) no debe abortar
# el respaldo entero, pero SI tiene que reflejarse en el resultado final (ver VERIFICACION).
set -uo pipefail

# Bug real (2026-07-26, encontrado al probar la tarea programada de verdad en vez de darla por
# buena): cuando el Task Scheduler lanza bash.exe desde un.cmd, el proceso hereda el PATH
# MINIMO de Windows -- sin /usr/bin no existen `date`, `tee`, `wc`, `find` ni `du`, y el script
# se desarma entero (el respaldo quedaba con nombre "mentis-" sin fecha y 0 archivos). Es la
# misma familia que ERR-037 (Git\bin fuera del PATH persistente). Corriendo a mano desde Git
# Bash nunca se ve, porque ahi el PATH ya viene completo.
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

# La carpeta de Mentis se acepta como argumento porque bajo Task Scheduler bash.exe no siempre
# resuelve BASH_SOURCE[0] bien al ser lanzado directo, sin shell padre (ERR-040, ya documentado
# y ya resuelto asi en mentis-run-once.sh).
case "${1:-}" in
  --listar|--restaurar) MB_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
  "") MB_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
  *)  MB_HOME="$1"; shift ;;
esac

MB_DATOS="${MENTIS_DATOS_DIR:-$HOME/Documents/Mentis}"
MB_DESTINO_RAIZ="${MENTIS_BACKUP_DIR:-$HOME/Mentis-Respaldos}"
MB_CONSERVAR="${MENTIS_BACKUP_CONSERVAR:-7}"
MB_LOG="$MB_DESTINO_RAIZ/respaldos.log"

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$MB_LOG" >&2; }

# ---------- modos informativos ----------
if [ "${1:-}" = "--listar" ]; then
  if [ ! -d "$MB_DESTINO_RAIZ" ]; then echo "Todavia no hay ningun respaldo en $MB_DESTINO_RAIZ"; exit 0; fi
  echo "Respaldos en $MB_DESTINO_RAIZ:"
  for d in "$MB_DESTINO_RAIZ"/mentis-*/; do
    [ -d "$d" ] || continue
    printf '  %-22s %s  (%s archivos)\n' "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(find "$d" -type f 2>/dev/null | wc -l)"
  done
  exit 0
fi

if [ "${1:-}" = "--restaurar" ]; then
  CUAL="${2:-}"
  echo "Para restaurar NO se pisa nada automaticamente (seria peor el remedio que la enfermedad)."
  echo "El respaldo es una copia normal de carpetas: abrila y copia lo que necesites."
  echo
  echo "  Respaldo:  $MB_DESTINO_RAIZ/${CUAL:-<elegi uno con --listar>}"
  echo "    motor/   -> va a $MB_HOME"
  echo "    datos/   -> va a $MB_DATOS"
  echo
  echo "Si querés volver TODO el motor a ese punto, cerra Mentis primero y despues copia"
  echo "el contenido de motor/ sobre la carpeta de Mentis (node_modules no se toca: no se respalda"
  echo "porque se regenera con 'npm install')."
  exit 0
fi

# ---------- respaldo ----------
MB_SELLO="$(date '+%Y-%m-%d_%H%M')"
MB_DESTINO="$MB_DESTINO_RAIZ/mentis-$MB_SELLO"
mkdir -p "$MB_DESTINO/motor" "$MB_DESTINO/datos" 2>/dev/null

_log "respaldo iniciado -> $MB_DESTINO"

# node_modules se excluye a proposito: son 624 de los 629 MB, se regeneran con npm install y
# respaldarlos multiplicaria por 100 el espacio sin agregar nada irrecuperable.
MB_FALLOS=0
if command -v tar >/dev/null 2>&1; then
  # tar respeta permisos y es MUCHO mas rapido que cp con miles de archivos chicos en Windows.
  ( cd "$MB_HOME" && tar -cf - --exclude=node_modules --exclude=.git. 2>/dev/null ) \
    | ( cd "$MB_DESTINO/motor" && tar -xf - 2>/dev/null ) || MB_FALLOS=$((MB_FALLOS+1))
  if [ -d "$MB_DATOS" ]; then
    ( cd "$MB_DATOS" && tar -cf -. 2>/dev/null ) \
      | ( cd "$MB_DESTINO/datos" && tar -xf - 2>/dev/null ) || MB_FALLOS=$((MB_FALLOS+1))
  fi
else
  cp -a "$MB_HOME"/. "$MB_DESTINO/motor/" 2>/dev/null || MB_FALLOS=$((MB_FALLOS+1))
  rm -rf "$MB_DESTINO/motor/node_modules" "$MB_DESTINO/motor/app/node_modules" 2>/dev/null
  [ -d "$MB_DATOS" ] && { cp -a "$MB_DATOS"/. "$MB_DESTINO/datos/" 2>/dev/null || MB_FALLOS=$((MB_FALLOS+1)); }
fi

# ---------- VERIFICACION (la leccion de Kai Vault: no declarar exito sin comprobarlo) ----------
# Kai Vault paso 8 dias diciendo "Listo" mientras fallaba, porque nadie chequeaba el resultado
# real. Un respaldo que miente es peor que no tener respaldo: te deja tranquilo con las manos
# vacias justo el dia que lo necesitas. Se comprueba que haya archivos y que aparezcan los que
# tienen que estar si.
MB_ARCHIVOS="$(find "$MB_DESTINO" -type f 2>/dev/null | wc -l)"
MB_ESENCIALES=0
for critico in "motor/mentis-chat.sh" "motor/engine/nv-agent.sh" "motor/app/main.js"; do
  [ -s "$MB_DESTINO/$critico" ] && MB_ESENCIALES=$((MB_ESENCIALES+1))
done

if [ "$MB_ARCHIVOS" -lt 50 ] || [ "$MB_ESENCIALES" -lt 3 ]; then
  _log "ERROR: el respaldo quedo incompleto ($MB_ARCHIVOS archivos, $MB_ESENCIALES/3 criticos). NO se rota nada."
  echo "ERROR: respaldo incompleto en $MB_DESTINO -- no se borro ningun respaldo viejo." >&2
  exit 1
fi

MB_PESO="$(du -sh "$MB_DESTINO" 2>/dev/null | cut -f1)"
[ "$MB_FALLOS" -gt 0 ] && _log "AVISO: $MB_FALLOS parte(s) dieron error de copia, pero los archivos criticos estan presentes."

# ---------- rotacion (solo despues de verificar que el nuevo sirve) ----------
MB_BORRADOS=0
MB_TOTAL="$(find "$MB_DESTINO_RAIZ" -maxdepth 1 -type d -name 'mentis-*' 2>/dev/null | wc -l)"
if [ "$MB_TOTAL" -gt "$MB_CONSERVAR" ]; then
  # Orden por nombre = orden cronologico (el sello es YYYY-MM-DD_HHMM). Se borran los mas viejos.
  while IFS= read -r viejo; do
    rm -rf "$viejo" 2>/dev/null && MB_BORRADOS=$((MB_BORRADOS+1))
  done < <(find "$MB_DESTINO_RAIZ" -maxdepth 1 -type d -name 'mentis-*' 2>/dev/null | sort | head -n $(( MB_TOTAL - MB_CONSERVAR )))
fi

_log "OK: $MB_ARCHIVOS archivos, $MB_PESO, se conservan $MB_CONSERVAR respaldos (se borraron $MB_BORRADOS viejos)"

# Caducidad de las memorias provisionales (regla 5 del learning loop, 2026-07-27).
# Va DESPUES del respaldo y no antes: si algo se borra de mas, la copia de esta misma corrida
# todavia lo tiene. Y va aca y no en cada turno porque es una limpieza diaria, no algo que deba
# competir con la conversacion.
if [ -x "$MB_HOME/mentis-aprender.sh" ] || [ -f "$MB_HOME/mentis-aprender.sh" ]; then
  MB_CADUCADAS="$(bash "$MB_HOME/mentis-aprender.sh" caducar 2>/dev/null | tail -1)"
  [ -n "$MB_CADUCADAS" ] && _log "memorias: $MB_CADUCADAS"
fi

echo "Respaldo listo: $MB_DESTINO ($MB_ARCHIVOS archivos, $MB_PESO)"
exit 0
