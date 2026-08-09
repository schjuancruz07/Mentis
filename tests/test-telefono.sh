#!/usr/bin/env bash
# test-telefono.sh -- Mentis y el teléfono por KDE Connect (reemplazo de ADB, 2026-07-30).
#
# El teléfono del usuario (Xiaomi 13C) no tiene a mano las Opciones de desarrollador, así que ADB
# quedó descartado y con él todo mentis-android.sh. KDE Connect va por WiFi y no pide depuración.
#
# Se prueba contra un STUB del CLI (MENTIS_KDECONNECT) y no contra el teléfono real: hace falta
# poder correr esto sin tener el teléfono en la mano, y sobre todo poder forzar los estados que
# importan -- "no hay nada vinculado" y "vinculado pero fuera de alcance" -- que son justamente
# los que uno no puede reproducir a voluntad con hardware real.
# Al final hay UNA prueba en vivo contra el CLI de verdad, para no quedarse sólo con el simulacro.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$DIR/mentis-telefono.sh"
fail=0
chk()  { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (esperado '$2', obtuve '$1')"; fail=1; fi; }
tiene() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else echo "FAIL: $1 (no aparece '$3' en: $2)"; fail=1; fi; }

bash -n "$SCRIPT" && echo "ok: mentis-telefono.sh parsea sin errores" || { echo "FAIL: sintaxis"; fail=1; }

MT_DIR="$(mktemp -d)"
trap 'rm -rf "$MT_DIR"' EXIT
STUB="$MT_DIR/kdeconnect-cli.exe"   # el nombre no importa, sí que sea ejecutable
LOG="$MT_DIR/llamadas.log"

cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Simulacro del CLI de KDE Connect. STUB_ESC elige el escenario.
printf '%s\n' "$*" >> "${STUB_LOG:?}"
case "${STUB_ESC:?}" in
  ninguno)          exit 0 ;;                     # ni vinculados ni disponibles
  lejos)
    case "$*" in
      *--list-available*) exit 0 ;;               # vinculado pero NO accesible
      *--list-devices*--name-only*) echo "Xiaomi 13C" ;;
      *--list-devices*) echo "abc123" ;;
    esac ;;
  ok)
    case "$*" in
      *--name-only*)      echo "Xiaomi 13C" ;;
      *--list-available*) echo "abc123" ;;
      *--list-devices*)   echo "abc123" ;;
      *--list-notifications*) printf 'WhatsApp: Mamá: llegaste?\nMercadoLibre: tu paquete salió\n' ;;
    esac ;;
  sinnotis)
    case "$*" in
      *--name-only*)      echo "Xiaomi 13C" ;;
      *--list-available*) echo "abc123" ;;
      *--list-devices*)   echo "abc123" ;;
      *--list-notifications*) exit 0 ;;
    esac ;;
  cp850)
    # Como habla la consola de Windows de verdad: 'á' es el byte 0xA0, no dos bytes UTF-8.
    case "$*" in
      *--name-only*)      printf 'Xiaomi 13C\n' ;;
      *--list-available*) echo "abc123" ;;
      *--list-devices*)   echo "abc123" ;;
      *--list-notifications*) printf 'WhatsApp: Mam\xa0: lleg\xa2 el paquete\n' ;;
    esac ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

_correr() { # _correr <escenario> <args...>
  local esc="$1"; shift
  : > "$LOG"
  MENTIS_KDECONNECT="$STUB" STUB_ESC="$esc" STUB_LOG="$LOG" MENTIS_TELEFONO_SIN_DEMONIO=1 \
    bash "$SCRIPT" "$@" 2>&1
}

echo "== 1. estado dice CUÁL de los dos problemas hay (no un 'no anda' genérico) =="
SAL="$(_correr ninguno estado)"; RC=$?
tiene "sin vincular manda a emparejar" "$SAL" "emparejar"
chk "$RC" "1" "sin vincular sale con codigo 1"

SAL="$(_correr lejos estado)"; RC=$?
tiene "vinculado pero lejos habla de la red WiFi" "$SAL" "misma red WiFi"
chk "$RC" "3" "fuera de alcance sale con codigo 3 (distinto de sin vincular)"

SAL="$(_correr ok estado)"; RC=$?
tiene "con el telefono al alcance lo nombra" "$SAL" "Xiaomi 13C"
chk "$RC" "0" "con telefono disponible sale con codigo 0"

echo "== 2. notificaciones: el caso vacío se dice, no se devuelve un silencio =="
SAL="$(_correr ok notificaciones)"
tiene "lista las notificaciones reales" "$SAL" "Mamá: llegaste?"
SAL="$(_correr sinnotis notificaciones)"
tiene "sin notificaciones lo dice con palabras" "$SAL" "no tiene notificaciones"

# Las dos mitades del problema de codificacion, y las dos importan:
#   - lo que ya viene en UTF-8 NO se toca (la primera version lo rompia: "Mamá" -> "Mam├í");
#   - lo que viene en CP850, que es como habla la consola de Windows, SI se convierte.
SAL="$(_correr ok notificaciones)"
tiene "una notificacion que YA es UTF-8 llega intacta" "$SAL" "salió"
SAL="$(_correr cp850 notificaciones)"
tiene "una notificacion en CP850 se convierte bien" "$SAL" "Mamá: llegó el paquete"

echo "== 3. las acciones llegan al CLI con el dispositivo correcto =="
_correr ok sonar >/dev/null
tiene "sonar usa --ring sobre el id encontrado" "$(cat "$LOG")" "-d abc123 --ring"
_correr ok bloquear >/dev/null
tiene "bloquear usa --lock" "$(cat "$LOG")" "--lock"
_correr ok texto "hola desde la compu" >/dev/null
tiene "texto usa --share-text" "$(cat "$LOG")" "--share-text hola desde la compu"

echo "== 4. un archivo local se manda con ruta de WINDOWS, no MSYS (ERR-004/006) =="
ARCH="$MT_DIR/archivo de prueba.txt"; echo "hola" > "$ARCH"
_correr ok enviar "$ARCH" >/dev/null
LLAMADAS="$(cat "$LOG")"
if printf '%s' "$LLAMADAS" | grep -qE '\-\-share [A-Za-z]:\\'; then
  echo "ok: la ruta viaja en formato Windows (C:\\...)"
else
  echo "FAIL: la ruta no se convirtio a formato Windows: $LLAMADAS"; fail=1
fi
# Una URL NO se toca: cygpath la destrozaria.
_correr ok enviar "https://example.com/foto.jpg" >/dev/null
tiene "una URL se manda tal cual" "$(cat "$LOG")" "--share https://example.com/foto.jpg"

echo "== 5. validaciones de uso =="
_correr ok enviar >/dev/null 2>&1; chk "$?" "2" "enviar sin argumento sale con codigo 2"
_correr ok texto  >/dev/null 2>&1; chk "$?" "2" "texto sin argumento sale con codigo 2"
_correr ok        >/dev/null 2>&1; chk "$?" "2" "sin comando muestra el uso y sale con 2"
_correr ok inventado >/dev/null 2>&1; chk "$?" "2" "un comando desconocido sale con 2"

echo "== 6. NO manda mensajes en nombre del usuario (regla que venía de la version por ADB) =="
SAL="$(_correr ok sms "+5491100000000" "hola" 2>&1)"; RC=$?
chk "$RC" "2" "'sms' no es un comando valido"
if grep -vE '^\s*#' "$SCRIPT" | grep -q -- "--send-sms"; then
  echo "FAIL: el script invoca --send-sms en algun lado"; fail=1
else
  echo "ok: --send-sms no se invoca en ninguna parte del codigo"
fi

echo "== 7. EN VIVO: el CLI real esta instalado y responde =="
# Sin esto, todo lo de arriba prueba el simulacro y nada mas. No se le exige un telefono
# vinculado (el usuario todavia tiene que emparejarlo), solo que el binario exista y conteste.
SAL_VIVO="$(MENTIS_TELEFONO_SIN_DEMONIO=1 bash "$SCRIPT" estado 2>&1)"; RC_VIVO=$?
if [ "$RC_VIVO" -ne 2 ] && printf '%s' "$SAL_VIVO" | grep -qvi "no encontré KDE Connect"; then
  echo "ok: el CLI real respondio ($SAL_VIVO)"
else
  echo "FAIL: el CLI real no respondio: $SAL_VIVO"; fail=1
fi

echo
if [ "$fail" = "0" ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit "$fail"
