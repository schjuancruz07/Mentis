#!/usr/bin/env bash
# Los departamentos de Cowork: eleccion deterministica, permisos y libro mayor que VERIFICA.
#
# POR QUE EXISTE: en la primera prueba real, Cobranzas contesto "se redactaron los borradores y
# quedaron en recordatorios.txt". El archivo tenia TRES BYTES. En la segunda dijo dejarlos en
# "recordatorios/drafts.json", que no existia (esa vez si los hizo, en otro archivo). O sea que el
# departamento es INCONSISTENTE, y un libro mayor que copia lo que el modelo dice no sirve para
# auditar nada -- que es justo lo que hay que poder vender si esto va a manejar plata.
TD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok    $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA $1  ($2)"; }
TD_TMP="$(mktemp -d)"; trap 'rm -rf "$TD_TMP"' EXIT
# Python no entiende las rutas /c/... que da MSYS: se le pasan relativas desde la raiz.
cd "$TD_HERE" || exit 1

echo "-- la estructura"
python3 -c "
import json, io, sys
d = json.load(io.open('departamentos.json', encoding='utf-8'))
ds = d['departamentos']
faltan = []
for k, v in ds.items():
    for campo in ('titulo','objetivo','medida','rol','herramientas','irreversibles','tope_por_turno','memoria','disparadores','persona','salida'):
        if not v.get(campo): faltan.append(k + '.' + campo)
sys.exit(1 if faltan else 0)
" 2>/dev/null && _ok "todo departamento declara jefe, objetivo, medida, tope, memoria e irreversibles" \
  || _mal "a un departamento le falta algo" "sin las seis piezas es un prompt con otro nombre"

echo "-- la eleccion es deterministica (no la decide un modelo)"
[ "$(bash "$TD_HERE/mentis-departamento.sh" cual 'me deben la factura 104')" = "cobranzas" ] \
  && _ok "un pedido de cobranza cae en Cobranzas" || _mal "no eligio Cobranzas" "el disparador no matchea"
bash "$TD_HERE/mentis-departamento.sh" cual 'diseñame un logo lindo' >/dev/null 2>&1 \
  && _mal "un pedido de diseño cayo en un departamento" "activaria el equipo por cualquier cosa" \
  || _ok "un pedido que no es de ningun departamento no activa ninguno"
A="$(bash "$TD_HERE/mentis-departamento.sh" cual 'cobrar factura vencida')"
B="$(bash "$TD_HERE/mentis-departamento.sh" cual 'cobrar factura vencida')"
[ "$A" = "$B" ] && _ok "el mismo pedido elige SIEMPRE el mismo departamento" \
                || _mal "la eleccion cambia entre corridas" "$A vs $B"

echo "-- lo irreversible esta declarado y prohibido"
python3 -c "
import json, io, sys
v = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']['cobranzas']
irr = ' '.join(v['irreversibles']).lower()
sys.exit(0 if ('enviar' in irr and 'mandar mail' in irr) else 1)
" && _ok "enviar y mandar mail figuran como irreversibles" || _mal "no estan declarados" "mandaria sin permiso"
# NO alcanza con mirar el JSON: eso es lo DECLARADO. Lo que importa es lo que se le pasa al motor.
# La version anterior de esta asercion daba verde mientras el departamento corria con TODAS las
# herramientas encendidas, porque nadie aplicaba la lista (arreglado 2026-08-19).
grep -q 'nv-agent.sh -w -n "$md_apagar"' "$TD_HERE/mentis-departamento.sh" && _ok "la lista de herramientas se APLICA al motor con -n" || _mal "la lista es decorativa" "el departamento correria con todo encendido"
_apagadas() {
  TD_PERM="$(python3 -c "
import json, io
print(' '.join(json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']['$1']['herramientas']))")"
  TODAS="read search write edit exec run git lsp mcp gen datos delegate parallel subagent task browse screen control webcam telefono arduino drive vscode video skill recordar presencia"
  OUT=""
  for t in $TODAS; do
    case " $TD_PERM " in *" $t "*) : ;; *) OUT="${OUT:+$OUT,}$t" ;; esac
  done
  printf %s "$OUT"
}
AP="$(_apagadas cobranzas)"
case ",$AP," in *,exec,*) _ok "el complemento apaga exec para Cobranzas" ;; *) _mal "exec queda encendido" "podria ejecutar comandos" ;; esac
case ",$AP," in *,telefono,*) _ok "el complemento apaga telefono (no puede contactar al cliente)" ;; *) _mal "telefono encendido" "contactaria sin permiso" ;; esac
case ",$AP," in *,read,*) _mal "apago read, que SI necesita" "no podria leer la cartera" ;; *) _ok "no apaga las que si necesita (read sigue)" ;; esac

echo "-- el libro mayor VERIFICA en vez de copiar"
mkdir -p "$TD_TMP/empresa"
printf '%s' "$(head -c 40 /dev/zero | tr '\0' 'x')" > "$TD_TMP/empresa/vacio.md"
head -c 900 /dev/zero | tr '\0' 'y' > "$TD_TMP/empresa/lleno.md"
_guarda() { MD_S="$1" MD_DIR="$(cygpath -w "$TD_TMP/empresa" 2>/dev/null || echo "$TD_TMP/empresa")" python3 -c '
import os, re
s = os.environ["MD_S"]; d = os.environ["MD_DIR"]
malos = []
for n in sorted(set(re.findall(r"[A-Za-z0-9_./-]+[.](?:txt|md|csv|json|html)", s))):
    f = os.path.join(d, n)
    if os.path.isfile(f):
        if os.path.getsize(f) < 200: malos.append(n)
    elif not n.endswith("cobranzas.json"): malos.append(n)
print("; ".join(malos))'; }
[ -z "$(_guarda 'deje todo en lleno.md')" ] \
  && _ok "no marca nada cuando el trabajo esta hecho de verdad" \
  || _mal "falso positivo sobre trabajo real" "se volveria ruido y nadie lo miraria"
case "$(_guarda 'deje los borradores en vacio.md')" in *vacio.md*) _ok "detecta el archivo que quedo casi vacio (el caso real)" ;;
  *) _mal "no detecta un entregable vacio" "el usuario cerraria el turno creyendo que esta hecho" ;; esac
case "$(_guarda 'quedo en inventado.md')" in *inventado.md*) _ok "detecta un archivo que ni existe" ;;
  *) _mal "no detecta un archivo inexistente" "" ;; esac

echo "-- el libro mayor deja rastro"
grep -q "_md_anotar" "$TD_HERE/mentis-departamento.sh" \
  && _ok "cada corrida se anota en el libro mayor" || _mal "no anota" "sin libro no es auditable"
grep -q "sin-evidencia" "$TD_HERE/mentis-departamento.sh" \
  && _ok "las corridas sin evidencia se anotan COMO TALES" \
  || _mal "no distingue una corrida sin evidencia" "el libro diria que se hizo algo que no se hizo"


echo "-- el contrato de salida (lo que hace que se pueda verificar dos veces seguidas)"
python3 -c "
import json, io, sys
c = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']['cobranzas']
sys.exit(0 if c.get('salida','').endswith('.md') else 1)
" && _ok "el departamento declara UN archivo de salida fijo"   || _mal "no declara salida" "sin ruta fija inventa un nombre distinto cada vez y nadie la encuentra"
grep -q '_md_campo "$depto" salida' "$TD_HERE/mentis-departamento.sh"   && _ok "la verificacion mira el entregable DECLARADO, no lo que la respuesta nombra"   || _mal "no verifica el entregable declarado" "volveria a depender de lo que el modelo diga"
grep -q 'for md_intento in 1 2' "$TD_HERE/mentis-departamento.sh"   && _ok "si el entregable no quedo, reintenta DOS veces antes de darse por vencido"   || _mal "no reintenta" "una corrida fallida quedaria en nada"
python3 -c "
import json, io, sys
c = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']['cobranzas']
sys.exit(0 if c['salida'].split('/')[-1] in c['persona'] else 1)
" && _ok "la persona le dice al modelo el nombre exacto del archivo"   || _mal "la persona no nombra el archivo" "el modelo tiene que adivinar donde escribir"


echo "-- el jefe del departamento"
# El rol NO es un detalle: con 'extract' (un modelo de extraccion) Cobranzas dejaba entregables de
# 3 y 18 bytes -- sabia leer la cartera y no sabia redactar los recordatorios. Con 'reason' salio
# 903 bytes y 4/4 facturas en la primera corrida.
python3 -c "
import json, io, sys
d = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']
malos = [k for k, v in d.items() if v['rol'] not in ('general','code','reason','deep','extract','multimodal','ultra')]
sys.exit(1 if malos else 0)
" && _ok "todo departamento declara un rol que el motor conoce"   || _mal "hay un rol invalido" "nv-agent lo rechazaria al arrancar"
python3 -c "
import json, io, sys
d = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']
# los que tienen que REDACTAR un entregable de texto no pueden tener un jefe de extraccion
malos = [k for k, v in d.items() if v['salida'].endswith('.md') and v['rol'] == 'extract']
sys.exit(1 if malos else 0)
" && _ok "ningun departamento que redacta tiene a 'extract' de jefe"   || _mal "un departamento que redacta usa 'extract'" "ya dejo entregables de 3 bytes por esto"

echo "-- el codigo de salida lo decide el entregable, no el motor"
# Caso real medido: una corrida devolvio rc=4 (el motor agoto su presupuesto) con el entregable
# perfecto: 2.462 bytes y 4 de 4 facturas. Reportar eso como fracaso es tan malo como al reves.
grep -q "lo que manda es el entregable" "$TD_HERE/mentis-departamento.sh" && _ok "entregable verificado = exito, aunque el motor se quede sin pasos" || _mal "el rc lo decide el motor" "una corrida buena se reportaria como fallida"
echo "-- la fuente de datos llega al prompt"
# Mismo error que las herramientas: departamentos.json declaraba de donde salen los datos y eso no
# se cableaba, asi que el departamento tenia que adivinar donde estaban. Medido: sin nombrarle el
# archivo, 1 de 4 corridas dejaba el entregable; nombrandoselo, salio a la primera.
grep -q "TUS DATOS ESTAN EN" "$TD_HERE/mentis-departamento.sh" && _ok "al departamento se le dice cual es su archivo de datos" || _mal "la fuente es decorativa" "tiene que adivinar donde estan los datos"
grep -q "NO existen" "$TD_HERE/mentis-departamento.sh" && _ok "si la fuente no existe, se le pide que lo diga en vez de inventar" || _mal "no avisa si falta la fuente" "inventaria los datos"
python3 -c "
import json, io, sys
d = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']
sys.exit(1 if [k for k, v in d.items() if not v.get('fuente')] else 0)
" && _ok "todo departamento declara su fuente de datos" || _mal "falta declarar fuente" "no sabria de donde leer"
echo "-- la cobertura: el tamaño del archivo no dice si el trabajo esta hecho"
# Caso real (2026-08-20): Presupuestos dejo un entregable de 222 bytes -- por encima del umbral de
# 200 -- que no mencionaba NINGUNA de las tres consultas, y la guarda lo dio por bueno. Un archivo
# pesa lo mismo lleno de trabajo que lleno de relleno.
TD_F="$TD_TMP/fuente.json"; TD_E="$TD_TMP/entregable.md"
printf %s '{"consultas":[{"id":"C-31"},{"id":"C-32"},{"id":"C-33"}]}' > "$TD_F"
# entregable largo pero SIN las consultas: tiene que dar 0
head -c 900 /dev/zero | tr " " "x" > "$TD_E"
TD_R="$(cd "$TD_HERE" && python3 engine/depto_cobertura.py "$TD_F" "$TD_E" consultas id 2>/dev/null)"
case "$TD_R" in "0 3") _ok "un entregable grande SIN las consultas da cobertura 0" ;; *) _mal "cobertura mal calculada" "dio: $TD_R" ;; esac
# entregable con las tres
printf "%s" "Presupuesto C-31... C-32... C-33..." > "$TD_E"
TD_R="$(cd "$TD_HERE" && python3 engine/depto_cobertura.py "$TD_F" "$TD_E" consultas id 2>/dev/null)"
case "$TD_R" in "3 3") _ok "un entregable con las tres consultas da cobertura completa" ;; *) _mal "no cuenta las presentes" "dio: $TD_R" ;; esac
# los dos departamentos declaran su cobertura
python3 -c "
import json, io, sys
d = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']
faltan = [k for k, v in d.items() if not v.get('verificar_cobertura', {}).get('campo')]
sys.exit(1 if faltan else 0)
" && _ok "todo departamento declara que identificadores tiene que cubrir" || _mal "falta verificar_cobertura" "el tamaño solo no alcanza"
grep -q "_md_hecho" "$TD_HERE/mentis-departamento.sh" && _ok "la guarda usa cobertura, no solo bytes" || _mal "la guarda mira solo el tamaño" "ya dejo pasar un entregable vacio de contenido"
echo
echo "== $OK ok, $MAL fallan =="
[ "$MAL" -eq 0 ]
