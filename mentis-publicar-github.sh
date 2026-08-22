#!/usr/bin/env bash
# mentis-publicar-github.sh -- lleva la version publica generada al repositorio de GitHub.
#
# POR QUE EXISTE ESTE ARCHIVO (2026-08-22). Hasta hoy este paso era "copiá.repo-publico adentro
# del clon, git add -A, commit, push" escrito en un comentario. Se hizo de esa forma, se miró el
# diff antes de empujar, y el diff BORRABA once archivos:
#
#     LICENSE  CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md.gitignore
#.github/ISSUE_TEMPLATE/*.github/PULL_REQUEST_TEMPLATE.md  instalar.sh
#
# Ninguno de esos archivos existe en la instalacion del usuario: viven SOLO en el repositorio. El
# generador no los conoce, no puede conocerlos, y un `git add -A` sobre una copia limpia los
# borra a todos. Un repositorio publico sin LICENSE deja de ser usable legalmente, y sin
# instalar.sh nadie que lo clone puede arrancarlo.
#
# La costumbre de mirar el diff antes de empujar es lo unico que lo evito esa vez. Este script
# existe para que no dependa de la costumbre.
#
# Uso:
#   mentis-publicar-github.sh                 prepara el commit y MUESTRA el diff (no empuja)
#   mentis-publicar-github.sh --empujar       ademas hace el push
set -uo pipefail
MPG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPG_FUENTE="$MPG_HERE/.repo-publico"
MPG_URL="${MENTIS_REPO_URL:-https://github.com/usuario/Mentis.git}"
MPG_EMPUJAR=0
[ "${1:-}" = "--empujar" ] && MPG_EMPUJAR=1

# LO QUE ES DEL REPOSITORIO Y NO DE MENTIS. Se conserva tal como esta publicado: no se toca, no se
# pisa y no se borra. Si alguna vez uno de estos tiene que cambiar, se cambia en GitHub.
MPG_SOLO_GITHUB=(
  "LICENSE" "CONTRIBUTING.md" "CODE_OF_CONDUCT.md" "SECURITY.md" ".gitignore"
  ".github" "instalar.sh"
)

[ -d "$MPG_FUENTE" ] || {
  echo "No existe $MPG_FUENTE. Genera primero la version publica:" >&2
  echo "  bash mentis-repo-publico.sh" >&2
  exit 1
}

MPG_TMP="$(mktemp -d)"
trap 'rm -rf "$MPG_TMP"' EXIT
MPG_CLON="$MPG_TMP/clon"

echo "== Clonando el repositorio publicado =="
if ! git clone --quiet "$MPG_URL" "$MPG_CLON" 2>&1; then
  echo "ERROR: no se pudo clonar $MPG_URL" >&2
  exit 1
fi

echo "== Guardando lo que es del repositorio =="
MPG_GUARDA="$MPG_TMP/guarda"
mkdir -p "$MPG_GUARDA"
for f in "${MPG_SOLO_GITHUB[@]}"; do
  if [ -e "$MPG_CLON/$f" ]; then
    mkdir -p "$MPG_GUARDA/$(dirname "$f")"
    cp -r "$MPG_CLON/$f" "$MPG_GUARDA/$f"
    echo "   guardado: $f"
  fi
done

echo "== Reemplazando el contenido por la version publica =="
find "$MPG_CLON" -mindepth 1 -maxdepth 1 -not -name ".git" -exec rm -rf {} + 2>/dev/null
cp -r "$MPG_FUENTE/." "$MPG_CLON/"

echo "== Devolviendo lo que es del repositorio =="
for f in "${MPG_SOLO_GITHUB[@]}"; do
  if [ -e "$MPG_GUARDA/$f" ]; then
    mkdir -p "$MPG_CLON/$(dirname "$f")"
    cp -r "$MPG_GUARDA/$f" "$MPG_CLON/$f"
  fi
done

cd "$MPG_CLON" || exit 1
git add -A >/dev/null 2>&1

# LA GUARDA QUE IMPORTA: si alguno de los archivos del repositorio sigue apareciendo como borrado,
# algo salio mal y NO se publica. Es la comprobacion, no la intencion.
MPG_PERDIDOS=""
for f in "${MPG_SOLO_GITHUB[@]}"; do
  if git diff --cached --name-status | grep -qE "^D[[:space:]]+$f(/|$)"; then
    MPG_PERDIDOS="$MPG_PERDIDOS $f"
  fi
done
if [ -n "${MPG_PERDIDOS// }" ]; then
  echo >&2
  echo "FRENO: la publicacion borraria archivos del repositorio:$MPG_PERDIDOS" >&2
  echo "No se publica nada." >&2
  exit 1
fi

echo
echo "== Lo que va a cambiar =="
git diff --cached --shortstat
echo
echo "-- archivos nuevos:"
git diff --cached --name-status | grep "^A" | awk '{print "     "$2}' | head -30
NUEVOS_TOT="$(git diff --cached --name-status | grep -c "^A")"
[ "${NUEVOS_TOT:-0}" -gt 30 ] && echo "... y $((NUEVOS_TOT - 30)) mas"
echo
echo "-- archivos que se borran:"
BORRADOS="$(git diff --cached --name-status | grep "^D" | awk '{print "     "$2}')"
if [ -n "${BORRADOS// }" ]; then printf '%s\n' "$BORRADOS"; else echo "     (ninguno)"; fi

if [ "$MPG_EMPUJAR" != "1" ]; then
  echo
  echo "Esto fue una PREPARACION: no se empujo nada."
  echo "Para publicar de verdad:  bash mentis-publicar-github.sh --empujar"
  exit 0
fi

VER="$(cat "$MPG_HERE/VERSION" 2>/dev/null | tr -d '\r\n ')"
echo
echo "== Publicando =="
# EL CORREO DEL COMMIT VA EN LA DIRECCION 'noreply' DE GITHUB (2026-08-22). El primer intento de
# push fue rechazado con "push declined due to email privacy restrictions": la cuenta tiene
# activada la proteccion que impide que su correo real quede escrito en un repositorio publico, y
# el commit lo llevaba porque asi esta la configuracion global de git en esta maquina.
#
# La respuesta correcta NO es apagar esa proteccion: es usar la direccion que GitHub da para esto.
# Se configura SOLO en el clon temporal -- la configuracion global de la maquina no se toca, porque
# es del usuario y vale para todos sus otros repositorios.
MPG_NOREPLY="${MENTIS_GIT_NOREPLY:-289528923+usuario@users.noreply.github.com}"
git config user.email "$MPG_NOREPLY"
echo "   commit como: $MPG_NOREPLY"
git commit --quiet -m "Mentis ${VER:-actualizacion}" 2>&1 | tail -3
if git push 2>&1 | tail -5; then
  echo "publicado en $MPG_URL"
else
  echo "ERROR: el push fallo." >&2
  echo "  - 'email privacy restrictions': el correo del commit no es el de noreply (ver arriba)." >&2
  echo "  - 'Authentication failed': faltan las credenciales de GitHub en esta maquina." >&2
  echo "  - 'rejected / non-fast-forward': alguien publico algo despues del clon; volve a correrlo." >&2
  exit 1
fi
