#!/usr/bin/env bash
# mentis-publicar-repo.sh -- publicar tus mejoras al repositorio publico, en un solo comando.
#
# EL PROBLEMA QUE RESUELVE (2026-08-09): el repositorio publico es una FOTO. Cuando cambias algo
# en tu Mentis, ese cambio no llega solo a la gente que lo instalo: hay que generar la version
# limpia, copiarla al clon, verificar que no se cuele nada personal, commitear y subir. Cinco
# pasos, cada uno con su forma de salir mal, y uno de ellos -- la verificacion -- es el que evita
# publicar tu nombre, tu  o una clave.
#
# Cinco pasos manuales que hay que recordar es un proceso que se hace mal o no se hace. Esto los
# junta y NO deja saltearse la verificacion.
#
# LO QUE NUNCA HACE: tocar tu Mentis. Trabaja sobre copias. Tu instalacion sigue con el rol # tus documentos y tu nombre -- la limpieza es solo para lo que se publica.
#
# Uso:
#   mentis-publicar-repo.sh            prepara todo y te muestra que subiria (NO sube)
#   mentis-publicar-repo.sh -s         sube de verdad
#   mentis-publicar-repo.sh -m "..."   con tu propio mensaje

set -uo pipefail
MPR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# El clon vive en una ruta CORTA a proposito: con la ruta larga de los temporales, git falla con
# "Filename too long" al clonar. Pasó de verdad la primera vez.
MPR_CLON="${MENTIS_CLON_REPO:-/c/mentis-repo}"
MPR_URL="https://github.com/usuario/Mentis.git"
MPR_SUBIR=0
MPR_MENSAJE=""

while getopts ":sm:h" opt; do
  case "$opt" in
    s) MPR_SUBIR=1 ;;
    m) MPR_MENSAJE="$OPTARG" ;;
    h) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "opcion invalida: -$OPTARG" >&2; exit 64 ;;
  esac
done

echo "== Publicar Mentis al repositorio publico =="
echo

# --- 1. El clon de trabajo --------------------------------------------------------------------
if [ -d "$MPR_CLON/.git" ]; then
  echo "-- actualizando el clon de trabajo"
  ( cd "$MPR_CLON" && timeout 120 git fetch --quiet origin 2>/dev/null && git reset --hard --quiet origin/main 2>/dev/null ) \
    || { echo "   No pude actualizar el clon. ¿Hay internet?"; exit 1; }
else
  echo "-- clonando el repositorio (primera vez)"
  mkdir -p "$(dirname "$MPR_CLON")" 2>/dev/null
  timeout 300 git clone --quiet "$MPR_URL" "$MPR_CLON" 2>/dev/null \
    || { echo "   No pude clonar $MPR_URL"; exit 1; }
  # Sin esto GitHub rechaza el push con "email privacy restrictions".
  ( cd "$MPR_CLON" && git config user.name "usuario" \
    && git config user.email "289528923+usuario@users.noreply.github.com" )
fi
echo "   $MPR_CLON"

# --- 2. Generar la version limpia -------------------------------------------------------------
echo "-- generando la version publica (sin datos personales ni el rol )"
if ! bash "$MPR_HERE/mentis-repo-publico.sh" >/dev/null 2>&1; then
  echo "   FALLO la limpieza. Corré 'bash mentis-repo-publico.sh' para ver qué pasó."
  exit 1
fi

# --- 3. Copiar encima -------------------------------------------------------------------------
# Se borra primero lo que habia (menos.git y los archivos propios del repositorio) para que un
# archivo que dejo de existir en Mentis tambien desaparezca del repositorio. Sin esto, los
# borrados nunca llegarian.
echo "-- pasando los cambios al clon"
( cd "$MPR_CLON" && find. -mindepth 1 -maxdepth 1 \
    ! -name '.git' ! -name 'LICENSE' ! -name '.github' \
    ! -name 'CONTRIBUTING.md' ! -name 'CODE_OF_CONDUCT.md' ! -name 'SECURITY.md' \
    ! -name 'README.md' ! -name '.gitignore' ! -name 'instalar.sh' \
    -exec rm -rf {} + 2>/dev/null )
cp -r "$MPR_HERE/.repo-publico/." "$MPR_CLON/" 2>/dev/null

# --- 4. LA VERIFICACION, que no se puede saltear ----------------------------------------------
# Va sobre el clon y no sobre la carpeta intermedia: se verifica lo que se va a subir, no un paso
# anterior. Si esto falla, no se sube nada.
echo "-- verificando que no se cuele nada personal"
# La salida se GUARDA y despues se busca, en vez de encadenar con `| grep -q`.
# Con `grep -q` el pipe se cierra apenas encuentra la coincidencia, el script que sigue
# escribiendo muere con SIGPIPE (141), y `set -o pipefail` toma ese 141 como fallo del conjunto:
# la verificacion pasaba y el publicador la daba por fallada. Ademas asi se corre UNA sola vez en
# vez de dos (una para preguntar y otra para mostrar el detalle).
MPR_SALIDA="$(bash "$MPR_HERE/mentis-repo-publico.sh" -v "$MPR_CLON" 2>&1)"
if ! printf '%s' "$MPR_SALIDA" | grep -q "^LISTO"; then
  echo
  echo "   NO SE PUBLICA: la verificación encontró algo. El detalle:"
  printf '%s\n' "$MPR_SALIDA" | grep -E "FALLA|ROTO" | head -8
  exit 1
fi
echo "   ok: limpio"

# --- 5. Que cambia ----------------------------------------------------------------------------
cd "$MPR_CLON" || exit 1
git add -A 2>/dev/null
CAMBIOS="$(git diff --cached --stat 2>/dev/null | tail -1)"
N="$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"

if [ "${N:-0}" -eq 0 ]; then
  echo
  echo "No hay nada nuevo para publicar: el repositorio ya está igual que tu Mentis."
  exit 0
fi

echo
echo "== Cambios que se publicarían =="
git diff --cached --stat 2>/dev/null | tail -12
echo

# Un ultimo vistazo a los nombres, por si aparece algo que no deberia estar ahi.
SOSPECHOSOS="$(git diff --cached --name-only 2>/dev/null | grep -iE "secret|token|\.pem$|conversations/|memoria/|history\.jsonl|settings\.json" | grep -v "firma-publica" | head -5)"
if [ -n "$SOSPECHOSOS" ]; then
  echo "OJO, revisá estos archivos antes de subir:"
  printf '%s\n' "$SOSPECHOSOS" | sed 's/^/  /'
  echo
fi

if [ "$MPR_SUBIR" != "1" ]; then
  echo "Esto fue un ensayo: NO se subió nada."
  echo "Para publicar de verdad:  bash mentis-publicar-repo.sh -s"
  exit 0
fi

# --- 6. Subir ---------------------------------------------------------------------------------
[ -n "$MPR_MENSAJE" ] || MPR_MENSAJE="Mentis $(cat "$MPR_HERE/VERSION" 2>/dev/null | tr -d '\r')"
git commit -q -m "$MPR_MENSAJE" 2>/dev/null
if timeout 300 git push origin main 2>&1 | tail -2; then
  echo
  echo "Listo. Ya lo pueden bajar con:  bash mentis-actualizar.sh instalar"
else
  echo "El push falló. El commit quedó hecho: podés reintentar con"
  echo "    cd $MPR_CLON && git push origin main"
  exit 1
fi
