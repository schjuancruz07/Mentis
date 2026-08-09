#!/usr/bin/env bash
# test-buscador.sh -- que Mentis no se rinda cuando un buscador lo rechaza (2026-07-31).
#
# EL PROBLEMA (reportado por el usuario): "Mentis directamente se rindió con entrar a buscar algo a la
# web porque lo rechazan". Reproducido antes de tocar nada:
#     iter 1: browse search (CAPTCHA detectado)
#     iter 2: browse search (CAPTCHA detectado)
#     terminé sin respuesta final (status=budget)
# Habia UN solo buscador cableado -- Bing -- y Bing challenguea a todo navegador automatizado.
#
# LO QUE NO SE HACE, Y NO ES UN OLVIDO: resolver o esquivar el CAPTCHA. Es una barrera que el
# sitio puso a proposito. La salida es usar buscadores que SI aceptan clientes automaticos.
#
# Los textos de rechazo de este test son REALES, capturados el 2026-07-31 desde la red del usuario.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FALLO=0
_ok()  { echo "ok: $1"; PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1"; FALLO=$((FALLO+1)); }

# Se extraen las funciones REALES del motor, no una copia (si se desincronizan, el test miente).
TMPF="$(mktemp -d)"; trap 'rm -rf "$TMPF"' EXIT
sed -n '/^_es_rechazo() {/,/^}/p'      "$DIR/engine/nv-agent.sh" >  "$TMPF/fx.sh"
sed -n '/^_urls_de_busqueda() {/,/^}/p' "$DIR/engine/nv-agent.sh" >> "$TMPF/fx.sh"
if [ -s "$TMPF/fx.sh" ]; then _ok "se pudieron extraer las funciones del motor"; else
  _bad "no estan _es_rechazo/_urls_de_busqueda en nv-agent.sh"; echo; echo "RESULTADO: $PASS ok, $FALLO fallos."; exit 1
fi
# shellcheck source=/dev/null
source "$TMPF/fx.sh"

echo "== 1. reconoce los rechazos REALES que devolvieron los buscadores hoy =="
BING='Para continuar, resuelve el desafío de abajo'
DDG='Unfortunately, bots use DuckDuckGo too. Please complete the following challenge to confirm this search was made by a human. Select all squares containing a duck:'
MOJEEK='403 - Forbidden Sorry your network appears to be sending automated queries so we can not process your search at this time.'
GOOGLE='Our systems have detected unusual traffic from your computer network.'
for par in "Bing|$BING" "DuckDuckGo|$DDG" "Mojeek|$MOJEEK" "Google|$GOOGLE"; do
  nombre="${par%%|*}"; texto="${par#*|}"
  if _es_rechazo "$texto"; then _ok "detecta el rechazo de $nombre"; else _bad "NO detecta el rechazo de $nombre: seguiria tratandolo como resultado"; fi
done

echo "== 2. NO confunde un resultado bueno con un rechazo =="
REAL='Copa Mundial de Fútbol de 2022 - La selección de Argentina se consagró campeona tras vencer a Francia en la final disputada en Lusail.'
MARGINALIA='Skip To Content Search Sites Explore About Marginalia Search Filter All Blogs Academia Results'
for par in "un resultado de verdad|$REAL" "la pagina de Marginalia|$MARGINALIA"; do
  nombre="${par%%|*}"; texto="${par#*|}"
  if _es_rechazo "$texto"; then _bad "marco como rechazo $nombre: descartaria resultados buenos"; else _ok "no confunde $nombre con un rechazo"; fi
done

echo "== 3. hay MAS DE UN buscador, y el que funciona va primero =="
URLS="$(_urls_de_busqueda 'prueba de busqueda')"
CUANTOS="$(printf '%s\n' "$URLS" | grep -c 'http')"
[ "$CUANTOS" -ge 3 ] && _ok "la cadena tiene $CUANTOS buscadores (antes habia 1)" || _bad "la cadena quedo con $CUANTOS: un solo buscador es el mismo bug con otro nombre"
PRIMERO="$(printf '%s\n' "$URLS" | head -1)"
case "$PRIMERO" in
  *marginalia*) _ok "arranca por el que hoy contesta de verdad (Marginalia)" ;;
  *) _bad "el primero de la cadena es '$PRIMERO', y hoy el unico que contesta es Marginalia" ;;
esac
case "$URLS" in
  *bing.com*) _bad "Bing sigue en la cadena: es el que challenguea siempre" ;;
  *) _ok "Bing ya no esta" ;;
esac
case "$URLS" in
  *wikipedia*) _ok "Wikipedia esta como respaldo de conocimiento" ;;
  *) _bad "falta Wikipedia, que es el otro que contesta" ;;
esac

echo "== 4. la consulta viaja codificada (acentos y espacios) =="
URLS2="$(_urls_de_busqueda 'cuánto sale el dólar hoy')"
case "$URLS2" in
  *" "*) _bad "hay espacios sin codificar en la URL" ;;
  *) _ok "sin espacios crudos" ;;
esac
case "$URLS2" in
  *%C3%A1*|*%c3%a1*) _ok "los acentos van codificados" ;;
  *) _bad "los acentos no se codificaron: $(printf '%s' "$URLS2" | head -1)" ;;
esac

echo "== 5. el motor NO intenta resolver el desafio (limite deliberado) =="
# Se buscan SERVICIOS de resolucion de captchas, no la palabra: la primera version de este test
# marcaba como sospechoso al propio DETECTOR de captchas del motor (que obviamente nombra el tema).
if grep -qiE "2captcha|anti-?captcha|deathbycaptcha|capmonster|captcha.?solver|solveRecaptcha" "$DIR/engine/nv-agent.sh"; then
  _bad "aparecio algo que huele a saltear un CAPTCHA: eso no va"
else
  _ok "no hay nada que intente saltear un CAPTCHA"
fi

echo
echo "RESULTADO: $PASS ok, $FALLO fallos."
[ "$FALLO" -eq 0 ] || exit 1
