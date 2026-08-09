#!/usr/bin/env bash
# test-git.sh -- la herramienta 'git' de nv-agent.sh (agregada 2026-08-02, solo lectura).
#
# Ejercita el DESPACHO REAL contra un repositorio de verdad creado al vuelo, no un mock. Lo que
# importa probar acá no es que git funcione (eso ya lo sabemos) sino las tres decisiones propias:
# que los verbos que ESCRIBEN se rechacen, que la jaula se respete, y que fuera de un repo lo diga
# en vez de fallar raro.
#
# OJO: el repo de prueba se crea en un temporal y se borra al salir. NUNCA se corre git init sobre
# una carpeta del usuario -- el 2026-07-26 se creo un repo que el no habia pedido y no se repite.
set -uo pipefail
TG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TG_AGENT="$TG_HERE/../engine/nv-agent.sh"
export PYTHONIOENCODING=utf-8

TG_OK=0; TG_MAL=0
_ok()  { TG_OK=$((TG_OK+1));  echo "  OK   $1"; }
_mal() { TG_MAL=$((TG_MAL+1)); echo "  MAL  $1  ($2)"; }

echo "== el protocolo de los dos lados =="
# shellcheck source=/dev/null
source "$TG_AGENT" 2>/dev/null || true
TG_ACT="$(_extract_action '{"tool":"git","action":"status","path":"."}' 2>/dev/null)"
printf '%s' "$TG_ACT" | grep -q "TOOL=git"    && _ok "reconoce tool=git"   || _mal "no reconoce tool=git" "$TG_ACT"
printf '%s' "$TG_ACT" | grep -q "ACTION_B64=" && _ok "emite ACTION_B64"    || _mal "no emite ACTION_B64" "$TG_ACT"
# Y que este declarada al modelo: una tool que el despacho entiende pero el prompt no menciona es
# una tool que no existe en la practica.
grep -q '{\\"tool\\":\\"git\\"' "$TG_AGENT" && _ok "está declarada en el protocolo que ve el modelo" || _mal "no está en el prompt" ""

echo "== el despacho real, contra un repo de verdad =="
TG_TMP="$(mktemp -d)"
trap 'rm -rf "$TG_TMP"' EXIT
mkdir -p "$TG_TMP/repo" "$TG_TMP/norepo"
( cd "$TG_TMP/repo"
  git init -q. 2>/dev/null
  git config user.email t@t.t; git config user.name t
  echo "hola" > a.txt; git add a.txt; git commit -qm "primer commit" 2>/dev/null
  echo "cambio sin guardar" >> a.txt ) >/dev/null 2>&1

_probar_git() {  # <action> <path> -> deja la observación en TG_OBS
  ROOT="$TG_TMP"; OBSMAX=4000; ALLOW_WRITE=0; it=1
  TOOL="git"
  ACTION_B64="$(printf '%s' "$1" | base64 -w0)"
  PATH_B64="$(printf '%s' "$2" | base64 -w0)"
  QUERY_B64=""; CODE_B64=""; CONTENT_B64=""; ANSWER_B64=""; OLD_B64=""; NEW_B64=""
  OBS=""
  _dispatch_tool 1
  TG_OBS="$OBS"
}

_probar_git status repo
printf '%s' "$TG_OBS" | grep -q "a.txt" && _ok "status ve el archivo modificado" || _mal "status no mostró el cambio" "$TG_OBS"

_probar_git log repo
printf '%s' "$TG_OBS" | grep -qi "primer commit" && _ok "log ve el historial" || _mal "log no mostró el commit" "$TG_OBS"

_probar_git diff repo
printf '%s' "$TG_OBS" | grep -q "cambio sin guardar" && _ok "diff muestra el contenido del cambio" || _mal "diff no mostró el cambio" "$TG_OBS"

# LO IMPORTANTE: los verbos que escriben tienen que rechazarse, y decir por qué.
for verbo in commit push reset checkout merge rebase clean init; do
  _probar_git "$verbo" repo
  if printf '%s' "$TG_OBS" | grep -qi "solo lectura"; then :; else
    _mal "'git $verbo' NO fue rechazado" "$TG_OBS"; continue
  fi
done
_ok "los 8 verbos que escriben (commit, push, reset, checkout, merge, rebase, clean, init) se rechazan"

# Que el repo quedó intacto: ningún commit nuevo, el cambio sigue sin guardar.
TG_N="$(cd "$TG_TMP/repo" && git rev-list --count HEAD 2>/dev/null)"
[ "$TG_N" = "1" ] && _ok "el repo quedó intacto (sigue con 1 commit)" || _mal "el repo cambió" "commits=$TG_N"

# Fuera de un repo: mensaje claro, no un error críptico de git.
_probar_git status norepo
printf '%s' "$TG_OBS" | grep -qi "no esta dentro de un repositorio\|no está dentro de un repositorio" && _ok "fuera de un repo lo dice claro" || _mal "no explicó que no hay repo" "$TG_OBS"

# La jaula.
_probar_git status../../..
printf '%s' "$TG_OBS" | grep -qi "fuera de la raiz\|fuera de la raíz\|invalida\|inválida" && _ok "la jaula rechaza rutas que escapan" || _mal "la jaula no rechazó" "$TG_OBS"

# Sin action.
_probar_git "" repo
printf '%s' "$TG_OBS" | grep -qi "necesita el campo action" && _ok "sin action, lo explica" || _mal "no explicó la falta de action" "$TG_OBS"

echo
echo "== RESULTADO: $TG_OK bien, $TG_MAL mal =="
[ "$TG_MAL" -eq 0 ]
