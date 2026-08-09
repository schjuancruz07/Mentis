#!/usr/bin/env bash
# Reproduce el bug real reportado por el usuario (2026-07-18, computer-use): mentis-chat.sh lanza
# trabajo en segundo plano (nv-verify.sh con '&', que a su vez hace curl a la API) y de ahi
# cuelgan NIETOS que `taskkill /T` no alcanza -- quedaban vivos gastando API despues de que la
# UI ya se habia destrabado. Medido en vivo: el fork() emulado de MSYS deja el ParentProcessId
# de Windows apuntando a un PID que ya murio, asi que la genealogia no sirve para encontrarlos.
#
# Imita la misma estructura que el motor real, incluido el registro de PIDs con nv_track_bg_pid
# (que es lo que hace posible matarlos): fixture -> hijo con '&' -> nieto de larga duracion.
# El PID MSYS del nieto se escribe en $1 para que el test pueda comprobar si sobrevivio.
PIDFILE="${1:?falta el archivo donde anotar el pid del nieto}"

# misma traduccion PID-MSYS -> PID-Windows que nv_track_bg_pid en nv-lib.sh
_track() {
  local p="$1" w
  [ -n "${MENTIS_PIDFILE:-}" ] || return 0
  w="$(cat "/proc/$p/winpid" 2>/dev/null || true)"
  [ -n "$w" ] && printf '%s\n' "$w" >> "$MENTIS_PIDFILE"
  return 0
}

(
  # hijo: imita el "( bash nv-verify.sh... ) &" de mentis-chat.sh
  (
    # nieto: imita el curl/python de larga duracion que cuelga de ese hijo
    exec sleep 120
  ) &
  NIETO=$!
  echo "$NIETO" > "$PIDFILE"
  _track "$NIETO"
  wait
) &
_track "$!"

while true; do
  printf 'Vos: '
  if ! IFS= read -r MSG; then
    break
  fi
  if [ "$MSG" = "salir" ]; then
    break
  fi
  printf 'Mentis: eco: %s\n' "$MSG"
done
