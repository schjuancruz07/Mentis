#!/usr/bin/env bash
# test-config-cableada.sh -- ningun campo de configuracion declarado y sin cablear.
#
# POR QUE EXISTE (2026-08-20). Una auditoria de los.json encontro CINCO campos que estaban
# declarados, comentados, versionados... y que nadie leia:
#   - modos.json: 'acento' (en los 7 modos), 'motor_externo' (en 3, uno con valor "openwork"),
#     'recordar_ultimo' (ponerlo en false no apagaba nada);
#   - mentis-settings.json: 'theme', que ademas el instalador seguia escribiendo con un valor
#     inexistente;
#   - y 'letra', que si viaja hasta el renderer pero no pinta nada, y por eso se habia separado de
#     la pantalla sin que nadie lo notara.
# Antes ya habia pasado lo mismo con tres campos de departamentos.json ('herramientas', 'fuente',
# 'salida'), que estaban declarados y sin efecto.
#
# LO QUE NINGUN TEST VIEJO VIO, Y POR QUE: los tests de configuracion validaban el ARCHIVO -- que
# el JSON parsee, que la clave exista, que el tipo sea el correcto. Los cinco campos muertos
# pasaban todas esas pruebas. Un campo de configuracion no se verifica leyendolo: se verifica
# comprobando que ALGUIEN LO LEA.
#
# COMO FUNCIONA: por cada clave de cada.json declarado abajo, busca lectores en el codigo. No
# alcanza con que el nombre aparezca en cualquier lado (aparece en el propio.json, en los
# comentarios, en los docs): se buscan las formas en que un lector de VERDAD la nombra --
# d.campo, m["campo"],.get("campo"), $campo en un node -e, etc.
#
# CUANDO ESTE TEST FALLA hay dos salidas honestas: cablear el campo, o borrarlo. Dejarlo
# declarado y sin leer no es una de las dos -- quien abre el archivo cree que ahi se configura
# algo, y los tests lo dan por bueno.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

# Los archivos que son CONFIGURACION DEL PROGRAMA (no datos, no estado de un proceso).
#
# skills-autonomas.json NO esta en esta lista y tiene su propio chequeo mas abajo: sus claves no
# son campos sino NOMBRES DE SKILLS ("recall": "libre"). Buscar un lector de la palabra "recall"
# en el codigo no dice nada -- el lector es generico (d.get(nombre)). Lo que ahi hay que
# comprobar es otra cosa: que cada nombre corresponda a una skill que existe.
ARCHIVOS=( "modos.json" "departamentos.json" "disparadores.json"
           "study-sugerencias.json" "hooks.json" )

# Claves que se saltean, con el motivo. Toda excepcion tiene que tener uno escrito.
#   _*            -> comentarios del propio archivo (esa es la convencion del proyecto)
#   version       -> numero de formato, se lee al migrar y no siempre hay migracion viva
#   nombre|titulo|descripcion -> texto que se muestra; si falta, se nota a simple vista
_saltear() {
  case "$1" in
    _*|version|nombre|titulo|descripcion) return 0 ;;
    *) return 1 ;;
  esac
}

# ¿Alguien lee esta clave? Se busca el nombre como PALABRA SUELTA en el codigo, descartando las
# lineas que son comentario.
#
# La primera version buscaba las formas exactas de leer un campo (d.campo, m["campo"],
#.get("campo")) y daba falsos positivos en cuatro claves que si se leen: 'verificar_cobertura'
# viaja como ARGUMENTO a una funcion de bash (_md_campo_json "$depto" verificar_cobertura lista),
# no como.verificar_cobertura. Un detector que no entiende como se lee la configuracion en bash
# no sirve para un proyecto que es mayormente bash -- y una alarma con falsos positivos es una
# alarma que nadie mira, que es exactamente el problema que este test viene a resolver.
#
# Buscar la palabra suelta es mas permisivo, y esta bien que lo sea: el riesgo de un falso
# NEGATIVO (dar por vivo un campo muerto) es que se escape un campo decorativo; el de un falso
# positivo es que el test moleste hasta que alguien lo apague. Se descartan los comentarios
# porque los cinco campos muertos que motivaron esto estaban largamente comentados.
_tiene_lector() {
  local k="$1"
  # "(^|[^-a-zA-Z0-9_])" en vez de "\b": \b da por vivo a `--acento`, que es la VARIABLE CSS del
  # color de acento -- otra cosa que casualmente se llama igual que el campo muerto de modos.json.
  # Sin esto, el test se acusaba a si mismo de no servir.
  grep -rhE "(^|[^-a-zA-Z0-9_])${k}\b" \
    --include="*.sh" --include="*.py" --include="*.js" --include="*.html" \
    "$HERE/engine" "$HERE/app" "$HERE/capabilities" "$HERE"/*.sh "$HERE"/*.py \
    --exclude-dir=test --exclude-dir=tests --exclude-dir=node_modules \
    2>/dev/null \
    | grep -vE "^[[:space:]]*(#|//|\*|/\*)" \
    | sed -E 's/[[:space:]]+#.*$//; s@[[:space:]]+//[^/].*$@@' \
    | grep -qE "(^|[^-a-zA-Z0-9_])${k}\b"
}

# Las claves de un archivo: las de primer nivel y las de los objetos que cuelgan de una coleccion
# (los modos, los departamentos), que es donde vivieron todos los campos muertos encontrados.
_claves() {
  MD_F="$1" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["MD_F"], encoding="utf-8"))
except Exception:
    sys.exit(0)
vistas = set()
def sumar(o):
    if isinstance(o, dict):
        for k in o: vistas.add(k)
    elif isinstance(o, list):
        for x in o[:3]: sumar(x)
if isinstance(d, dict):
    for k, v in d.items():
        vistas.add(k)
        # Una coleccion de objetos parecidos (modos, departamentos, reglas): interesan sus campos.
        if isinstance(v, dict) and v and all(isinstance(x, dict) for x in v.values()):
            for sub in v.values(): sumar(sub)
        elif isinstance(v, list):
            sumar(v)
elif isinstance(d, list):
    sumar(d)
for k in sorted(vistas): print(k)
'
}

for arch in "${ARCHIVOS[@]}"; do
  ruta="$HERE/$arch"
  [ -f "$ruta" ] || { echo "  (no existe $arch, se saltea)"; continue; }
  echo "== $arch =="
  muertas=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    _saltear "$k" && continue
    _tiene_lector "$k" || muertas="${muertas:+$muertas }$k"
  # tr -d '\r': el python de Windows escribe \r\n aunque se le pida \n, asi que cada clave llegaba
  # como "herramientas\r" y el grep no encontraba a nadie leyendo "herramientas\r". Daba TODAS las
  # claves por muertas -- justo cuando la guarda de mas abajo decia que esa misma clave si tenia
  # lector. Es la misma familia de error que se encontro hoy en mentis-hooks.sh, donde ese \r se
  # estaba inyectando en el prompt del modelo.
  done < <(_claves "$(cygpath -w "$ruta" 2>/dev/null || printf '%s' "$ruta")" | tr -d '\r')
  if [ -z "$muertas" ]; then
    _ok "todas sus claves tienen quien las lea"
  else
    _mal "$arch declara campos que nadie lee: $muertas" \
         "o se cablean o se borran; declarado y sin efecto es peor que no tenerlo (quien lo lee cree que configura algo)"
  fi
done

echo ""
echo "== skills-autonomas.json: cada permiso apunta a una skill que existe =="
# El equivalente de "campo cableado" para este archivo. Un permiso sobre una skill que no existe
# es la misma clase de mentira: esta escrito, parece que gobierna algo, y no gobierna nada. Y el
# caso inverso importa mas todavia -- una skill sin entrada en el registro NO es autonoma (el
# motor la trata como "no"), asi que conviene verlo declarado.
_huerfanas=""
while IFS= read -r sk; do
  [ -n "$sk" ] || continue
  case "$sk" in _*) continue ;; esac
  [ -f "$HERE/capabilities/$sk.sh" ] || _huerfanas="${_huerfanas:+$_huerfanas }$sk"
done < <(MD_F="$(cygpath -w "$HERE/skills-autonomas.json" 2>/dev/null || printf '%s' "$HERE/skills-autonomas.json")" python3 -c '
import json, os
d = json.load(open(os.environ["MD_F"], encoding="utf-8"))
for k, v in d.items():
    if not k.startswith("_") and isinstance(v, str): print(k)
' 2>/dev/null | tr -d '\r')
if [ -z "$_huerfanas" ]; then
  _ok "todos los permisos apuntan a una skill que existe"
else
  _mal "permisos sobre skills inexistentes: $_huerfanas" "el permiso no gobierna nada; o se crea la skill o se saca la linea"
fi

echo ""
echo "== la guarda de la guarda =="
# Si el buscador de lectores estuviera roto (una comilla de mas en el grep, por ejemplo), diria
# "todo bien" sobre cualquier cosa y este test seria decorativo, como los campos que persigue.
# Se comprueba con los dos casos: una clave que SI se lee y una inventada que no puede existir.
if _tiene_lector "herramientas"; then
  _ok "encuentra el lector de una clave que si se usa ('herramientas')"
else
  _mal "el buscador de lectores no encuentra 'herramientas'" "esta roto: todo lo de arriba es humo"
fi
if _tiene_lector "campo_inventado_que_no_existe_zzz"; then
  _mal "el buscador encuentra lectores de una clave inventada" "matchea cualquier cosa: todo lo de arriba es humo"
else
  _ok "no inventa lectores para una clave que no existe"
fi

# Y la prueba de fuego: los campos que SE SABE que estaban muertos. Se borraron el 2026-08-20,
# pero el detector tiene que seguir diciendo que nadie los lee -- si dijera que si, no habria
# detectado nada aquel dia y no detectaria el proximo.
for muerto in acento motor_externo recordar_ultimo; do
  if _tiene_lector "$muerto"; then
    _mal "el buscador cree que '$muerto' tiene lector" "es uno de los campos que se comprobo muerto: el detector no sirve"
  else
    _ok "sigue viendo que nadie lee '$muerto' (el caso que motivo este test)"
  fi
done

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
