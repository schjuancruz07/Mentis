#!/usr/bin/env bash
# mentis-departamento.sh -- los departamentos de Mentis Cowork.
#
# QUE ES UN DEPARTAMENTO Y QUE NO. No es un modo (no hay que cambiar de modo para usarlo) ni un
# agente corriendo todo el tiempo. Es un PERFIL que se activa por demanda, de a uno por turno: su
# jefe (un rol), su objetivo, sus herramientas, su tope y su memoria.
#
# POR QUE DE A UNO. El reparto simultaneo de Cowork medido el 2026-08-14 salio PEOR que no
# repartir (31/60 contra 37/60). Encender cinco departamentos a la vez es multiplicar justo eso.
# En un organismo, cortarse un dedo no enciende el sistema digestivo.
#
# EL LIBRO MAYOR NO ES PROLIJIDAD. Si esto va a tocar plata, lo que se puede vender no es que
# trabaje solo -- es poder auditar que hizo. Cada corrida deja una linea con fecha, pedido,
# resultado y archivos tocados.
set -uo pipefail
MD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LA CARPETA DE TRABAJO de los departamentos. Estaba escrita a mano en los dos lugares donde se
# lanza el agente, y el campo "salida" de departamentos.json es relativo a la RAIZ -- dos sistemas
# de referencia distintos para la misma ruta. De ahi salia el error de abajo.
MD_TRABAJO="empresa"
MD_CONF="${MENTIS_DEPARTAMENTOS:-$MD_HERE/departamentos.json}"
MD_LIBRO="${MENTIS_LIBRO_MAYOR:-$MD_HERE/memoria/departamentos/libro-mayor.jsonl}"

_md_py() { python3 -c "$1" "${@:2}"; }

_md_listar() {
  _md_py '
import json, io, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
for k, v in d["departamentos"].items():
    print("  %-12s %s" % (k, v["titulo"]))
    print("               objetivo: %s" % v["objetivo"])
    print("               se mide:  %s" % v.get("medida", "(sin medida definida)"))
' "$MD_CONF"
}

# Que departamento corresponde a un pedido. Deterministico y por disparador: si dependiera de que
# un modelo elija, el mismo pedido caeria en departamentos distintos segun el dia.
_md_cual() {
  _md_py '
import json, io, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
t = (sys.argv[2] or "").lower()
for k, v in d["departamentos"].items():
    for disp in v.get("disparadores", []):
        if disp.lower() in t:
            print(k); sys.exit(0)
sys.exit(1)
' "$MD_CONF" "$1"
}

_md_campo() { _md_py '
import json, io, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
v = d["departamentos"].get(sys.argv[2], {})
x = v.get(sys.argv[3], "")
print(x if not isinstance(x, list) else " ".join(map(str, x)))
' "$MD_CONF" "$1" "$2"; }

_md_anotar() {  # $1=depto $2=pedido $3=resultado $4=rc
  mkdir -p "$(dirname "$MD_LIBRO")" 2>/dev/null
  MD_D="$1" MD_P="$2" MD_R="$3" MD_RC="$4" MD_L="$MD_LIBRO" _md_py '
import json, io, os, datetime
fila = {
    "fecha": datetime.datetime.now().isoformat(timespec="seconds"),
    "departamento": os.environ["MD_D"],
    "pedido": os.environ["MD_P"][:400],
    "resultado": os.environ["MD_R"][:1200],
    "rc": os.environ["MD_RC"],
}
with io.open(os.environ["MD_L"], "a", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(fila, ensure_ascii=False) + "\n")
'
}

# _md_hecho <depto> <archivo> -> 0 si el entregable esta DE VERDAD hecho.
#
# El tamaño solo no alcanza (2026-08-20): Presupuestos dejo un archivo de 222 bytes -- por encima
# del umbral de 200 -- que no mencionaba NINGUNA de las tres consultas, y la corrida se dio por
# buena. El peso de un archivo no dice si el trabajo esta hecho. Se cuenta ademas cuantos
# identificadores de la fuente aparecen adentro.
_md_hecho() {
  local depto="$1" arch="$2" tam cob pres tot minimo lista campo fuente
  tam=0; [ -f "$arch" ] && tam="$(wc -c < "$arch" | tr -d " ")"
  [ "${tam:-0}" -ge 200 ] || return 1
  lista="$(_md_campo_json "$depto" verificar_cobertura lista)"
  campo="$(_md_campo_json "$depto" verificar_cobertura campo)"
  minimo="$(_md_campo_json "$depto" verificar_cobertura minimo)"
  [ -n "$lista" ] && [ -n "$campo" ] || return 0   # sin cobertura declarada, alcanza el tamaño
  fuente="$MD_HERE/$(_md_campo_json "$depto" verificar_cobertura archivo)"
  [ -f "$fuente" ] || return 0
  read -r pres tot <<< "$(python3 "$MD_HERE/engine/depto_cobertura.py" "$fuente" "$arch" "$lista" "$campo" 2>/dev/null)"
  [[ "${minimo:-0}" =~ ^[0-9]+$ ]] || minimo=1
  [ "${pres:-0}" -ge "$minimo" ] || return 1
  # LAS CUENTAS SE VERIFICAN CON CODIGO (2026-08-20). El modelo escribio las lineas bien y sumo
  # 288400 en vez de 202400: 86.000 pesos de diferencia en un presupuesto listo para mandar. Con
  # plata de por medio esto no se le puede pedir al modelo por texto.
  if [ "$(_md_campo "$depto" verificar_aritmetica)" = "True" ]; then
    MD_ARIT="$( cd "$MD_HERE" && python3 engine/depto_aritmetica.py "$arch" 2>/dev/null )" || {
      echo "[departamento] las cuentas NO cierran:" >&2
      printf %s "$MD_ARIT" | head -3 | sed "s/^/    /" >&2
      return 1
    }
  fi
  return 0
}

# lee un campo anidado de verificar_cobertura
_md_campo_json() {
  # cd + ruta relativa: python no entiende las rutas estilo /c/... que da MSYS.
  ( cd "$MD_HERE" 2>/dev/null && MD_D="$1" MD_K1="$2" MD_K2="$3" python3 -c "
import json, io, os
d = json.load(io.open('departamentos.json', encoding='utf-8'))['departamentos']
v = d.get(os.environ['MD_D'], {}).get(os.environ['MD_K1'], {})
print(v.get(os.environ['MD_K2'], '') if isinstance(v, dict) else '')
" 2>/dev/null )
}

_md_correr() {  # $1=depto $2=pedido
  local depto="$1" pedido="$2"
  local titulo objetivo rol persona irrev memoria tope
  local md_fuente md_fuente_txt md_salida md_abs md_tam md_intento md_out md_apagar md_permitidas
  local md_salida_vista md_donde md_fix md_arit_on MD_ARIT_FIX=""
  titulo="$(_md_campo "$depto" titulo)"
  [ -z "$titulo" ] && { echo "No existe el departamento '$depto'. Los que hay:"; _md_listar; return 2; }
  objetivo="$(_md_campo "$depto" objetivo)"
  rol="$(_md_campo "$depto" rol)"; [ -z "$rol" ] && rol="reason"
  persona="$(_md_campo "$depto" persona)"
  irrev="$(_md_campo "$depto" irreversibles)"
  memoria="$MD_HERE/$(_md_campo "$depto" memoria)"
  md_salida="$(_md_campo "$depto" salida)"

  local recuerdo=""
  [ -f "$memoria" ] && recuerdo="$(tail -c 2000 "$memoria")"

  # LA FUENTE TIENE QUE LLEGAR AL PROMPT (2026-08-19). Estaba declarada en departamentos.json y no
  # se cableaba: el departamento no sabia donde estaban sus datos y los buscaba a ciegas. Medido:
  # sin nombrarle el archivo, 1 de 4 corridas dejaba el entregable; nombrandoselo, sale a la primera.
  # La fuente es una LISTA: un departamento puede necesitar varios archivos (Presupuestos no puede
  # cotizar sin la lista de precios Y las consultas). Nombrarle uno solo lo deja a ciegas para el otro.
  md_fuente="$(_md_campo "$depto" fuente)"
  md_fuente_txt=""
  local md_f md_faltan=""
  for md_f in $md_fuente; do
    if [ -f "$MD_HERE/$md_f" ]; then
      md_fuente_txt="${md_fuente_txt:+$md_fuente_txt, }$(basename "$md_f")"
    else
      md_faltan="${md_faltan:+$md_faltan, }$md_f"
    fi
  done
  [ -n "$md_fuente_txt" ] && md_fuente_txt="TUS DATOS ESTAN EN: $md_fuente_txt (en tu carpeta de trabajo). Leelos TODOS antes de cualquier otra cosa."
  [ -n "$md_faltan" ] && md_fuente_txt="$md_fuente_txt
OJO: estos archivos que necesitas NO existen: $md_faltan. Decilo y NO inventes datos."

  # DONDE DEJAR EL ENTREGABLE (2026-08-20). El campo "salida" existia desde el 2026-08-19 y su
  # propia nota explica para que: "sin esto el departamento inventaba el nombre en cada corrida".
  # Pero el valor NUNCA llegaba al prompt -- solo se usaba para verificar despues. O sea que se le
  # exigia acertar un nombre que nadie le habia dicho.
  #
  # Lo que quedo de eso, a la vista en la carpeta empresa/: 'empresa/empresa/' con TRES borradores
  # (el modelo escribio la ruta "empresa/cobranzas-borradores.md" tal cual, pero su carpeta de
  # trabajo YA es empresa/, asi que cayo un nivel mas abajo), un 'ruta/relativa', y un archivo
  # llamado '...' de 3 bytes. Esa es la corrida que el libro mayor pesco diciendo "listo".
  #
  # Se le pasa la ruta VISTA DESDE SU CARPETA DE TRABAJO, que es lo unico que el puede escribir
  # sin equivocarse. El campo sigue siendo relativo a la raiz porque asi lo verifica el libro.
  local md_salida_vista="${md_salida#$MD_TRABAJO/}"
  local md_donde=""
  [ -n "$md_salida" ] && md_donde="DONDE DEJAR EL RESULTADO: en el archivo \"$md_salida_vista\" de tu carpeta de trabajo. Ese nombre exacto, sin carpetas adelante -- es donde el usuario lo busca y donde se verifica que lo hiciste. Si ya existe, lo reescribis entero.

"

  local prompt="$persona

$md_fuente_txt

${md_donde}TU OBJETIVO: $objetivo

LO QUE NO PODES HACER SIN QUE USUARIO DIGA QUE SI: $irrev
Si el pedido necesita una de esas, DEJALO PREPARADO y decile al usuario que falta su OK. No lo hagas.

${recuerdo:+LO QUE YA SABES DE ANTES:
$recuerdo

}PEDIDO DE USUARIO:
$pedido"

  tope="$(_md_campo "$depto" tope_por_turno)"; [[ "$tope" =~ ^[0-9]+$ ]] || tope=15

  # LA LISTA DE HERRAMIENTAS SE APLICA DE VERDAD (2026-08-19). Estaba declarada y sin cablear: el
  # departamento corria con exec, run y telefono encendidos. nv-agent.sh recibe con -n las
  # PROHIBIDAS, asi que se calcula el complemento.
  local md_todas="read search write edit exec run git lsp mcp gen datos delegate parallel subagent task browse screen control webcam telefono arduino drive vscode video skill recordar presencia"
  md_permitidas="$(_md_campo "$depto" herramientas)"
  md_apagar=""
  for _t in $md_todas; do
    case " $md_permitidas " in
      *" $_t "*) : ;;
      *) md_apagar="${md_apagar:+$md_apagar,}$_t" ;;
    esac
  done
  echo "[departamento] $titulo (jefe: rol $rol, tope $tope pasos, herramientas: ${md_permitidas// /, })" >&2

  # NO SE CAPTURA CON $(...) (2026-08-20). Una corrida quedo COLGADA 20 HORAS pese a tener timeout
  # 600 adentro y 900 afuera. La causa ya estaba documentada en este proyecto: en MSYS la genealogia
  # de procesos esta rota por el fork() emulado, asi que timeout mata al proceso directo pero NO a
  # los nietos (curl, python). Y $(...) no espera a que el proceso muera: espera a que se CIERRE EL
  # PIPE, y un nieto huerfano lo mantiene abierto para siempre. Con redireccion a archivo no hay
  # pipe que esperar, y </dev/null evita quedarse esperando una entrada que nadie va a escribir.
  local rc=0 salida=""
  md_out="$(mktemp)"
  ( cd "$MD_HERE" && timeout -k 20 ${MENTIS_DEPTO_TIMEOUT:-300} bash engine/nv-agent.sh -w -n "$md_apagar" -d "$MD_HERE/$MD_TRABAJO" \
      -m "$rol" -i "$tope" "$prompt" > "$md_out" 2>/dev/null < /dev/null ) && rc=0 || rc=$?
  salida="$(cat "$md_out" 2>/dev/null)"; rm -f "$md_out"

  # SE VERIFICA EL ENTREGABLE DECLARADO Y SE REINTENTA HASTA DOS VECES (2026-08-19). Medido: el
  # reintento rescata corridas que arrancaron mal (163 -> 2.462 bytes). Y el codigo de salida lo
  # decide EL ENTREGABLE, no el motor: una corrida devolvio rc=4 con el archivo perfecto.
  if [ -n "$md_salida" ]; then
    md_abs="$MD_HERE/$md_salida"
    for md_intento in 1 2; do
      md_tam=0; [ -f "$md_abs" ] && md_tam="$(wc -c < "$md_abs" | tr -d ' ')"
      # LAS SUMAS LAS ARREGLA EL CODIGO, NO EL MODELO (2026-08-20). Antes esto solo verificaba y,
      # si no cerraba, le pedia al modelo que lo rehiciera -- o sea que le pedia sumar de nuevo al
      # que no sabe sumar. Medido sobre tres corridas de Presupuestos: falla la aritmetica 1 de
      # cada 3, y una de esas paso la guarda vieja con 60.000 pesos de mas.
      # Corrige SOLO los totales (sumas de numeros ya escritos ahi). Un producto mal no se toca:
      # ahi el numero equivocado puede ser el precio unitario, y "corregir" el resultado
      # consolidaria el error -- eso sigue yendo a reintento.
      # "True" con mayuscula: _md_campo saca el valor con python, y python imprime los booleanos
      # de JSON como True/False. Comparar contra "true" no coincide NUNCA -- la guarda no se
      # habria activado ni una vez. Se aceptan las dos formas para que no dependa de eso.
      md_arit_on="$(_md_campo "$depto" verificar_aritmetica)"
      if [ "${md_tam:-0}" -ge 200 ] && { [ "$md_arit_on" = "True" ] || [ "$md_arit_on" = "true" ]; }; then
        md_fix="$( cd "$MD_HERE" && python3 engine/depto_aritmetica.py --corregir "$md_abs" 2>/dev/null | grep '^CORREGIDO:' )" || true
        if [ -n "${md_fix// }" ]; then
          echo "[departamento] aritmetica corregida por el motor:" >&2
          printf '  %s
' "$md_fix" >&2
          MD_ARIT_FIX="${MD_ARIT_FIX:+$MD_ARIT_FIX; }$md_fix"
        fi
      fi
      _md_hecho "$depto" "$md_abs" && break
      # EL REINTENTO TIENE QUE DECIR QUE ESTUVO MAL (2026-08-20). "No dejaste el archivo escrito"
      # cuando el problema era una suma equivocada manda al modelo a reescribir todo de nuevo en vez
      # de corregir la cuenta. Se le pasa el motivo concreto.
      md_motivo="el archivo quedo vacio o incompleto"
      if [ "${md_tam:-0}" -ge 200 ]; then
        md_arit="$( cd "$MD_HERE" && python3 engine/depto_aritmetica.py "$md_abs" 2>/dev/null )" ||           md_motivo="las cuentas no cierran -- $(printf %s "$md_arit" | head -2 | tr '
' ' ')"
      fi
      echo "[departamento] el entregable no pasa ($md_salida: ${md_tam} bytes, $md_motivo). Reintento $md_intento de 2." >&2
      md_out="$(mktemp)"
      ( cd "$MD_HERE" && timeout -k 20 ${MENTIS_DEPTO_TIMEOUT:-300} bash engine/nv-agent.sh -w -n "$md_apagar" -d "$MD_HERE/$MD_TRABAJO" \
          -m "$rol" -i "$tope" "$prompt

OJO: el intento anterior NO quedo bien: $md_motivo. Corregilo AHORA en '$md_salida'. Si el problema es una cuenta, rehacela: sumá los numeros uno por uno y comproba el total antes de escribirlo." > "$md_out" 2>/dev/null < /dev/null ) || true
      salida="$(cat "$md_out" 2>/dev/null)"; rm -f "$md_out"
    done
    md_tam=0; [ -f "$md_abs" ] && md_tam="$(wc -c < "$md_abs" | tr -d ' ')"
    if ! _md_hecho "$depto" "$md_abs"; then
      printf '%s\n' "$salida"
      echo ""
      echo "OJO: el entregable NO quedo hecho. $md_salida tiene ${md_tam} bytes."
      echo "     No lo des por cerrado: no hay borradores para revisar."
      _md_anotar "$depto" "$pedido" "SIN EVIDENCIA ($md_salida: ${md_tam} bytes) :: $salida" "sin-evidencia"
      return 3
    fi
    echo "[departamento] entregable verificado: $md_salida (${md_tam} bytes)" >&2
    rc=0   # lo que manda es el entregable, no como termino el motor
  fi

  printf '%s\n' "$salida"
  _md_anotar "$depto" "$pedido" "$salida" "$rc"
  return $rc
}

case "${1:-}" in
  listar|"") echo "Departamentos:"; _md_listar ;;
  cual)      _md_cual "${2:-}" || { echo "(ningun departamento cubre ese pedido)"; exit 1; } ;;
  correr)    shift; _md_correr "${1:-}" "${2:-}" ;;
  libro)
    if [ -f "$MD_LIBRO" ]; then
      MD_L="$MD_LIBRO" _md_py '
import json, io, os
for ln in io.open(os.environ["MD_L"], encoding="utf-8"):
    ln = ln.strip()
    if not ln: continue
    d = json.loads(ln)
    print("%s  %-11s rc=%s" % (d["fecha"][:16], d["departamento"], d["rc"]))
    print("    pedido: %s" % d["pedido"][:100])
    print("    hizo:   %s" % (d["resultado"][:100].replace("\n", " ") or "(nada)"))
'
    else
      echo "El libro mayor todavia esta vacio."
    fi ;;
  *) echo "uso: mentis-departamento.sh [listar|cual <texto>|correr <depto> <pedido>|libro]"; exit 2 ;;
esac
