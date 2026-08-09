#!/usr/bin/env bash
# mentis-actualizar.sh -- traer las mejoras publicadas. Corre en las copias instaladas con git.
#
# QUE CAMBIO (2026-08-08): antes esto bajaba paquetes firmados de un repositorio aparte y
# verificaba una firma Ed25519 antes de instalar. Ahora Mentis vive en un repositorio publico y
# se instala con `git clone`, asi que actualizar es `git pull`. El sistema de firma no se tira --
# sigue teniendo sentido si algun dia se distribuye fuera de GitHub -- pero para cinco personas y
# un repositorio publico, la complejidad no se paga: el riesgo real no era que alguien modificara
# un paquete en el camino, era que la actualizacion nunca llegara porque el proceso tenia
# demasiados pasos.
#
# LO QUE SE MANTIENE, porque no era complejidad al pedo:
#   1. Se pregunta ANTES. Nunca se actualiza solo.
#   2. Se respalda antes de tocar nada, y `volver` deshace.
#   3. Si modificaste un archivo de Mentis, se FRENA y se avisa. No se pisa el trabajo de nadie.
#   4. Los datos NO se tocan nunca: conversaciones, memorias, claves y configuracion se quedan
#      donde estan. Estan en.gitignore, asi que git ni los mira.
#
# Uso:
#   mentis-actualizar.sh buscar     ve si hay algo nuevo y que cambio, sin instalar
#   mentis-actualizar.sh instalar   actualiza (pregunta antes)
#   mentis-actualizar.sh volver     deshace la ultima actualizacion

set -uo pipefail
MA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MA_RESPALDOS="${MENTIS_RESPALDOS_DIR:-$MA_HERE/.respaldos-actualizacion}"

_ma_es_clon() { [ -d "$MA_HERE/.git" ]; }

# Una instalacion que no vino de `git clone` no se puede actualizar asi, y hay que decirlo claro
# en vez de fallar con un error de git. Es tambien el caso de la maquina donde se DESARROLLA
# Mentis: esa no se actualiza desde el repositorio publico, porque es la que publica.
if ! _ma_es_clon; then
  cat <<'FIN'
Esta instalación de Mentis no vino de `git clone`, así que no se actualiza por acá.

Puede ser por dos motivos:

  1. La instalaste copiando la carpeta desde otra computadora.
     Para pasarte al sistema de actualizaciones, volvé a instalarla con:
         git clone https://github.com/usuario/Mentis.git
     y copiá tus datos (conversations/, memoria/, y los archivos de claves) a la carpeta nueva.

  2. Es la máquina donde se desarrolla Mentis.
     Esa no se actualiza desde el repositorio: es la que publica.
FIN
  exit 1
fi

cd "$MA_HERE" || exit 1

# --- buscar -----------------------------------------------------------------------------------
_ma_buscar() {
  echo "== Buscando novedades =="
  if ! timeout 60 git fetch --quiet origin 2>/dev/null; then
    echo "No pude consultar el repositorio. ¿Hay internet?"
    return 1
  fi
  local atras
  atras="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "${atras:-0}" -eq 0 ]; then
    echo "Ya tenés la última versión."
    return 0
  fi
  echo "Hay $atras cambio(s) nuevo(s):"
  echo
  git log --format='  - %s' HEAD..origin/main 2>/dev/null | head -20
  echo
  echo "Para instalarlos:  bash mentis-actualizar.sh instalar"
  return 0
}

# --- instalar ---------------------------------------------------------------------------------
_ma_instalar() {
  timeout 60 git fetch --quiet origin 2>/dev/null || { echo "No pude consultar el repositorio."; return 1; }

  local atras; atras="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "${atras:-0}" -eq 0 ]; then echo "Ya tenés la última versión."; return 0; fi

  # FRENO: si tocaste archivos de Mentis, se para acá. `git pull` los pisaría o daría un conflicto
  # a mitad de camino, y ninguna de las dos es forma de tratar el trabajo de otro.
  # Los datos (conversaciones, claves, configuración) no cuentan: están en.gitignore.
  local sucios; sucios="$(git status --porcelain 2>/dev/null | grep -v '^??' | head -5)"
  if [ -n "$sucios" ]; then
    echo "PARO: modificaste archivos de Mentis y la actualización los pisaría."
    echo
    printf '%s\n' "$sucios" | sed 's/^/  /'
    echo
    echo "Si los cambios te importan, guardalos antes (copialos a otro lado)."
    echo "Si no te importan y querés la versión nueva igual:"
    echo "    git checkout --.   &&   bash mentis-actualizar.sh instalar"
    return 1
  fi

  echo "== Se van a instalar $atras cambio(s) =="
  echo
  git log --format='  - %s' HEAD..origin/main 2>/dev/null | head -20
  echo
  printf "¿Actualizamos? (s/N): "
  read -r _resp
  case "${_resp:-}" in
    s|S|si|SI|Si|sí|Sí) ;;
    *) echo "No se instaló nada."; return 0 ;;
  esac

  # RESPALDO antes de tocar nada. Se guarda el punto exacto del historial, que es todo lo que hace
  # falta para volver: los archivos se reconstruyen desde ahí.
  mkdir -p "$MA_RESPALDOS" 2>/dev/null
  local sello; sello="$(date +%Y%m%d-%H%M%S)"
  git rev-parse HEAD > "$MA_RESPALDOS/$sello.punto" 2>/dev/null
  echo "  respaldo: $sello (para deshacer: bash mentis-actualizar.sh volver)"

  if timeout 180 git pull --ff-only origin main 2>&1 | tail -3; then
    echo
    echo "Listo. Versión: $(cat VERSION 2>/dev/null | tr -d '\r')"
    # Si cambió algo de la ventana, hay que rearmarla: el.exe no se actualiza solo.
    if git diff --name-only "$(cat "$MA_RESPALDOS/$sello.punto")" HEAD 2>/dev/null | grep -q '^app/'; then
      echo
      echo "OJO: cambió la ventana de Mentis. Cerrala y corré:"
      echo "    cd app && npm run empaquetar"
    fi
  else
    echo "La actualización falló. No se cambió nada. Para volver: bash mentis-actualizar.sh volver"
    return 1
  fi
}

# --- volver -----------------------------------------------------------------------------------
_ma_volver() {
  local ultimo; ultimo="$(ls -1 "$MA_RESPALDOS"/*.punto 2>/dev/null | sort | tail -1)"
  if [ -z "$ultimo" ]; then echo "No hay ninguna actualización para deshacer."; return 1; fi
  local punto; punto="$(cat "$ultimo" 2>/dev/null | tr -d '\r')"
  if [ -z "$punto" ]; then echo "El respaldo está vacío."; return 1; fi

  echo "Vas a volver al punto anterior a la última actualización:"
  git log --format='  %h  %s' -1 "$punto" 2>/dev/null
  printf "¿Seguimos? (s/N): "
  read -r _resp
  case "${_resp:-}" in
    s|S|si|SI|Si|sí|Sí) ;;
    *) echo "No se tocó nada."; return 0 ;;
  esac

  if git reset --hard "$punto" 2>&1 | tail -1; then
    echo "Listo, volviste a la versión anterior."
    rm -f "$ultimo" 2>/dev/null
  else
    echo "No se pudo volver."
    return 1
  fi
}

case "${1:-}" in
  buscar)   _ma_buscar ;;
  instalar) _ma_instalar ;;
  volver)   _ma_volver ;;
  *) sed -n '18,21p' "$0" ;;
esac
