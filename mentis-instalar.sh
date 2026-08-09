#!/usr/bin/env bash
# mentis-instalar.sh -- deja a Mentis andando en una maquina que no es la del usuario.
#
# POR QUE EXISTE (2026-08-06, pedido del usuario): que sus amigos y su familia puedan usar Mentis.
#
# LA REGLA QUE MANDA: la copia va SIN LOS DATOS DE USUARIO. No es una preferencia de prolijidad --
# adentro de esta carpeta hay conversaciones enteras, memorias sobre su vida, su ubicacion, su
# nombre, y las CLAVES DE API que el paga. Copiar eso seria filtrarle la vida a otra persona y
# regalarle las claves de paso. Por eso este script arranca listando lo que NO viaja, y el chequeo
# de que la copia salio limpia corre SIEMPRE al final, no como opcion.
#
# Uso:
#   mentis-instalar.sh preparar <carpeta-destino>   arma la copia limpia para llevarse
#   mentis-instalar.sh configurar                   (en la maquina nueva) pide claves y deja andando
#   mentis-instalar.sh revisar                      dice que falta para que funcione
set -uo pipefail
MI_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- LO QUE NUNCA VIAJA -------------------------------------------------------------------------
# Cada linea es "que es" para que se entienda por que esta, y para que nadie la saque sin pensar.
NO_VIAJA=(
  "conversations"            # todo lo que el usuario hablo con Mentis
  "memoria"                  # las memorias que Mentis fue guardando sobre el
  "engine/logs"              # telemetria, errores, y prompts que quedaron en los logs
  "engine/index"             # el indice de busqueda: contiene el texto de las conversaciones
  "engine/recall-corpus"     # idem, el corpus del pasado
  "engine/sombras"           # repo sombra de deshacer: copias de archivos suyos
  "engine/.web-token"        # la llave de su pagina del celular
  "engine/.nv-secrets"       # claves
  "propuestas"               # diagnosticos de SU sistema
  "scheduled-runs"           # sus tareas programadas
  "workspace"                # archivos de trabajo suyos
  "workspace-app"            # idem
  "avatar"                   # su foto
  "knowledge"                # notas suyas
  "dist"                     # la app empaquetada: se genera en la maquina nueva
  "mentis-settings.json"     # perfil, nombre, ubicacion, memorias, conectores y CLAVES
  "modelos-override.json"    # decisiones de modelos medidas en SU cuenta
  # LA CLAVE PRIVADA DE ADMINISTRADOR. Lo mas grave que podria viajar: con ella, cualquiera de
  # las cinco personas podria firmar una actualizacion y meter codigo en las maquinas de las otras
  # cuatro. Es exactamente el poder que la firma existe para concentrar en una sola maquina.
  # Faltaba, y lo encontro tests/test-admin.sh (2026-08-07).
  ".firma"
  "actualizaciones"          # los paquetes publicados: se bajan del repo, no viajan en la copia
  ".actualizaciones-cache"   # copia local de lo bajado
  ".respaldos-actualizacion" # respaldos de SUS versiones anteriores
  ".archivos-instalados.sha256"
  # Credenciales del puente MCP (agregado 2026-08-08, ANTES de que el archivo existiera).
  # GOOGLE_CLIENT_SECRET identifica la aplicacion del usuario; los tokens son acceso VIVO a su Gmail,
  # su Drive y su calendario. Cada persona que reciba una copia tiene que poner las suyas.
  # Se agrega a las DOS listas a la vez -- la de publicar y esta -- porque ERR-126 fue justamente
  # actualizar una sola y creer que estaba cubierto.
  "mcp-bridge/.secrets.env"
  "mcp-bridge/.google-tokens.json"
  "mcp-bridge/.gmail-oauth.json"
  "node_modules"
  "__pycache__"
  ".git"
)
# Archivos sueltos que sí van, pero vaciados.
PLANTILLA_SETTINGS='{
  "theme": "oscuro",
  "profile": { "fullName": "", "nickname": "", "role": "", "instructions": "" },
  "connectorsEnabled": {}
}'

_uso() { sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'; }

_hay() { command -v "$1" >/dev/null 2>&1; }

# --- preparar: armar la copia limpia -----------------------------------------------------------
_preparar() {
  local destino="$1"
  [ -n "$destino" ] || { echo "ERROR: decime a que carpeta la copio" >&2; return 2; }
  if [ -e "$destino" ] && [ -n "$(ls -A "$destino" 2>/dev/null)" ]; then
    echo "ERROR: '$destino' ya existe y tiene cosas adentro. Elegi una carpeta vacia." >&2
    return 2
  fi
  mkdir -p "$destino" || return 1

  echo "== Copiando Mentis sin datos personales =="
  local excl=()
  for x in "${NO_VIAJA[@]}"; do excl+=(--exclude="$x"); done

  if _hay rsync; then
    rsync -a "${excl[@]}" "$MI_HERE"/ "$destino"/ || return 1
  else
    # Sin rsync (pasa en Windows limpio): copia con tar, que respeta --exclude igual.
    tar -cf - -C "$MI_HERE" "${excl[@]}". | tar -xf - -C "$destino" || return 1
  fi

  printf '%s\n' "$PLANTILLA_SETTINGS" > "$destino/mentis-settings.json"
  mkdir -p "$destino/conversations" "$destino/memoria" "$destino/engine/logs" "$destino/workspace"

  # El mail de contacto que se le manda a Nominatim (OpenStreetMap pide identificar a quien
  # consulta). En la copia no puede seguir siendo el del usuario: las consultas de otra persona irian
  # a su nombre, y si alguien abusara del servicio le cerrarian el acceso a el.
  if [ -f "$destino/mentis-location.sh" ]; then
    # El mail se arma en dos pedazos a proposito: si estuviera entero en este archivo, el chequeo
    # de mas abajo se detectaria a si mismo y avisaria de una fuga que no existe.
    local _u="usuario"; _u="${_u}07@ejemplo.com"
    sed -i "s/contacto: ${_u//./\\.}/contacto: usuario de Mentis/" "$destino/mentis-location.sh" 2>/dev/null || true
  fi

  echo
  _revisar_copia "$destino"
}

# --- el chequeo que no se saltea ---------------------------------------------------------------
# Corre SIEMPRE despues de copiar. Un instalador que "casi siempre" limpia los datos no sirve:
# el error se descubre cuando la copia ya esta en la maquina de otro.
_revisar_copia() {
  local destino="$1" problemas=0
  echo "== Revisando que no se haya colado nada personal =="

  # Se chequea que esten VACIOS, no que no existan: varias de estas carpetas se recrean vacias a
  # proposito mas arriba, porque Mentis las necesita para arrancar. Chequear la existencia daba
  # cuatro "MAL" sobre carpetas que acababa de crear este mismo script.
  for x in "${NO_VIAJA[@]}"; do
    [ "$x" = "mentis-settings.json" ] && continue
    if [ -d "$destino/$x" ]; then
      if [ -n "$(ls -A "$destino/$x" 2>/dev/null)" ]; then
        echo "  MAL: '$x' viajo CON CONTENIDO ($(find "$destino/$x" -type f 2>/dev/null | wc -l) archivos)"
        problemas=$((problemas+1))
      fi
    elif [ -e "$destino/$x" ]; then
      echo "  MAL: viajo el archivo '$x'"; problemas=$((problemas+1))
    fi
  done

  # Claves de NVIDIA sueltas. Es el chequeo mas importante: una clave olvidada en un archivo no la
  # ve nadie hasta que llega la factura o alguien la usa.
  #
  # tests/ queda afuera A PROPOSITO y con motivo verificado: test-guardas.sh contiene claves FALSAS
  # de juguete porque su trabajo es justamente comprobar que el
  # guard de privacidad las enmascara. Sin esta excepcion, el instalador da un "MAL" que no lo es
  # -- y una alarma que suena siempre termina siendo una alarma que nadie mira.
  local conclave
  conclave="$(grep -rlE "nvapi-[A-Za-z0-9_-]{20,}" "$destino" 2>/dev/null | grep -v "/tests/" | head -5)"
  if [ -n "$conclave" ]; then
    echo "  MAL: hay claves de NVIDIA en:"; printf '    %s\n' $conclave; problemas=$((problemas+1))
  fi

  # Datos de contacto del dueño original. El caso real: mentis-location.sh manda su mail como User-Agent a
  # Nominatim (OpenStreetMap lo exige para identificar a quien consulta). En la copia de otra
  # persona eso ademas de personal es incorrecto: las consultas de ella irian a nombre de el.
  local connombre
  local patron_mail="usuario"; patron_mail="${patron_mail}07"
  connombre="$(grep -rli "$patron_mail" "$destino" 2>/dev/null | grep -v "/docs/" | head -5)"
  if [ -n "$connombre" ]; then
    echo "  MAL: quedo el mail del usuario en:"; printf '    %s\n' $connombre; problemas=$((problemas+1))
  fi

  if [ "$problemas" -eq 0 ]; then
    echo "  OK: la copia esta limpia."
    echo
    echo "Ahora, en la maquina nueva:  bash mentis-instalar.sh configurar"
    return 0
  fi
  echo
  echo "NO la entregues asi: hay $problemas problema(s) arriba." >&2
  return 1
}

# --- revisar: que falta para que ande ----------------------------------------------------------
_revisar() {
  local faltan=0
  echo "== Lo que Mentis necesita en esta maquina =="
  for par in "bash:para todo" "python3:el motor" "node:la app" "curl:hablar con NVIDIA" "git:opcional, para deshacer"; do
    local cmd="${par%%:*}" para="${par#*:}"
    if _hay "$cmd"; then
      echo "  OK    $cmd  ($para)"
    else
      case "$cmd" in
        git) echo "  falta $cmd  ($para)" ;;
        *)   echo "  FALTA $cmd  ($para)"; faltan=$((faltan+1)) ;;
      esac
    fi
  done

  echo
  echo "== Claves =="
  # Se lee con la MISMA funcion que usa el motor (nv_read_setting), no con un parseo propio: las
  # claves viven bajo "env" y no en la raiz del JSON, y una segunda implementacion de esa lectura
  # es justo la que un dia queda desincronizada y hace decir "falta la clave" con la clave puesta
  # -- que es exactamente lo que paso al escribir esto.
  # LA CLAVE NO VIVE EN mentis-settings.json (lo comprobe al escribir esto y me habia equivocado):
  # vive en ~/.claude/settings.json, bajo "env", que es de donde la lee nv_read_setting. Se lee con
  # esa misma funcion y no con un parseo propio -- una segunda implementacion es justo la que un dia
  # queda desincronizada y avisa "falta la clave" con la clave puesta.
  #
  # Que este afuera del repo es una buena noticia para la copia: las claves del usuario no viajan ni
  # por accidente. Lo que si vive adentro y es personal es el "profile" de mentis-settings.json.
  local key=""
  if [ -f "$MI_HERE/engine/nv-lib.sh" ]; then
    key="$(bash -c 'source "'"$MI_HERE"'/engine/nv-lib.sh" 2>/dev/null; nv_read_setting NVIDIA_API_KEY' 2>/dev/null | tr -d ' \r\n')"
  fi
  if [ -n "$key" ]; then
    echo "  OK    NVIDIA_API_KEY cargada (${#key} caracteres)"
  else
    echo "  FALTA NVIDIA_API_KEY -- sin esto Mentis no piensa. Es gratis:"
    echo "        1. Entra a  https://build.nvidia.com/  y crea una cuenta."
    echo "        2. Generá una API key (empieza con 'nvapi-')."
    echo "        3. Corre:  bash mentis-instalar.sh configurar"
    faltan=$((faltan+1))
  fi

  # --- LO OPCIONAL, DICHO CON HONESTIDAD -------------------------------------------------------
  # Investigacion del 2026-08-06 (se leyo el codigo y se probo cada servicio). Las claves viven en
  # TRES archivos distintos, no en uno, y el instalador viejo solo escribia en el primero: quien lo
  # usaba se quedaba sin imagenes, sin video y sin Google, sin enterarse de por que.
  echo
  echo "== Lo opcional =="
  local sec="$MI_HERE/.custom-models-secrets.env"
  _tiene_secreto() { [ -f "$sec" ] && grep -q "^$1=." "$sec" 2>/dev/null; }

  _tiene_secreto IDEOGRAM_API_KEY \
    && echo "  OK    Ideogram (generar imagenes)" \
    || echo "  --    Ideogram: generar imagenes. ES PAGO. Sin esto no se generan imagenes."
  _tiene_secreto RUNWAY_API_KEY \
    && echo "  OK    Runway (generar video)" \
    || echo "  --    Runway: generar video. ES PAGO."
  _tiene_secreto NASA_API_KEY \
    && echo "  OK    NASA (foto astronomica)" \
    || echo "  --    NASA: la foto astronomica anda igual sin clave (usa DEMO_KEY, probado). Una clave propia solo sube el limite."

  # ElevenLabs merece una advertencia y no una linea mas: pedirle a alguien que haga el tramite
  # para algo que no va a poder usar es peor que no ofrecerlo. Medido 2026-08-06: el plan gratis da
  # 10 creditos POR MES via API (unos 20 caracteres). Los 10.000 caracteres del plan gratis son de
  # la pagina web, no de la API.
  local el_key=""
  [ -f "$MI_HERE/engine/nv-lib.sh" ] && el_key="$(bash -c 'source "'"$MI_HERE"'/engine/nv-lib.sh" 2>/dev/null; nv_read_setting ELEVENLABS_API_KEY' 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$el_key" ]; then
    echo "  OK    ElevenLabs (voz)"
  else
    echo "  --    ElevenLabs: NO te conviene salvo que pagues. El plan gratis da 10 creditos por MES"
    echo "        por API (~20 caracteres). La voz de NVIDIA ya viene y funciona bien."
  fi

  # Google Workspace: el conector YA esta cableado y habilitado en mcp-bridge/mcp-servers.json.
  # Lo unico que falta son las credenciales OAuth. No hay que construir nada.
  if grep -q '"GOOGLE_CLIENT_ID": *"[^$][^"]*"' "$MI_HERE/mcp-bridge/mcp-servers.json" 2>/dev/null; then
    echo "  OK    Google Workspace (Drive, Docs, Gmail, Calendar...)"
  else
    echo "  --    Google Workspace (Drive, Docs, Sheets, Gmail, Calendar): ya esta cableado, le faltan"
    echo "        las credenciales. Es el tramite mas largo de todos: mira INSTALAR.md."
  fi

  echo
  echo "== Lo que YA funciona sin cargar nada =="
  echo "  Wikipedia, fotos libres de Wikimedia, ubicacion y mapas (OpenStreetMap), busqueda web,"
  echo "  vuelos en vivo, datos publicos, archive.org, papers, y generacion de imagenes por"
  echo "  pollinations. Probados el 2026-08-06: los 11 contestan sin clave."

  echo
  [ "$faltan" -eq 0 ] && echo "Listo: no falta nada de lo necesario." || echo "Falta(n) $faltan cosa(s) necesaria(s)."
  return 0
}

# --- configurar: pedir las claves y dejar andando ----------------------------------------------
_configurar() {
  echo "== Configurar Mentis en esta maquina =="
  echo
  echo "Hace falta una API key de NVIDIA (gratis): https://build.nvidia.com/"
  echo "Pegala aca abajo (empieza con nvapi-). Queda guardada SOLO en esta maquina."
  echo
  printf 'NVIDIA_API_KEY: '
  local key=""
  read -r key
  key="$(printf '%s' "$key" | tr -d ' \r\n')"
  case "$key" in
    nvapi-*) : ;;
    "") echo "ERROR: no pegaste nada." >&2; return 2 ;;
    *) echo "ERROR: una key de NVIDIA empieza con 'nvapi-'. Eso no lo parece." >&2; return 2 ;;
  esac

  printf '¿Como querés que te llame? (nombre o apodo): '
  local nombre=""; read -r nombre

  # Van a DOS archivos distintos y no es un detalle:
  #   ~/.claude/settings.json  -> la clave, bajo "env" (es de donde la lee el motor)
  #   mentis-settings.json     -> el perfil (como te llamas), que es del proyecto
  local claude_settings="${HOME}/.claude/settings.json"
  mkdir -p "$(dirname "$claude_settings")" 2>/dev/null || true
  [ -f "$claude_settings" ] || printf '{}' > "$claude_settings"

  MI_KEY="$key" python3 -c '
import json, io, os, sys
ruta = sys.argv[1]
try:
    with io.open(ruta, encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
d.setdefault("env", {})["NVIDIA_API_KEY"] = os.environ["MI_KEY"]
tmp = ruta + ".tmp"
with io.open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, ruta)
print("clave guardada en " + ruta)
' "$(cygpath -w "$claude_settings" 2>/dev/null || printf '%s' "$claude_settings")" || return 1

  MI_NOMBRE="$nombre" python3 -c '
import json, io, os, sys
ruta = sys.argv[1]
try:
    with io.open(ruta, encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
d.setdefault("profile", {})
if os.environ.get("MI_NOMBRE"):
    d["profile"]["nickname"] = os.environ["MI_NOMBRE"]
tmp = ruta + ".tmp"
with io.open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, ruta)
' "$(cygpath -w "$MI_HERE/mentis-settings.json" 2>/dev/null || printf '%s' "$MI_HERE/mentis-settings.json")" || return 1

  echo
  echo "Probando la clave contra NVIDIA..."
  local salida
  salida="$(timeout 90 bash "$MI_HERE/engine/ask-nvidia.sh" fast "Responde solo: listo" 2>&1 | tail -3)"
  if printf '%s' "$salida" | grep -qi "listo"; then
    echo "  OK: Mentis contesta."
  else
    echo "  El modelo no contesto todavia. Puede ser la clave o que NVIDIA este saturada."
    echo "  Respuesta: $(printf '%s' "$salida" | head -c 200)"
  fi

  # --- LAS OPCIONALES -------------------------------------------------------------------------
  # Van DESPUES de probar la principal: si NVIDIA no anda, no tiene sentido seguir pidiendo cosas.
  # Y cada una va al archivo que le corresponde -- son tres lugares distintos, y ese fue el bug del
  # instalador anterior: escribia todo en uno y las demas nunca llegaban a destino.
  echo
  echo "== Lo opcional (podes saltear todo con Enter) =="
  echo "Nada de esto hace falta para que funcione."
  echo

  echo "Ideogram genera imagenes. ES PAGO (https://ideogram.ai)."
  printf 'IDEOGRAM_API_KEY (Enter para saltear): '
  local ig=""; read -r ig; ig="$(printf '%s' "$ig" | tr -d ' \r\n')"
  [ -n "$ig" ] && _guardar_secreto IDEOGRAM_API_KEY "$ig"

  echo
  echo "NASA: la foto astronomica del dia. Anda SIN clave (probado); una propia solo sube el limite."
  echo "Si igual la queres: https://api.nasa.gov (gratis, sale en un minuto)."
  printf 'NASA_API_KEY (Enter para saltear): '
  local na=""; read -r na; na="$(printf '%s' "$na" | tr -d ' \r\n')"
  [ -n "$na" ] && _guardar_secreto NASA_API_KEY "$na"

  echo
  echo "ElevenLabs (voz): te lo NO recomiendo salvo que pagues. El plan gratis da 10 creditos por"
  echo "MES via API -- unos 20 caracteres. La voz que ya viene con NVIDIA funciona bien."
  printf 'ELEVENLABS_API_KEY (Enter para saltear, es lo normal): '
  local el=""; read -r el; el="$(printf '%s' "$el" | tr -d ' \r\n')"
  if [ -n "$el" ]; then
    MI_EL="$el" python3 -c '
import json, io, os, sys
ruta = sys.argv[1]
try:
    with io.open(ruta, encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
d.setdefault("env", {})["ELEVENLABS_API_KEY"] = os.environ["MI_EL"]
tmp = ruta + ".tmp"
with io.open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, ruta)
' "$(cygpath -w "$claude_settings" 2>/dev/null || printf '%s' "$claude_settings")" 2>/dev/null \
      && echo "  guardada." || echo "  no pude guardarla."
  fi

  echo
  echo "Falta instalar lo de la app (una sola vez):"
  echo "   cd app && npm install && npm run empaquetar"

  # Los servicios externos se PIDEN acá, en vez de mandar a leer otro archivo. Antes esta parte
  # decía "está todo explicado en INSTALAR.md", y ese archivo ni siquiera viaja en la version
  # publica: quien clonara el repositorio se encontraba con una referencia a la nada.
  _configurar_mcp

  echo
  echo "Falta el telefono y el acceso remoto (Tailscale), que son tramites aparte:"
  echo "  telefono:  bash mentis-telefono.sh --ayuda"
  echo "  remoto:    https://tailscale.com/download"
  echo
  _revisar
}

# Las credenciales de los servidores MCP van a OTRO archivo: mcp-bridge/.secrets.env, que es de
# donde las lee mcp-bridge/mcp-client.js. Escribirlas en.custom-models-secrets.env seria
# escribirlas donde nadie las busca.
_guardar_secreto_mcp() {
  local nombre="$1" valor="$2"
  local archivo="$MI_HERE/mcp-bridge/.secrets.env"
  mkdir -p "$MI_HERE/mcp-bridge" 2>/dev/null
  if [ ! -f "$archivo" ]; then
    printf '# Credenciales de los servidores MCP -- NO se versiona, NO viaja en las copias.\n' > "$archivo"
    chmod 600 "$archivo" 2>/dev/null || true
  fi
  if grep -q "^${nombre}=" "$archivo" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "^${nombre}=" "$archivo" > "$tmp" && mv -f "$tmp" "$archivo"
  fi
  printf '%s=%s\n' "$nombre" "$valor" >> "$archivo"
  echo "  guardada en mcp-bridge/.secrets.env"
}

# --- Los servicios que se conectan por MCP (2026-08-08) ----------------------------------------
# Antes esta parte no existia: el instalador detectaba que a Google Workspace le faltaban las
# credenciales y te mandaba a leer INSTALAR.md, un archivo que ni siquiera viaja en la version
# publica. "Anda a leer otro documento" no es instalar.
_configurar_mcp() {
  echo
  echo "== Servicios externos (opcionales, se pueden dejar para despues) =="
  echo

  # --- GitHub ---
  echo "GitHub -- para que Mentis pueda leer tus repositorios, buscar codigo y mirar issues."
  echo "  Se saca en: GitHub -> Settings -> Developer settings -> Personal access tokens ->"
  echo "  Tokens (classic) -> Generate new token. Alcanza con marcar 'repo'."
  echo "  (Si solo vas a usar repositorios publicos, con 'public_repo' te sobra.)"
  printf "  Pegá el token (o Enter para saltear): "
  read -r _gh_token
  if [ -n "${_gh_token:-}" ]; then
    _guardar_secreto_mcp "GITHUB_PERSONAL_ACCESS_TOKEN" "$_gh_token"
    # El binario NO viaja en el paquete: pesa 25 MB y hay uno por sistema operativo.
    if [ ! -f "$MI_HERE/mcp-bridge/bin/github-mcp-server.exe" ]; then
      echo "  Falta el programa del servidor. Se baja del release oficial de GitHub:"
      echo "     https://github.com/github/github-mcp-server/releases"
      echo "  Descomprimilo en mcp-bridge/bin/ (ver mcp-bridge/bin/COMO-OBTENER.md)."
    else
      echo "  El servidor ya esta instalado."
    fi
    echo "  Arranca en modo SOLO LECTURA y apagado. Se prende desde Conectores."
  else
    echo "  Salteado."
  fi
  echo

  # --- Google Workspace ---
  echo "Google Workspace -- Drive, Docs, Sheets, Gmail y Calendar."
  echo "  Es el tramite mas largo, pero se hace una sola vez:"
  echo "   1. Entra a https://console.cloud.google.com/ y crea un proyecto."
  echo "   2. En 'APIs y servicios' habilita: Drive, Docs, Sheets, Gmail y Calendar."
  echo "   3. En 'Credenciales' crea un 'ID de cliente de OAuth' de tipo 'Aplicacion de escritorio'."
  echo "   4. Copia el ID y el secreto que te muestra."
  printf "  Pegá el ID de cliente (o Enter para saltear): "
  read -r _g_id
  if [ -n "${_g_id:-}" ]; then
    printf "  Pegá el secreto de cliente: "
    read -r _g_secret
    if [ -n "${_g_secret:-}" ]; then
      _guardar_secreto_mcp "GOOGLE_CLIENT_ID" "$_g_id"
      _guardar_secreto_mcp "GOOGLE_CLIENT_SECRET" "$_g_secret"
      echo "  Listo. La primera vez que lo uses te va a abrir el navegador para dar permiso."
    else
      echo "  Sin el secreto no sirve el ID solo. Salteado."
    fi
  else
    echo "  Salteado."
  fi
  echo

  # --- Gemini ---
  echo "Google Gemini -- como alternativa a los modelos de NVIDIA. VIENE APAGADO."
  echo
  echo "  ANTES DE PONER LA CLAVE, LEE ESTO:"
  echo "  El plan GRATUITO de Google USA LO QUE LE MANDES PARA ENTRENAR SUS MODELOS, y hay"
  echo "  revisores humanos que pueden llegar a leerlo. El plan pago no."
  echo "  Si vas a hablar de cosas privadas -- salud, plata, trabajo, otras personas -- dejalo."
  echo "  NVIDIA sigue siendo el proveedor principal y no hace falta tocar nada."
  echo "  La clave, si la queres, se saca gratis en https://aistudio.google.com"
  printf "  Pegá la clave de Gemini (o Enter para saltear): "
  read -r _gem_key
  if [ -n "${_gem_key:-}" ]; then
    _guardar_secreto "CUSTOM_MODEL_KEY_GEMINI" "$_gem_key"
    echo "  Guardada. Sigue APAGADO: se prende por rol desde la configuracion."
  else
    echo "  Salteado (es lo mas prudente)."
  fi
}

# Las claves de Ideogram, Runway y NASA NO van al settings.json: van a.custom-models-secrets.env,
# que es de donde las leen mentis-image-gen-ideogram.sh, mentis-video-gen-runway.sh y
# mentis-datos.sh. Escribirlas en otro lado es escribirlas en el vacio.
_guardar_secreto() {
  local nombre="$1" valor="$2"
  local archivo="$MI_HERE/.custom-models-secrets.env"
  if [ ! -f "$archivo" ]; then
    printf '# Claves de servicios externos -- NO se versiona.\n' > "$archivo"
    chmod 600 "$archivo" 2>/dev/null || true
  fi
  # Si ya estaba, se reemplaza en vez de duplicar: dos lineas con la misma clave y distinto valor
  # dejan el resultado a merced de cual lea primero el que la busca.
  if grep -q "^${nombre}=" "$archivo" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "^${nombre}=" "$archivo" > "$tmp" && mv -f "$tmp" "$archivo"
  fi
  printf '%s=%s\n' "$nombre" "$valor" >> "$archivo"
  echo "  guardada en.custom-models-secrets.env"
}

# El guard permite `source mentis-instalar.sh` para probar las funciones sueltas sin que el script
# ejecute nada. Sin esto, sourcearlo corria el bloque de abajo, imprimia el uso y mataba el shell
# del test -- que es como se descubrio que hacia falta.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    preparar)   _preparar "${2:-}" ;;
    configurar) _configurar ;;
    revisar)    _revisar ;;
    *) _uso; exit 2 ;;
  esac
fi
