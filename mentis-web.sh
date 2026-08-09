#!/usr/bin/env bash
# mentis-web.sh — la pagina para hablarle a Mentis desde el celular (2026-07-30).
#
# Uso:
#   mentis-web.sh prender     # levanta el servidor y te dice que direccion abrir
#   mentis-web.sh estado      # ¿esta corriendo? ¿en que direccion?
#   mentis-web.sh apagar      # lo baja
#   mentis-web.sh token       # muestra (o crea) el token de acceso
#   mentis-web.sh rotar       # cambia el token (invalida los favoritos viejos)
#   mentis-web.sh direcciones # las direcciones para abrir: la de casa y la de Tailscale
#
# COMO SE USA: prendelo, abri en el celular la direccion que imprime, y guardala en favoritos.
# El token va en la direccion, asi que el favorito ya queda con la llave puesta.
#
# LO QUE MENTIS **NO** PUEDE HACER cuando el mensaje entra por aca (mentis-chat.sh -R): escribir
# archivos, ejecutar comandos, mirar la pantalla, prender la camara ni controlar la computadora.
# La pagina vive en la WiFi de una casa con mas gente; el token la cierra, pero un token no es
# excusa para darle manos a algo que entra por la red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESTADO="$HERE/web-server-state.json"
LOG="$HERE/web-server.log"
TOKEN_FILE="$HERE/engine/.web-token"
PUERTO="${MENTIS_WEB_PUERTO:-8765}"

_token() {
  if [ -s "$TOKEN_FILE" ]; then cat "$TOKEN_FILE"; return 0; fi
  # 24 bytes al azar en hexa. Se usa el generador del sistema (os.urandom), no $RANDOM: $RANDOM es
  # predecible y esto es una llave.
  local t
  t="$(python3 -c 'import os,binascii;print(binascii.hexlify(os.urandom(24)).decode())' 2>/dev/null)" || t=""
  if [ -z "$t" ]; then echo "ERROR: no pude generar el token" >&2; return 1; fi
  printf '%s' "$t" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  printf '%s' "$t"
}

# Lee un campo del JSON de estado. La ruta va como ARGUMENTO y no interpolada dentro del texto
# del script (ERR-069), y en formato Windows porque este python es el nativo (ERR-004/006).
_campo_estado() {
  [ -s "$ESTADO" ] || return 1
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
except Exception:
    sys.exit(1)
' "$(cygpath -w "$ESTADO" 2>/dev/null || printf '%s' "$ESTADO")" "$1" 2>/dev/null
}

_pid_vivo() {
  local pid
  pid="$(_campo_estado pid)" || return 1
  [ -n "$pid" ] || return 1
  # tasklist y no 'kill -0': el pid es de un proceso nativo de Windows, no de MSYS.
  tasklist //FI "PID eq $pid" 2>/dev/null | grep -q "$pid" || return 1
  printf '%s' "$pid"
}

_url() { _campo_estado url; }

# La direccion de Tailscale, si esta instalado y con sesion iniciada. Es la que sirve DESDE
# CUALQUIER RED (datos moviles, WiFi ajeno): la IP 100.x.y.z existe solo dentro de la red privada
# del usuario, asi que no hay nada abierto al mundo.
_ip_tailscale() {
  local ts
  for ts in "/c/Program Files/Tailscale/tailscale.exe" "$(command -v tailscale 2>/dev/null)"; do
    [ -n "$ts" ] && [ -x "$ts" ] || continue
    # tr -dc con lista blanca en vez de nombrar el retorno de carro: escribir esa secuencia desde
    # un generador de codigo la convierte en un caracter REAL y parte la linea al medio (paso).
    "$ts" ip -4 2>/dev/null | head -1 | tr -dc "0-9."
    return 0
  done
  return 1
}
# --- AVISO DE RED PUBLICA (2026-08-02) ----------------------------------------------------------
#
# EL PROBLEMA QUE ESTO EVITA, y que costo una sesion entera de sintomas raros: si Windows tiene la
# WiFi de casa clasificada como **Publica**, el firewall bloquea TODO lo entrante de la red local.
# El servidor arranca bien, escucha bien, responde bien desde la propia PC -- y el celular no lo
# alcanza. Los tres sintomas que se ven son: el navegador dice "192.168.1.x no responde", KDE
# Connect dice "este dispositivo vinculado no esta disponible", y Tailscale muestra la PC en gris.
# Ninguno de los tres apunta al firewall, y los tres mandan a revisar la red.
#
# No se arregla desde aca a proposito: cambiar el perfil de red y las reglas del firewall necesita
# PowerShell como administrador, o sea al usuario. Lo que si se puede hacer es DECIRLO, y ofrecer el
# camino que funciona igual (Tailscale, cuyo adaptador queda como Privada).
_aviso_red_publica() {
  local perfil
  perfil="$(powershell.exe -NoProfile -NonInteractive -Command \
    "(Get-NetConnectionProfile | Where-Object {\$_.InterfaceAlias -notlike '*Tailscale*'} | Select-Object -First 1).NetworkCategory" \
    2>/dev/null | tr -d '\r\n ')"
  [ "$perfil" = "Public" ] || return 0
  echo
  echo "  OJO: Windows tiene tu WiFi clasificada como PUBLICA, y con eso el firewall bloquea las"
  echo "  conexiones entrantes de la red local. La direccion de arriba probablemente NO funcione"
  echo "  desde el celular (ni KDE Connect). No es la red: es el perfil de Windows."
  echo "  Para arreglarlo hace falta PowerShell COMO ADMINISTRADOR:"
  echo "      Set-NetConnectionProfile -InterfaceAlias 'Wi-Fi' -NetworkCategory Private"
  echo "  Mientras tanto, usa la direccion de Tailscale que sale abajo: esa si funciona."
}

case "${1:-}" in
  prender)
    if PID="$(_pid_vivo)"; then
      echo "ya estaba prendido (pid $PID)"
      echo "abri en el celular: $(_url)"
      exit 0
    fi
    TOKEN="$(_token)" || exit 1
    # Start-Process y no "&" + disown: backgroundear procesos de larga vida desde Git Bash tiene
    # su propia historia de fallos en esta maquina (ERR-027). El servidor escribe su estado en un
    # JSON, que es como se lo encuentra despues.
    # El python REAL, no el que aparece en el PATH. En esta maquina "python" es el stub de la
    # Microsoft Store (C:/Users/<usuario>\bin\python.exe, 210 bytes) y Start-Process se niega a
    # lanzarlo con un error que no dice nada: "Esta version de %1 no es compatible con la version
    # de Windows que esta ejecutando". El interprete de verdad lo dice el propio python.
    PY_EXE="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || PY_EXE=""
    if [ -z "$PY_EXE" ]; then echo "ERROR: no encuentro el interprete de python" >&2; exit 1; fi
    PY_WIN="$(cygpath -w "$HERE/engine/nv_web_server.py" 2>/dev/null || printf '%s' "$HERE/engine/nv_web_server.py")"
    RAIZ_WIN="$(cygpath -w "$HERE" 2>/dev/null || printf '%s' "$HERE")"
    ESTADO_WIN="$(cygpath -w "$ESTADO" 2>/dev/null || printf '%s' "$ESTADO")"
    LOG_WIN="$(cygpath -w "$LOG" 2>/dev/null || printf '%s' "$LOG")"
    # OJO: el Start-Process va en UNA SOLA LINEA. La primera version partia los argumentos con "\"
    # al final de cada linea -- que es la continuacion de bash, no la de PowerShell (alla es un
    # backtick). PowerShell se comia el comando sin decir nada: el servidor no arrancaba, el log
    # quedaba vacio y no habia error en ningun lado. (Encontrado probandolo, 2026-07-30.)
    powershell.exe -NoProfile -NonInteractive -Command "\$env:MENTIS_WEB_TOKEN='$TOKEN'; Start-Process -WindowStyle Hidden -WorkingDirectory '$RAIZ_WIN' -FilePath '$PY_EXE' -ArgumentList '$PY_WIN','--raiz','$RAIZ_WIN','--puerto','$PUERTO','--estado','$ESTADO_WIN' -RedirectStandardError '$LOG_WIN'" >/dev/null 2>&1

    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      if PID="$(_pid_vivo)"; then
        echo "prendido (pid $PID)"
        echo
        echo "  Abri esto en el celular y guardalo en favoritos:"
        echo "    $(_url)"
        _aviso_red_publica
        # La direccion de Tailscale se muestra SIEMPRE que exista, no solo en 'direcciones'
        # (2026-08-02). Motivo: cuando la WiFi esta clasificada como Publica en Windows, la URL de
        # arriba NO FUNCIONA -- el firewall bloquea lo entrante -- y la de Tailscale sí, porque su
        # adaptador queda como Privada. Mostrar solo la que no anda y decir "tiene que estar en la
        # misma WiFi" mandaba al usuario a buscar el problema en la red equivocada. Paso de verdad.
        TS_IP_P="$(_ip_tailscale)" || TS_IP_P=""
        if [ -n "${TS_IP_P// }" ]; then
          echo
          echo "  Y esta anda desde cualquier red, y tambien cuando la de arriba falla:"
          echo "    http://$TS_IP_P:$PUERTO/?t=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n')"
          echo "    (el celular tiene que tener Tailscale prendido, con tu misma cuenta)"
        fi
        exit 0
      fi
    done
    echo "ERROR: no arranco. Mira el log: $LOG" >&2
    tail -5 "$LOG" 2>/dev/null >&2
    exit 1 ;;

  estado)
    if PID="$(_pid_vivo)"; then
      echo "prendido (pid $PID)"
      echo "direccion: $(_url)"
    else
      # "apagado" a secas manda a buscar el problema en el lugar equivocado (2026-08-06). Paso:
      # se diagnostico durante un rato una supuesta falla de red del celular cuando lo unico que
      # habia era que la app estaba cerrada. Este servidor NO es un servicio suelto: lo enciende
      # Mentis al arrancar (main.js, encenderPaginaDelCelular) y lo apaga al salir de verdad, a
      # proposito -- dejar la casa escuchando en la red despues de cerrar el programa es
      # justamente lo que nadie espera. Asi que "apagado" casi siempre significa "Mentis cerrado".
      echo "apagado"
      if tasklist //FI "IMAGENAME eq Mentis.exe" 2>/dev/null | grep -qi "Mentis.exe"; then
        echo "  Mentis esta abierto pero el servidor no responde: puede haber muerto al arrancar."
        echo "  Mira el log:  $LOG"
        echo "  Y proba a mano:  mentis-web.sh prender"
      else
        echo "  Mentis esta CERRADO, y la pagina del celular vive con la app: se prende cuando"
        echo "  abris Mentis y se apaga cuando salis. Si el celular dice que no responde, casi"
        echo "  siempre es esto."
        echo "  Abri Mentis, o levantalo suelto con:  mentis-web.sh prender"
      fi
      exit 1
    fi ;;

  apagar)
    if PID="$(_pid_vivo)"; then
      taskkill //PID "$PID" //F >/dev/null 2>&1 && echo "apagado" || { echo "ERROR: no pude apagarlo" >&2; exit 1; }
      rm -f "$ESTADO"
    else
      echo "no estaba prendido"
    fi ;;

  token)
    _token; echo ;;

  rotar)
    # Cambiar el token invalida los favoritos viejos del celular. Importa mas ahora que se entra
    # desde afuera: el token viaja en la direccion y queda guardado en el historial del navegador.
    rm -f "$TOKEN_FILE"
    NUEVO="$(_token)" || exit 1
    echo "token nuevo: $NUEVO"
    echo "OJO: los favoritos viejos dejaron de servir. Volve a guardar la direccion nueva:"
    if PID="$(_pid_vivo)"; then
      echo "  (reinicia el servidor para que tome el token nuevo: mentis-web.sh apagar && mentis-web.sh prender)"
    fi ;;

  direcciones)
    TOKEN="$(_token)" || exit 1
    IP_CASA="$(python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("8.8.8.8", 80)); print(s.getsockname()[0])
except Exception:
    print("127.0.0.1")
finally:
    s.close()' 2>/dev/null)"
    echo "En tu casa (misma WiFi):"
    echo "  http://$IP_CASA:$PUERTO/?t=$TOKEN"
    TS_IP="$(_ip_tailscale)" || TS_IP=""
    echo
    if [ -n "${TS_IP// }" ]; then
      echo "Desde cualquier red (Tailscale):"
      echo "  http://$TS_IP:$PUERTO/?t=$TOKEN"
      echo "  (el celular tiene que tener Tailscale prendido y con tu misma cuenta)"
    else
      echo "Desde cualquier red: falta iniciar sesion en Tailscale."
      echo "  1. Abri Tailscale en la PC e inicia sesion con tu cuenta."
      echo "  2. Instala Tailscale en el celular y entra con LA MISMA cuenta."
      echo "  3. Volve a correr: mentis-web.sh direcciones"
    fi ;;

  *)
    echo "Uso: mentis-web.sh prender|estado|apagar|token|rotar|direcciones" >&2
    exit 2 ;;
esac
