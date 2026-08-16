#!/usr/bin/env bash
# nv-textos-lib.sh -- carga los textos que LEE EL MODELO desde archivos, en vez de tenerlos
# adentro de strings de bash.
#
# POR QUE EXISTE (2026-08-15). El protocolo -- las ~250 lineas que le explican al modelo que
# herramientas tiene y como usarlas -- vivia dentro de asignaciones de bash con comillas dobles.
# Eso obliga a escapar CADA comilla del JSON de ejemplo: {\"tool\":\"read\"...}. Dos consecuencias
# medidas, no teoricas:
#
#   1. ERR-159: al editar esos textos con una herramienta que genera codigo, los backslashes se
#      colapsan. Cuatro parches salieron rotos y UNO paso en silencio -- el motor arrancaba igual
#      y el modelo leia un protocolo con las comillas mal. Un texto roto no tira ningun error:
#      simplemente el modelo entiende otra cosa.
#   2. No se pueden leer. Nadie revisa de verdad un parrafo escrito como
#      {\"tool\":\"gen\",\"action\":\"image\"}; se revisa un parrafo escrito como
#      {"tool":"gen","action":"image"}.
#
# COMO SE EVITA LA MISMA TRAMPA ACA: los archivos.txt se leen TAL CUAL, sin que bash los
# interprete nunca. No hay expansion de $VARIABLES, ni de `comandos`, ni de comillas. Lo que esta
# escrito en el archivo es exactamente lo que ve el modelo. Cuando un texto necesita un dato
# calculado (la carpeta de creaciones, el indice de capacidades), se marca con {{NOMBRE}} y se lo
# pasa explicitamente -- un placeholder que bash no puede confundir con nada suyo.
#
# LA REGLA: si un texto lo lee el MODELO, va a un archivo. Si es logica (cuando se agrega, en que
# orden, bajo que bandera), se queda en bash. Los archivos no tienen condicionales a proposito.

NVTEXTOS_DIR="${MENTIS_TEXTOS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/textos}"

# nv_texto <ruta relativa sin.txt> [CLAVE=valor...] -> imprime el texto, con los {{CLAVE}}
# reemplazados. Sin newline final: quien llama decide como pegarlo.
#
# Si el archivo no existe devuelve vacio y codigo 1, y avisa por stderr. Nunca corta el turno: un
# protocolo con una ficha de menos es peor que uno completo, pero es MUCHO mejor que un Mentis
# que no arranca.
nv_texto() {
  local nombre="${1:-}"; shift 2>/dev/null || true
  local archivo="$NVTEXTOS_DIR/$nombre.txt"
  if [ ! -f "$archivo" ]; then
    echo "[nv-textos] falta el texto: $archivo" >&2
    return 1
  fi
  # El reemplazo lo hace python y no sed: los textos tienen barras, comillas y & -- todos
  # caracteres que sed interpreta y que convertirian una sustitucion en una corrupcion silenciosa,
  # que es exactamente la familia de errores de la que este archivo viene escapando.
  if [ "$#" -eq 0 ]; then
    NVT_ARCHIVO="$archivo" python3 -c "
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8', newline='')
with io.open(os.environ['NVT_ARCHIVO'], encoding='utf-8') as f: t = f.read()
sys.stdout.write(t.rstrip('\n'))
"
    return 0
  fi
  # Los pares van separados por \x01 y NO por salto de linea. Esto no es cosmetico: el primer
  # valor que se paso aca fue el indice de capacidades, que es MULTILINEA y empieza con un salto.
  # Partiendo por "\n" se colaba entera la primera linea (vacia) como si fuera el valor y las ocho
  # capacidades desaparecian del protocolo -- el modelo dejaba de saber que existian. Lo agarro el
  # golden byte a byte; a ojo era invisible.
  local pares=""
  local kv
  for kv in "$@"; do pares="$pares$kv"$'\001'; done
  NVT_ARCHIVO="$archivo" NVT_PARES="$pares" python3 -c "
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8', newline='')
with io.open(os.environ['NVT_ARCHIVO'], encoding='utf-8') as f: t = f.read()
for par in os.environ.get('NVT_PARES','').split(chr(1)):
    if '=' not in par: continue
    k, v = par.split('=', 1)
    t = t.replace('{{' + k.strip() + '}}', v)
sys.stdout.write(t.rstrip('\n'))
"
}

# nv_textos_faltantes <nombre> [<nombre>...] -> lista los que no existen. Lo usa el test para
# comprobar que ningun bloque quedo referenciado sin archivo.
nv_textos_faltantes() {
  local n faltan=""
  for n in "$@"; do
    [ -f "$NVTEXTOS_DIR/$n.txt" ] || faltan="$faltan $n"
  done
  printf '%s' "${faltan# }"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    "") echo "uso: nv-textos-lib.sh <nombre> [CLAVE=valor...]" >&2; exit 64 ;;
    *)  nv_texto "$@"; echo ;;
  esac
fi
