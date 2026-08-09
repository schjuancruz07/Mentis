#!/usr/bin/env bash
# mentis-telefono.sh — Mentis y el teléfono del usuario, por KDE Connect.
#
# Uso:
#   mentis-telefono.sh estado                    # ¿hay teléfono vinculado y al alcance?
#   mentis-telefono.sh emparejar                 # pide la vinculación (se acepta en el teléfono)
#   mentis-telefono.sh notificaciones            # qué notificaciones tiene el teléfono ahora
#   mentis-telefono.sh sonar                     # lo hace sonar para encontrarlo
#   mentis-telefono.sh avisar "<texto>"          # te manda un aviso a la pantalla del teléfono
#   mentis-telefono.sh enviar <archivo|URL>      # se lo manda al teléfono
#   mentis-telefono.sh texto "<texto>"           # le manda un texto (queda en el portapapeles)
#   mentis-telefono.sh portapapeles              # le manda lo que haya copiado en la computadora
#   mentis-telefono.sh bloquear | desbloquear    # bloquea/desbloquea la pantalla del teléfono
#
# POR QUÉ KDE CONNECT Y NO ADB (2026-07-30): el teléfono del usuario (Xiaomi 13C) no tiene a mano las
# Opciones de desarrollador, y sin ellas no hay depuración USB, y sin depuración USB no hay ADB.
# KDE Connect no necesita ninguna de las tres: es una app normal de la tienda, va por WiFi y el
# permiso lo da el usuario una sola vez aceptando la vinculación en la pantalla del teléfono.
#
# LO QUE SE PIERDE respecto de ADB, para que quede escrito y nadie lo busque en vano: no hay
# captura de pantalla del teléfono, no se pueden tocar coordenadas ni tipear en un campo, y no se
# abren apps a control remoto. Eso es depuración USB, no KDE Connect.
#
# LO QUE NO HACE, A PROPÓSITO: el CLI sabe mandar SMS (--send-sms) y acá NO se expone. Escribirle
# a alguien en nombre del usuario no se deshace. Es la misma regla que ya tenía la versión por ADB.
set -uo pipefail

# El ejecutable NO queda en el PATH del shell (instalación por usuario en AppData). Se resuelve a
# mano en vez de confiar en el PATH: el mismo problema que ya costó caro con bash.exe bajo el
# Programador de tareas (ERR-037) y con adb.
_kdeconnect() {
  local c
  for c in "${MENTIS_KDECONNECT:-}" \
           "$HOME/AppData/Local/Programs/KDE Connect/bin/kdeconnect-cli.exe" \
           "${LOCALAPPDATA:-}/Programs/KDE Connect/bin/kdeconnect-cli.exe" \
           "/c/Program Files/KDE Connect/bin/kdeconnect-cli.exe"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v kdeconnect-cli 2>/dev/null && return 0
  return 1
}
KC="$(_kdeconnect)" || {
  echo "ERROR: no encontré KDE Connect. Instalalo con:  winget install KDE.KDEConnect" >&2
  exit 1
}
KC_BIN_DIR="$(dirname "$KC")"

# La salida del CLI viene en la página de códigos de la consola de Windows (CP850 acá) y no en
# UTF-8: sin esto los nombres de dispositivo y las notificaciones con acentos llegan rotos a la
# conversación.
#
# OJO, esto se probó y la primera versión estaba MAL (2026-07-30, lo cazó el test): convertía
# SIEMPRE desde CP850. Como CP850 le asigna un carácter a los 256 bytes posibles, esa conversión
# no falla nunca -- ni siquiera cuando el texto ya venía en UTF-8, en cuyo caso lo rompe ("Mamá"
# salía "Mam├í") y el fallback jamás se enteraba. Hay que preguntar primero si YA es UTF-8 válido,
# que es lo único que iconv sí sabe rechazar, y recién convertir si no lo es. Si iconv no está o
# la conversión falla, pasa el texto tal cual: un acento feo molesta, perder la notificación es
# peor.
_texto() {
  local datos
  datos="$(cat)"
  if ! command -v iconv >/dev/null 2>&1; then printf '%s\n' "$datos"; return 0; fi
  if printf '%s' "$datos" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    printf '%s\n' "$datos"
  else
    printf '%s' "$datos" | iconv -f CP850 -t UTF-8 2>/dev/null || printf '%s\n' "$datos"
  fi
}

# El CLI habla con un demonio (kdeconnectd) por DBus. Si el demonio no está levantado, todo
# devuelve "0 dispositivos" aunque el teléfono esté al lado. Se levanta con Start-Process de
# PowerShell y no con "&" + disown: backgroundear procesos de larga vida desde Git Bash tiene su
# propia historia de fallos en esta máquina (ERR-027).
_asegurar_demonio() {
  # Puerta SOLO para los tests: sin esto, probar el script exige tener el demonio real corriendo,
  # y un test que depende de un proceso ajeno da verde o rojo según el día. En uso normal nadie
  # define esta variable.
  [ "${MENTIS_TELEFONO_SIN_DEMONIO:-0}" = "1" ] && return 0
  tasklist 2>/dev/null | grep -qi "kdeconnectd.exe" && return 0
  # -WorkingDirectory NO es cosmetico (ERR-106): sin el, el demonio hereda como cwd la carpeta
  # desde la que lo llamaron -- que cuando lo prende la app es la carpeta de la app -- y Windows
  # no deja borrar/reemplazar un directorio que algun proceso tiene abierto como cwd, asi que
  # empaquetar fallaba con EBUSY. Se apunta a la carpeta del propio KDE Connect y no a $HOME
  # porque es lo mas compatible para el demonio (y tampoco es una carpeta que se empaquete).
  local kc_exe_win kc_dir_win
  kc_exe_win="$(cygpath -w "$KC_BIN_DIR/kdeconnectd.exe" 2>/dev/null || printf '%s' "$KC_BIN_DIR/kdeconnectd.exe")"
  kc_dir_win="$(cygpath -w "$KC_BIN_DIR" 2>/dev/null || printf '%s' "$KC_BIN_DIR")"
  powershell.exe -NoProfile -NonInteractive -Command \
    "Start-Process -WindowStyle Hidden -WorkingDirectory '$kc_dir_win' -FilePath '$kc_exe_win'" >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    tasklist 2>/dev/null | grep -qi "kdeconnectd.exe" && return 0
  done
  return 1
}

# Un id por línea. --id-only existe justamente para scripts: evita parsear la lista "linda", que
# está traducida y cambia de formato entre versiones.
_ids_disponibles() { "$KC" --list-available --id-only 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' || true; }
_ids_vinculados()  { "$KC" --list-devices   --id-only 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' || true; }
_nombre_de() { "$KC" -d "$1" --list-devices --name-only 2>/dev/null | tr -d '\r' | head -1 | _texto; }

# Devuelve el id del teléfono a usar, o corta con un error que dice QUÉ falta hacer. La diferencia
# entre "no hay ninguno vinculado" y "está vinculado pero no lo veo" es la diferencia entre
# "emparejalo" y "prendé el WiFi": decir cuál de las dos es ahorra el viaje en falso.
_exigir_telefono() {
  local disp vinc
  _asegurar_demonio || { echo "ERROR: no pude levantar el servicio de KDE Connect (kdeconnectd)." >&2; exit 4; }
  disp="$(_ids_disponibles)"
  if [ -n "$disp" ]; then printf '%s' "$(printf '%s\n' "$disp" | head -1)"; return 0; fi
  vinc="$(_ids_vinculados)"
  if [ -n "$vinc" ]; then
    echo "ERROR: el teléfono está vinculado pero ahora mismo no lo veo en la red." >&2
    echo "       Revisá que esté prendido, con la pantalla desbloqueada al menos una vez, y en la" >&2
    echo "       MISMA red WiFi que esta computadora (no en datos móviles)." >&2
    exit 3
  fi
  echo "ERROR: no hay ningún teléfono vinculado todavía. Corré: mentis-telefono.sh emparejar" >&2
  exit 1
}

CMD="${1:-}"; shift || true

case "$CMD" in
  estado)
    _asegurar_demonio || { echo "el servicio de KDE Connect no está corriendo y no pude levantarlo"; exit 4; }
    DISP="$(_ids_disponibles)"
    if [ -n "$DISP" ]; then
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        printf 'conectado: %s (%s)\n' "$(_nombre_de "$id")" "$id"
      done <<< "$DISP"
      exit 0
    fi
    VINC="$(_ids_vinculados)"
    if [ -n "$VINC" ]; then
      echo "vinculado pero fuera de alcance -- prendelo y ponelo en la misma red WiFi"
      exit 3
    fi
    echo "no hay ningún teléfono vinculado -- corré: mentis-telefono.sh emparejar"
    exit 1 ;;

  emparejar)
    _asegurar_demonio || { echo "ERROR: no pude levantar el servicio de KDE Connect." >&2; exit 4; }
    "$KC" --refresh >/dev/null 2>&1 || true
    # Un teléfono que todavía no está vinculado aparece en --list-devices pero NO en
    # --list-available (esa lista es "vinculados Y accesibles"). Por eso acá se busca en la
    # primera: si se usara la segunda, no habría nada a quien pedirle la vinculación.
    OBJETIVO="${1:-}"
    if [ -z "$OBJETIVO" ]; then
      OBJETIVO="$(_ids_vinculados | head -1)"
      [ -n "$OBJETIVO" ] || {
        echo "ERROR: no veo ningún teléfono en la red." >&2
        echo "       En el teléfono: instalá 'KDE Connect' desde Google Play, abrila, y dejala en" >&2
        echo "       la pantalla principal con el WiFi conectado a la misma red que esta computadora." >&2
        exit 1; }
    fi
    "$KC" -d "$OBJETIVO" --pair 2>&1 | _texto
    echo "Pedido de vinculación enviado. Aceptalo en la pantalla del teléfono." ;;

  notificaciones)
    ID="$(_exigir_telefono)"
    SALIDA="$("$KC" -d "$ID" --list-notifications 2>/dev/null | tr -d '\r' | _texto)"
    if [ -z "${SALIDA// }" ]; then
      echo "(el teléfono no tiene notificaciones ahora mismo)"
    else
      printf '%s\n' "$SALIDA" | head -40
    fi ;;

  avisar)
    # Un aviso que aparece en la pantalla del telefono. Es lo que usa Mentis para decirte "termine
    # eso que me pediste" cuando no estas mirando la computadora.
    ID="$(_exigir_telefono)"
    TXT="${1:-}"; [ -n "$TXT" ] || { echo "ERROR: falta el texto del aviso" >&2; exit 2; }
    "$KC" -d "$ID" --ping-msg "$TXT" >/dev/null 2>&1 && echo "aviso enviado al teléfono" || { echo "ERROR: no pude avisarte" >&2; exit 1; } ;;

  sonar)
    ID="$(_exigir_telefono)"
    "$KC" -d "$ID" --ring >/dev/null 2>&1 && echo "lo hice sonar" || { echo "ERROR: no pude hacerlo sonar" >&2; exit 1; } ;;

  enviar)
    ID="$(_exigir_telefono)"
    QUE="${1:-}"; [ -n "$QUE" ] || { echo "ERROR: falta el archivo o la URL a enviar" >&2; exit 2; }
    # Un archivo local hay que mandarlo con ruta de WINDOWS: del otro lado hay un binario nativo
    # que toma "/c/Users/..." literal y no encuentra nada (ERR-004/006, la trampa de siempre).
    if [ -e "$QUE" ]; then
      QUE="$(cygpath -w "$QUE" 2>/dev/null || printf '%s' "$QUE")"
    fi
    "$KC" -d "$ID" --share "$QUE" >/dev/null 2>&1 && echo "enviado al teléfono" || { echo "ERROR: no pude enviarlo" >&2; exit 1; } ;;

  texto)
    ID="$(_exigir_telefono)"
    TXT="${1:-}"; [ -n "$TXT" ] || { echo "ERROR: falta el texto" >&2; exit 2; }
    "$KC" -d "$ID" --share-text "$TXT" >/dev/null 2>&1 && echo "texto enviado al teléfono" || { echo "ERROR: no pude enviarlo" >&2; exit 1; } ;;

  portapapeles)
    ID="$(_exigir_telefono)"
    "$KC" -d "$ID" --send-clipboard >/dev/null 2>&1 && echo "portapapeles enviado" || { echo "ERROR: no pude enviarlo" >&2; exit 1; } ;;

  bloquear)
    ID="$(_exigir_telefono)"
    "$KC" -d "$ID" --lock >/dev/null 2>&1 && echo "teléfono bloqueado" || { echo "ERROR: no pude bloquearlo" >&2; exit 1; } ;;

  desbloquear)
    ID="$(_exigir_telefono)"
    "$KC" -d "$ID" --unlock >/dev/null 2>&1 && echo "teléfono desbloqueado" || { echo "ERROR: no pude desbloquearlo" >&2; exit 1; } ;;

  "")
    echo "Uso: mentis-telefono.sh estado|emparejar|notificaciones|sonar|avisar|enviar|texto|portapapeles|bloquear|desbloquear" >&2
    exit 2 ;;
  *)
    echo "ERROR: comando desconocido '$CMD'" >&2
    exit 2 ;;
esac
