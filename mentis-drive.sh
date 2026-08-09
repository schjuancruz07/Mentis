#!/usr/bin/env bash
# mentis-drive.sh -- subir archivos a Google Drive por la app de escritorio (2026-08-03).
#
# POR QUE ASI Y NO POR API: el conector de Google Workspace no funciona (token vencido, y
# re-autenticar es algo que solo puede hacer el usuario). Pero Drive de escritorio SI anda y monta las
# cuentas como unidades de Windows. Copiar un archivo a esa unidad lo sube: no hace falta ninguna
# credencial, ningun token que se vence, ningun permiso nuevo. Idea del usuario (2026-08-03).
#
# LO QUE ESTO NO HACE, DICHO DE ENTRADA: sube el archivo tal cual. NO lo convierte a formato
# Google Docs editable -- un.docx queda como.docx en Drive. Para convertirlo hace falta la API,
# que es justo lo que no anda.
#
# TRES CUENTAS MONTADAS, Y POR ESO NUNCA ADIVINA. En esta maquina hay tres cuentas de Google
# montadas a la vez (G:, H:, J:). Mandar un archivo del usuario a la cuenta equivocada -- por ejemplo,
# algo personal a la cuenta del taller -- no es un error que se arregle borrandolo. Si hay mas de
# una cuenta y nadie dijo cual, ESTO NO SUBE NADA: lista las cuentas y pide que elijan. El default
# se puede fijar de una vez con MENTIS_DRIVE_CUENTA (o en mentis-settings.json).
#
# Uso:
#   mentis-drive.sh estado                          -> si Drive corre y que cuentas hay
#   mentis-drive.sh cuentas                         -> solo la lista de cuentas
#   mentis-drive.sh subir <archivo> [cuenta] [subcarpeta]
#   mentis-drive.sh prender                         -> levanta Drive y espera el montaje
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

DRIVE_ESPERA="${MENTIS_DRIVE_ESPERA:-45}"     # segundos maximos esperando el montaje

_ps() { MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }

# --- que cuentas hay montadas -------------------------------------------------------------------
# Se leen del propio Windows (el VolumeName de cada unidad trae el mail), no de una lista escrita
# a mano: si el usuario agrega o saca una cuenta, esto se entera solo.
_cuentas() {
  _ps '
    Get-CimInstance Win32_LogicalDisk | Where-Object { $_.VolumeName -like "*@*" -and $_.DriveType -eq 3 } |
      ForEach-Object {
        $mail = ($_.VolumeName -split " - ")[0]
        "{0}|{1}" -f $_.DeviceID.TrimEnd(":"), $mail
      }'
}

_drive_exe() {
  _ps '
    $base = "C:\Program Files\Google\Drive File Stream"
    if (-not (Test-Path $base)) { exit }
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "^\d+\." } |
      Sort-Object { [version]($_.Name) } -Descending |
      ForEach-Object { Join-Path $_.FullName "GoogleDriveFS.exe" } |
      Where-Object { Test-Path $_ } | Select-Object -First 1'
}

_corriendo() {
  local n; n="$(_ps '(@(Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue)).Count')"
  [ -n "$n" ] && [ "$n" != "0" ]
}

# --- prender Drive y esperar a que monte ----------------------------------------------------------
_prender() {
  if _corriendo && [ -n "$(_cuentas)" ]; then return 0; fi
  local exe; exe="$(_drive_exe)"
  if [ -z "$exe" ]; then
    echo "ERROR: no encuentro GoogleDriveFS.exe -- Drive de escritorio no parece instalado." >&2
    return 1
  fi
  if ! _corriendo; then
    echo "[drive] Drive no estaba corriendo; lo levanto..." >&2
    # Start-Process y no "&": backgroundear procesos de larga vida desde Git Bash tiene su propia
    # historia de fallos en esta maquina (ERR-027). -WorkingDirectory fuera de Mentis para no
    # dejar la carpeta bloqueada (ERR-106): Windows no deja borrar un directorio que algun proceso
    # tiene abierto como cwd, y eso rompia el empaquetado de la app.
    _ps "Start-Process -FilePath '$exe' -WorkingDirectory \$env:USERPROFILE -WindowStyle Hidden" >/dev/null
  fi
  # El proceso arranca enseguida pero las unidades tardan: se espera al MONTAJE, no al proceso.
  local i
  for i in $(seq 1 "$DRIVE_ESPERA"); do
    [ -n "$(_cuentas)" ] && { echo "[drive] montado tras ${i}s" >&2; return 0; }
    sleep 1
  done
  echo "ERROR: Drive arranco pero no monto ninguna unidad en ${DRIVE_ESPERA}s." >&2
  return 1
}

# --- default de cuenta ----------------------------------------------------------------------------
_cuenta_default() {
  [ -n "${MENTIS_DRIVE_CUENTA:-}" ] && { printf '%s' "$MENTIS_DRIVE_CUENTA"; return 0; }
  local f="$HERE/mentis-settings.json"
  [ -f "$f" ] || return 1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
v = ((d.get("profile") or {}).get("driveCuenta") or "").strip()
sys.stdout.write(v)
' "$f" 2>/dev/null
}

_listar_bonito() {
  local linea letra mail
  while IFS='|' read -r letra mail; do
    [ -z "$letra" ] && continue
    printf '  %s:  %s\n' "$letra" "$mail"
  done <<< "$(_cuentas)"
}

case "${1:-}" in
  estado)
    if _corriendo; then echo "Drive de escritorio: CORRIENDO"; else echo "Drive de escritorio: apagado"; fi
    C="$(_cuentas)"
    if [ -n "$C" ]; then
      echo "Cuentas montadas:"
      _listar_bonito
    else
      echo "Cuentas montadas: ninguna"
    fi
    D="$(_cuenta_default 2>/dev/null || true)"
    [ -n "$D" ] && echo "Cuenta por defecto configurada: $D"
    exit 0 ;;
  cuentas)
    _prender || exit 1
    _listar_bonito
    exit 0 ;;
  prender)
    _prender || exit 1
    echo "Drive listo."
    exit 0 ;;
  subir) : ;;
  ""|-h|--help)
    sed -n '2,25p' "$0" | sed 's/^# \?//'
    exit 0 ;;
  *)
    echo "ERROR: no conozco '$1'. Usa: estado | cuentas | prender | subir" >&2
    exit 2 ;;
esac

# --- subir ---------------------------------------------------------------------------------------
ARCHIVO="${2:-}"
CUENTA="${3:-}"
SUBCARPETA="${4:-}"

if [ -z "$ARCHIVO" ]; then
  echo "ERROR: falta el archivo. Uso: mentis-drive.sh subir <archivo> [cuenta] [subcarpeta]" >&2
  exit 2
fi
if [ ! -f "$ARCHIVO" ]; then
  echo "ERROR: no existe el archivo '$ARCHIVO'." >&2
  exit 1
fi

_prender || exit 1

LISTA="$(_cuentas)"
[ -n "$LISTA" ] || { echo "ERROR: Drive corre pero no hay ninguna cuenta montada." >&2; exit 1; }
CANT="$(printf '%s\n' "$LISTA" | grep -c '|')"

[ -n "$CUENTA" ] || CUENTA="$(_cuenta_default 2>/dev/null || true)"

if [ -z "$CUENTA" ]; then
  if [ "$CANT" -gt 1 ]; then
    # NO se elige por el usuario. Un archivo suyo en la cuenta equivocada no se arregla borrandolo.
    echo "Hay $CANT cuentas de Google montadas y no me dijiste a cual subirlo:" >&2
    _listar_bonito >&2
    echo "" >&2
    echo "Volve a pedirlo indicando la cuenta (la letra o el mail). Para no tener que decirlo" >&2
    echo "cada vez, se puede fijar una por defecto con MENTIS_DRIVE_CUENTA o en el perfil." >&2
    exit 3
  fi
  CUENTA="$(printf '%s' "$LISTA" | cut -d'|' -f1)"
fi

# La cuenta puede venir como letra ("H"), como unidad ("H:"), como mail completo o como un
# PEDAZO del mail ("schneider.rd"). Lo ultimo no es un capricho: nadie dice el mail entero, y en
# la primera prueba real Mentis fallo justamente por eso -- el usuario dijo "la cuenta schneider.rd",
# el matcher exigia el mail exacto, y el turno termino preguntando cual de las tres era, con la
# respuesta a la vista en la observacion anterior.
#
# La coincidencia parcial solo vale si es INEQUIVOCA. Si un pedazo matchea dos cuentas, no se
# elige la primera: se pregunta. Adivinar aca es mandar un archivo del usuario a la cuenta
# equivocada, que es el unico error de este script que no se arregla borrando algo.
CUENTA_L="$(printf '%s' "$CUENTA" | tr '[:upper:]' '[:lower:]' | sed 's/:$//')"
LETRA=""
COINCIDENCIAS=""
while IFS='|' read -r l m; do
  [ -z "$l" ] && continue
  l_l="$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')"
  m_l="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
  # exacto (letra o mail completo): gana enseguida, sin mirar el resto
  if [ "$CUENTA_L" = "$l_l" ] || [ "$CUENTA_L" = "$m_l" ]; then LETRA="$l"; COINCIDENCIAS=""; break; fi
  # parcial: se acumula para ver despues si fue una sola
  case "$m_l" in *"$CUENTA_L"*) COINCIDENCIAS="$COINCIDENCIAS $l" ;; esac
done <<< "$LISTA"

if [ -z "$LETRA" ]; then
  N_COIN="$(printf '%s' "$COINCIDENCIAS" | wc -w | tr -d ' ')"
  if [ "$N_COIN" = "1" ]; then
    LETRA="$(printf '%s' "$COINCIDENCIAS" | tr -d ' ')"
  elif [ "$N_COIN" -gt 1 ]; then
    echo "ERROR: '$CUENTA' coincide con MAS DE UNA cuenta montada; no voy a elegir por vos:" >&2
    _listar_bonito >&2
    exit 3
  else
    echo "ERROR: no tengo montada ninguna cuenta que coincida con '$CUENTA'. Las que hay:" >&2
    _listar_bonito >&2
    exit 3
  fi
fi

# "Mi unidad" en español; se resuelve mirando, no suponiendo -- el nombre cambia con el idioma
# de la cuenta y hardcodearlo lo rompe en la primera cuenta en ingles.
RAIZ=""
for cand in "Mi unidad" "My Drive"; do
  if [ -d "/${LETRA,}/$cand" ]; then RAIZ="/${LETRA,}/$cand"; break; fi
done
[ -n "$RAIZ" ] || { echo "ERROR: la unidad ${LETRA}: esta montada pero no encuentro 'Mi unidad' ni 'My Drive' adentro." >&2; exit 1; }

DESTINO_DIR="$RAIZ"
if [ -n "$SUBCARPETA" ]; then
  DESTINO_DIR="$RAIZ/$SUBCARPETA"
  mkdir -p "$DESTINO_DIR" 2>/dev/null || { echo "ERROR: no pude crear '$SUBCARPETA' en Drive." >&2; exit 1; }
fi

NOMBRE="$(basename "$ARCHIVO")"
DESTINO="$DESTINO_DIR/$NOMBRE"
ORIGEN_BYTES="$(wc -c < "$ARCHIVO" | tr -d ' ')"

cp -f "$ARCHIVO" "$DESTINO" 2>/dev/null || { echo "ERROR: no pude copiar a '$DESTINO'." >&2; exit 1; }

# VERIFICAR QUE LLEGO, no dar por hecho que la copia salio bien. Drive es un sistema de archivos
# virtual: la escritura puede aceptarse y despues fallar la sincronizacion. Comparar el tamaño es
# lo minimo para no reportar "subido" sobre un archivo de 0 bytes -- justo el tipo de afirmacion
# infundada que la guarda HAD_REAL_ACTION existe para impedir.
for _ in $(seq 1 20); do
  [ -f "$DESTINO" ] && [ "$(wc -c < "$DESTINO" 2>/dev/null | tr -d ' ')" = "$ORIGEN_BYTES" ] && break
  sleep 0.25
done
DEST_BYTES="$(wc -c < "$DESTINO" 2>/dev/null | tr -d ' ')"
if [ "$DEST_BYTES" != "$ORIGEN_BYTES" ]; then
  echo "ERROR: el archivo llego incompleto a Drive ($DEST_BYTES de $ORIGEN_BYTES bytes)." >&2
  exit 1
fi

MAIL="$(printf '%s' "$LISTA" | grep "^$LETRA|" | cut -d'|' -f2)"
echo "Subido a Drive ($MAIL): ${SUBCARPETA:+$SUBCARPETA/}$NOMBRE  ($ORIGEN_BYTES bytes)"
echo "Ruta local: $(cygpath -w "$DESTINO" 2>/dev/null || printf '%s' "$DESTINO")"
echo "AVISO: quedo como archivo tal cual (no convertido a documento de Google editable)."
