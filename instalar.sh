#!/usr/bin/env bash
# instalar.sh -- deja Mentis andando desde una copia recién clonada.
#
# Para quien lo lea: esto no hace magia. Revisa que estén los programas que hacen falta, instala
# las dependencias, te pide la clave de NVIDIA y arma la aplicación. Cada paso dice qué está
# haciendo y, si algo falla, dice exactamente qué hacer -- en castellano, no un error de consola.
#
# Uso:
#   bash instalar.sh                 instala
#   bash instalar.sh --solo-revisar  dice qué falta y no toca nada

set -uo pipefail
INS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INS_HERE" || exit 1
INS_SOLO_REVISAR=0
[ "${1:-}" = "--solo-revisar" ] && INS_SOLO_REVISAR=1

_ok()    { printf '  \033[32mok\033[0m    %s\n' "$1"; }
_falta() { printf '  \033[31mfalta\033[0m %s\n' "$1"; }
_paso()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo ""
echo "  ================================"
echo "     Instalación de Mentis"
echo "  ================================"

# --- 1. Lo que tiene que estar ----------------------------------------------------------------
# Se chequea TODO antes de instalar nada. Es preferible decir "te faltan tres cosas" al principio
# que fallar a la mitad con el sistema a medio armar.
_paso "1. Revisando qué hay instalado"
FALTAN=0

if command -v node >/dev/null 2>&1; then
  NODE_V="$(node --version 2>/dev/null | tr -d 'v\r')"
  NODE_MAJOR="${NODE_V%%.*}"
  if [ "${NODE_MAJOR:-0}" -ge 20 ] 2>/dev/null; then
    _ok "Node.js $NODE_V"
  else
    _falta "Node.js $NODE_V es muy viejo (hace falta 20 o mayor) -> https://nodejs.org/"
    FALTAN=$((FALTAN+1))
  fi
else
  _falta "Node.js -> instalalo de https://nodejs.org/ (elegí la versión LTS)"
  FALTAN=$((FALTAN+1))
fi

if command -v python3 >/dev/null 2>&1; then
  _ok "Python $(python3 --version 2>&1 | awk '{print $2}' | tr -d '\r')"
else
  _falta "Python 3 -> instalalo de https://www.python.org/downloads/"
  echo "         IMPORTANTE: marcá 'Add Python to PATH' durante la instalación."
  FALTAN=$((FALTAN+1))
fi

if command -v curl >/dev/null 2>&1; then _ok "curl"; else
  _falta "curl (viene con Git para Windows) -> https://git-scm.com/download/win"
  FALTAN=$((FALTAN+1))
fi

# GIT BASH NO ES OPCIONAL, aunque no lo parezca. La ventana de Mentis busca bash.exe de Git para
# Windows en rutas fijas (ver resolveBashPath en app/main.js) y sin eso no arranca: el motor entero
# es bash. Antes solo se chequeaba curl, que viene con Git -- pero alguien puede tener curl por
# otro lado, pasar el chequeo y encontrarse con una aplicacion que abre y no responde.
BASH_GIT=""
for c in "/c/Program Files/Git/bin/bash.exe" "/c/Program Files/Git/usr/bin/bash.exe" \
         "/c/Program Files (x86)/Git/bin/bash.exe" "/c/Program Files (x86)/Git/usr/bin/bash.exe"; do
  [ -f "$c" ] && { BASH_GIT="$c"; break; }
done
if [ -n "$BASH_GIT" ]; then
  _ok "Git Bash"
else
  _falta "Git para Windows -> https://git-scm.com/download/win"
  echo "         Es lo que hace funcionar el motor de Mentis; sin esto la ventana abre y no responde."
  FALTAN=$((FALTAN+1))
fi

# VS Code es OPCIONAL: sirve para que Mentis pueda abrirte archivos en el editor, y ese conector
# arranca apagado. Se avisa, no se exige -- pedir algo que no hace falta es una barrera inventada.
if command -v code >/dev/null 2>&1 || [ -d "$HOME/AppData/Local/Programs/Microsoft VS Code" ]; then
  _ok "Visual Studio Code (opcional, para abrir archivos en el editor)"
else
  printf '  \033[33m--\033[0m    Visual Studio Code no está. Es OPCIONAL: sin él, Mentis funciona igual,\n'
  printf '        solo que no puede abrirte archivos en el editor. https://code.visualstudio.com/\n'
fi

if [ "$FALTAN" -gt 0 ]; then
  echo ""
  echo "  Faltan $FALTAN cosa(s). Instalalas, cerrá esta ventana, abrí una nueva y volvé a correr:"
  echo "      bash instalar.sh"
  echo ""
  echo "  (Hay que abrir una ventana NUEVA: la actual no ve los programas que instalaste recién.)"
  exit 1
fi

if [ "$INS_SOLO_REVISAR" = "1" ]; then
  echo ""
  echo "  Está todo lo que hace falta. Para instalar de verdad:  bash instalar.sh"
  exit 0
fi

# --- 2. Dependencias --------------------------------------------------------------------------
_paso "2. Instalando dependencias (tarda unos minutos)"
if [ -f "app/package.json" ]; then
  ( cd app && npm install --no-audit --no-fund >/dev/null 2>&1 ) \
    && _ok "las de la ventana" \
    || { _falta "no pude instalar las dependencias de la ventana"; echo "         Probá a mano:  cd app && npm install"; exit 1; }
fi
if [ -f "mcp-bridge/package.json" ]; then
  ( cd mcp-bridge && npm install --no-audit --no-fund >/dev/null 2>&1 ) \
    && _ok "las del puente de servicios" \
    || _falta "las del puente de servicios (no es grave: Mentis anda igual, sin conectores externos)"
fi

# --- 3. La clave ------------------------------------------------------------------------------
# Se delega en mentis-instalar.sh, que ya sabe pedirla y guardarla donde corresponde. No se
# duplica esa lógica acá: dos lugares que guardan claves es un lugar de más donde equivocarse.
_paso "3. Configurando tu clave de IA"
if [ -f "engine/.nv-secrets" ] && grep -q "NVIDIA_API_KEY=..*" engine/.nv-secrets 2>/dev/null; then
  _ok "ya tenías una clave configurada"
elif [ -f "mentis-instalar.sh" ]; then
  bash mentis-instalar.sh configurar || {
    echo ""
    echo "  La configuración quedó a medias. Podés retomarla cuando quieras con:"
    echo "      bash mentis-instalar.sh configurar"
  }
else
  _falta "no encontré mentis-instalar.sh"
fi

# --- 4. La aplicación -------------------------------------------------------------------------
_paso "4. Armando la aplicación"
if [ -f "app/package.json" ]; then
  ( cd app && npm run empaquetar >/dev/null 2>&1 ) \
    && _ok "lista en dist/Mentis-win32-x64/Mentis.exe" \
    || { _falta "no se pudo armar la ventana"
         echo "         Mentis igual funciona desde la consola:  bash mentis-chat.sh"
         echo "         Para ver el error:  cd app && npm run empaquetar"; }
fi

# --- 5. Que ande de verdad --------------------------------------------------------------------
# El paso que decide si esto sirvió: una llamada real al modelo. Que los archivos estén en su
# lugar no significa que funcione.
_paso "5. Probando que responda"
if [ -f "engine/ask-nvidia.sh" ]; then
  RESP="$(timeout 90 bash engine/ask-nvidia.sh -q fast "Decí solamente: listo" 2>&1 | head -1 | tr -d '\r')"
  if [ -n "$RESP" ] && [[ "$RESP" != ERROR:* ]] && [[ "$RESP" != *"API"* ]]; then
    _ok "contestó: $RESP"
    echo ""
    echo "  ================================"
    echo "     Mentis está listo."
    echo "  ================================"
    echo ""
    echo "  Abrilo desde:  dist/Mentis-win32-x64/Mentis.exe"
    echo "  O desde la consola:  bash mentis-chat.sh"
    echo ""
    exit 0
  fi
  _falta "el modelo no contestó"
  echo "         Respuesta: ${RESP:-(vacía)}"
  echo ""
  echo "  Casi siempre es la clave. Revisala con:"
  echo "      bash mentis-diagnostico.sh"
  exit 1
fi
