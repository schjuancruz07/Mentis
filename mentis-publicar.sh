#!/usr/bin/env bash
# mentis-publicar.sh -- publicar una actualizacion para las otras Mentis. Solo en la máquina del usuario.
#
# POR QUE EXISTE (2026-08-07): Mentis lo usan cinco personas o mas, y va a seguir mejorando. Sin un
# canal, cada mejora se queda en la máquina del usuario y las demas copias envejecen.
#
# LO QUE ESTE SCRIPT NO ES: no es "el boton de mandar". Es una serie de frenos ANTES del boton.
# Publicar es meter codigo en la computadora de otra persona; el error se multiplica por cinco y lo
# descubren ellos, no vos. Por eso:
#
#   - No se publica si los tests no pasan.
#   - No se publica sin notas de que cambio (quien recibe tiene que poder decidir si acepta).
#   - No se publica una version que no sea mayor que la ultima.
#   - No se publica sin FIRMAR: sin firma, las otras Mentis lo rechazan y con razon.
#   - Antes de mandar se muestra exactamente que archivos salen.
#
# Y lo que NO viaja: los datos del usuario (conversaciones, memorias, claves) ni el.exe de 225 MB.
# El codigo pesa unos pocos MB; la app se reconstruye del lado de cada uno cuando hace falta.
set -uo pipefail
MP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MP_HERE/engine/nv-firma-lib.sh" 2>/dev/null || { echo "ERROR: falta engine/nv-firma-lib.sh" >&2; exit 1; }

MP_CLAVES="${MENTIS_CLAVES_DIR:-$MP_HERE/.firma}"
MP_PRIV="$MP_CLAVES/mentis-firma-privada.pem"
MP_PUB="$MP_HERE/mentis-firma-publica.pem"     # esta SI viaja: la necesitan para verificar
MP_SALIDA="${MENTIS_PUBLICAR_DIR:-$MP_HERE/actualizaciones}"
MP_VERSION_ARCH="$MP_HERE/VERSION"

# Lo que NO entra en el paquete. Hay DOS listas y la diferencia importa:
#
#   MP_EXCLUIR_RUTA   rutas exactas desde la raiz. "engine/logs" es una sola carpeta concreta.
#   MP_EXCLUIR_NOMBRE nombres que hay que sacar EN CUALQUIER NIVEL.
#
# La segunda existe por un bug real encontrado al probar esto (2026-08-07): node_modules estaba en
# la lista, pero como ruta exacta -- y en la raiz NO hay ninguno. Los que hay son app/node_modules,
# browser-server/node_modules y mcp-bridge/node_modules: 10.179 archivos que se habrian metido en
# un paquete que se supone que pesa "unos pocos MB". Se noto porque el comando tardaba una eternidad,
# no porque alguien releyera el filtro.
MP_EXCLUIR_RUTA=(
  "conversations" "memoria" "engine/logs" "engine/index" "engine/recall-corpus"
  "engine/sombras" "engine/.web-token" "engine/.nv-secrets" "propuestas" "scheduled-runs"
  "workspace" "workspace-app" "avatar" "knowledge" "dist"
  "mentis-settings.json" "modelos-override.json" ".custom-models-secrets.env"
  ".firma" "actualizaciones"
  # mcp-bridge/.secrets.env: GOOGLE_CLIENT_SECRET y compania. Agregado 2026-08-08 ANTES de
  # escribir la primera credencial ahi -- que es el orden que ERR-126 enseño a los golpes: aquella
  # vez la clave privada existio primero y la exclusion llego despues, y en el medio la copia se
  # la llevaba. Un archivo de secretos que todavia no existe es el mejor momento para excluirlo.
  "mcp-bridge/.secrets.env"
  # El token de OAuth que Google devuelve despues del login tampoco puede viajar: es acceso vivo
  # a la cuenta del usuario, no una credencial de aplicacion.
  "mcp-bridge/.google-tokens.json" "mcp-bridge/.gmail-oauth.json"
  # Binarios de servidores MCP (agregado 2026-08-08). El de GitHub solo pesa 25 MB y el paquete
  # entero pesa 2,7: meterlo adentro lo multiplicaria por diez, para mandar un ejecutable que
  # cada uno puede bajar del release oficial en veinte segundos. Ademas son binarios por
  # plataforma -- el.exe de Windows no le sirve a nadie en otro sistema.
  # El instalador los baja si hacen falta; ver mcp-bridge/bin/COMO-OBTENER.md.
  "mcp-bridge/bin"
)
MP_EXCLUIR_NOMBRE=( "node_modules" "__pycache__" ".git" )
MP_EXCLUIR=( "${MP_EXCLUIR_RUTA[@]}" "${MP_EXCLUIR_NOMBRE[@]}" )

_mp_uso() {
  cat <<'FIN'
Uso:
  mentis-publicar.sh clave                  crea el par de claves (UNA sola vez)
  mentis-publicar.sh revisar                que cambiaria, sin publicar nada
  mentis-publicar.sh publicar "<notas>"     corre tests, arma, firma y deja el paquete listo
  mentis-publicar.sh retirar                saca la ultima publicacion
FIN
}

_mp_version() { tr -d ' \r\n' < "$MP_VERSION_ARCH" 2>/dev/null; }

# Compara dos versiones tipo 0.2.0. Devuelve 0 si $1 > $2.
_mp_mayor_que() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  local mayor; mayor="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
  [ "$mayor" = "$a" ]
}

_mp_version_publicada() {
  local m="$MP_SALIDA/manifiesto.json"
  [ -f "$m" ] || { printf '0.0.0'; return 0; }
  python3 -c '
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as f:
        print((json.load(f).get("version") or "0.0.0"))
except Exception:
    print("0.0.0")
' "$(nv_winpath "$m" 2>/dev/null || printf '%s' "$m")" 2>/dev/null | tr -d ' \r\n'
}

# --- clave: se corre una sola vez --------------------------------------------------------------
_mp_clave() {
  echo "== Crear el par de claves de administrador =="
  echo
  echo "La PRIVADA se queda en esta maquina y no viaja nunca. Es lo unico que te permite publicar."
  echo "La PUBLICA se copia adentro de Mentis: es con lo que las otras copias verifican que sos vos."
  echo
  if ! nv_firma_generar_par "$MP_CLAVES" >/dev/null; then return 1; fi
  cp -f "$MP_CLAVES/mentis-firma-publica.pem" "$MP_PUB" || return 1
  echo "  privada : $MP_PRIV   (NO la compartas, no la subas a ningun lado)"
  echo "  publica : $MP_PUB   (esta si va adentro de cada copia)"
  echo "  huella  : $(nv_firma_huella "$MP_PUB")"
  echo
  echo "Si algun dia perdes la privada, no vas a poder publicar mas hasta repartir una clave nueva."
  echo "Hace una copia de $MP_PRIV en algun lugar seguro."
}

# --- que archivos saldrian ---------------------------------------------------------------------
_mp_listar_archivos() {
  local excl=()
  # Rutas exactas: solo esa, desde la raiz.
  for x in "${MP_EXCLUIR_RUTA[@]}"; do excl+=(-path "./$x" -prune -o); done
  # Nombres: en cualquier nivel. Sin esto se colaban los tres node_modules (10.179 archivos).
  for x in "${MP_EXCLUIR_NOMBRE[@]}"; do excl+=(-name "$x" -prune -o); done
  ( cd "$MP_HERE" && find. "${excl[@]}" -type f -print 2>/dev/null | sed 's|^\./||' | sort )
}

_mp_revisar() {
  local v; v="$(_mp_version)"
  local pub; pub="$(_mp_version_publicada)"
  echo "== Que pasaria si publicaras =="
  echo "  version en VERSION      : ${v:-(vacio)}"
  echo "  ultima publicada        : $pub"
  if [ -z "$v" ]; then
    echo "  PROBLEMA: el archivo VERSION esta vacio."
  elif ! _mp_mayor_que "$v" "$pub"; then
    echo "  PROBLEMA: $v no es mayor que $pub. Subi el numero en VERSION antes de publicar."
  else
    echo "  ok: $v es mayor que $pub"
  fi
  echo
  local n; n="$(_mp_listar_archivos | wc -l)"
  local kb; kb="$( ( cd "$MP_HERE" && _mp_listar_archivos | xargs -r du -ck 2>/dev/null | tail -1 | cut -f1 ) )"
  echo "  archivos que viajarian  : $n  (~${kb:-?} KB)"
  echo "  NO viajan               : ${MP_EXCLUIR[*]}"
  echo
  [ -f "$MP_PRIV" ] && echo "  clave privada: presente (huella $(nv_firma_huella "$MP_PUB" 2>/dev/null))" \
                    || echo "  clave privada: FALTA -- corre primero: mentis-publicar.sh clave"
}

# --- publicar ----------------------------------------------------------------------------------
_mp_publicar() {
  local notas="${1:-}"
  local v; v="$(_mp_version)"
  local pub; pub="$(_mp_version_publicada)"

  echo "== Publicar Mentis $v =="
  echo

  # 1. Los frenos, en orden de que tan barato es descubrir el problema.
  if [ -z "$notas" ]; then
    echo "FRENO: falta decir que cambia." >&2
    echo "  Quien la recibe tiene que poder decidir si la quiere. Escribi las notas:" >&2
    echo "  mentis-publicar.sh publicar \"arregle X, agregue Y\"" >&2
    return 2
  fi
  if [ ! -f "$MP_PRIV" ]; then
    echo "FRENO: no hay clave privada. Sin firma, las otras Mentis van a rechazar esto." >&2
    echo "  Corre primero: mentis-publicar.sh clave" >&2
    return 2
  fi
  if [ -z "$v" ]; then
    echo "FRENO: el archivo VERSION esta vacio." >&2; return 2
  fi
  if ! _mp_mayor_que "$v" "$pub"; then
    echo "FRENO: la version $v no es mayor que la publicada ($pub)." >&2
    echo "  Si publicaras con el mismo numero, nadie se enteraria de que hay algo nuevo." >&2
    return 2
  fi

  # 2. Los tests. Este es el freno que mas importa: es lo unico que separa "creo que anda" de
  # "anda". Publicar sin esto es multiplicar un bug por cinco maquinas.
  echo "-- corriendo los tests (si alguno falla, no se publica)"
  local fallaron=0
  # LA LISTA ENVEJECE SOLA, Y ESO ES EL PROBLEMA (2026-08-08).
  # Esta enumeración se escribió el 2026-08-07 con los tests que existían ese día. Al día
  # siguiente ya se habían sumado cinco suites nuevas -- entre ellas la del tope de la cámara y
  # la del panel que se veía cuando no debía -- y la publicación las ignoró: dijo "ok" seis veces
  # y publicó sin haber probado nada de lo nuevo. El freno más importante del sistema estaba
  # verificando una foto vieja del proyecto.
  # Es el mismo modo de falla que ERR-126 con las listas de exclusión: un inventario escrito a
  # mano no se entera de lo que se agrega después, y no da ningún síntoma.
  # Se dejan nombrados los que TIENEN que estar (los lentos y los críticos, para que se note si
  # alguien borra uno) y se suma automáticamente cualquier otro test-*.sh que aparezca.
  local base="test-temas test-formato test-stream test-web test-modelos-override test-instalar
              test-ocultar test-preview-vivo test-camara-tope test-gemini test-modelos-guardia"
  local lista=""
  for t in $base; do [ -f "$MP_HERE/tests/$t.sh" ] && lista="$lista $t"; done
  for f in "$MP_HERE"/tests/test-*.sh; do
    [ -f "$f" ] || continue
    local n; n="$(basename "$f".sh)"
    case " $lista " in *" $n "*) ;; *) lista="$lista $n" ;; esac
  done
  # UN REINTENTO ANTES DE DAR POR ROTO ALGO QUE NO LO ESTA (2026-08-08).
  # Al pasar de 6 tests a 54, aparecio un problema que con 6 no existia: varias suites levantan
  # servidores de verdad y compiten por puertos y CPU. 'test-instancia-unica' fallo en la tanda
  # completa y, corrido solo un minuto despues, dio 15/15. No estaba roto: estaba apretado.
  # Un freno que bloquea publicaciones por ruido termina siendo un freno que alguien desactiva.
  # Por eso: si falla, se reintenta UNA vez, solo y sin nadie mas compitiendo. Si vuelve a fallar,
  # es real y no se publica. El reintento se AVISA, para que un test que siempre necesita dos
  # intentos se note en vez de esconderse detras del "ok".
  for t in $lista; do
    [ -f "$MP_HERE/tests/$t.sh" ] || continue
    if timeout 580 bash "$MP_HERE/tests/$t.sh" >/dev/null 2>&1; then
      echo "   ok   $t"
    else
      sleep 3
      if timeout 580 bash "$MP_HERE/tests/$t.sh" >/dev/null 2>&1; then
        echo "   ok   $t   (fallo en la primera vuelta y paso en la segunda -- mirarlo si se repite)"
      else
        echo "   FALLA $t   (dos veces seguidas)"; fallaron=$((fallaron+1))
      fi
    fi
  done
  if [ "$fallaron" -gt 0 ]; then
    echo >&2
    echo "FRENO: $fallaron suite(s) en rojo. No se publica." >&2
    echo "  Corre la que falla a mano para ver que pasa." >&2
    return 1
  fi

  # 3. Armar el paquete.
  echo "-- armando el paquete"
  mkdir -p "$MP_SALIDA/paquetes" 2>/dev/null || true
  local tgz="$MP_SALIDA/paquetes/mentis-$v.tar.gz"
  local lista; lista="$(mktemp)"
  _mp_listar_archivos > "$lista"
  ( cd "$MP_HERE" && tar -czf "$tgz" -T "$lista" ) || { rm -f "$lista"; echo "ERROR: no pude armar el paquete" >&2; return 1; }
  local cuantos; cuantos="$(wc -l < "$lista")"
  rm -f "$lista"
  local tam; tam="$(du -k "$tgz" 2>/dev/null | cut -f1)"
  echo "   $cuantos archivos, ${tam:-?} KB"

  # 4. Firmar. El sha va aparte para que quien recibe pueda chequear la integridad sin openssl.
  echo "-- firmando"
  local firma sha
  firma="$(nv_firma_firmar "$tgz" "$MP_PRIV")" || { echo "ERROR: no pude firmar" >&2; return 1; }
  sha="$(openssl dgst -sha256 "$tgz" 2>/dev/null | sed -E 's/.*= *//')"
  [ -n "$firma" ] || { echo "ERROR: la firma salio vacia" >&2; return 1; }

  # 5. Verificar la propia firma ANTES de publicar. Parece redundante y no lo es: si por lo que sea
  # la firma no valida, es mejor descubrirlo aca que en la maquina de otro, donde el sintoma va a
  # ser "no me deja actualizar" sin ninguna pista.
  if ! nv_firma_verificar "$tgz" "$firma" "$MP_PUB"; then
    echo "ERROR: la firma que acabo de generar NO valida contra la clave publica." >&2
    echo "  Puede que $MP_PUB sea de otro par de claves. No se publica." >&2
    return 1
  fi
  echo "   firma verificada contra la clave publica"

  # 6. El manifiesto: lo que las otras Mentis leen para saber si hay algo nuevo.
  MPW_V="$v" MPW_NOTAS="$notas" MPW_SHA="$sha" MPW_FIRMA="$firma" \
  MPW_ARCH="paquetes/mentis-$v.tar.gz" MPW_N="$cuantos" \
  python3 -c '
import json, io, os, sys, datetime
ruta = sys.argv[1]
d = {
    "version":  os.environ["MPW_V"],
    "fecha":    datetime.datetime.now().isoformat(timespec="seconds"),
    "notas":    os.environ["MPW_NOTAS"],
    "archivo":  os.environ["MPW_ARCH"],
    "sha256":   os.environ["MPW_SHA"],
    "firma":    os.environ["MPW_FIRMA"],
    "archivos": int(os.environ["MPW_N"]),
}
tmp = ruta + ".tmp"
with io.open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, ruta)
' "$(nv_winpath "$MP_SALIDA/manifiesto.json" 2>/dev/null || printf '%s' "$MP_SALIDA/manifiesto.json")" || return 1

  echo
  echo "LISTO. Version $v preparada en:"
  echo "  $MP_SALIDA"
  echo
  echo "Notas que van a ver: \"$notas\""
  echo
  echo "Para que les llegue, subi esa carpeta al repo:"
  echo "  cd $MP_SALIDA && git add -A && git commit -m \"Mentis $v\" && git push"
  echo
  echo "Si todavia no creaste el repo, mira docs/actualizaciones.md."
}

# --- retirar -----------------------------------------------------------------------------------
_mp_retirar() {
  local m="$MP_SALIDA/manifiesto.json"
  [ -f "$m" ] || { echo "No hay ninguna publicacion para retirar."; return 0; }
  local v; v="$(_mp_version_publicada)"
  echo "Retirando la version $v."
  echo "  Quien NO la instalo todavia va a dejar de verla."
  echo "  Quien ya la instalo la sigue teniendo: avisale que corra 'mentis-actualizar.sh volver'."
  rm -f "$m"
  echo "Retirada. Acordate de subir el cambio:  cd $MP_SALIDA && git add -A && git commit -m 'retiro $v' && git push"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    clave)    _mp_clave ;;
    revisar)  _mp_revisar ;;
    publicar) _mp_publicar "${2:-}" ;;
    retirar)  _mp_retirar ;;
    *) _mp_uso; exit 2 ;;
  esac
fi
