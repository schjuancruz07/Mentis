# CAPABILITY: /boveda | pregunta a Kai Vault (índice semántico de todo el ecosistema Mentis + tu bóveda de notas) -- respuestas citando el archivo de origen. "/boveda salud" = estado de la bóveda de notas. "/boveda reindexar" = reconstruye el índice.
#
# Kai Vault (pedido del usuario, 2026-07-13, "versión completa"): antes indexaba SOLO
# Documents/Mentis/Vault (notas.md) con grep literal. Ahora indexa TODO el ecosistema de
# Mentis (mentis-env + mentis-app) además de la bóveda de notas, con búsqueda semántica REAL
# -- reusa nv-index.sh/nv-search.sh (embeddings NVIDIA nv-embedqa-e5-v5 ya wireados y probados
# en este entorno, RAG local B), no un TF-IDF casero ni grep con sinónimos. Además, mentis-chat.sh
# ahora llama a este script en modo "__lookup__" ANTES de cada turno (ver _mc_kai_vault_lookup)
# -- Kai Vault pasa a ser un paso obligatorio del pipeline, no una skill opcional con prefijo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # raíz de Mentis
TOOLSDIR="$(cd "$HERE/engine" && pwd)"                      # Mentis/engine
VAULT_DIR="$HOME/Documents/Mentis/Vault"
ECOSYSTEM_DIR="$HERE"

mkdir -p "$VAULT_DIR"

# KAI_ULTIMO_ERROR guarda por que fallo la ultima busqueda. Antes esto se tragaba con
# 2>/dev/null y el llamador no tenia forma de distinguir "no hay indice" de "la API se cayo"
# de "no hubo coincidencias" -- los tres terminaban en el mismo "no encontre nada", que ademas
# mandaba a reindexar aunque reindexar tampoco funcionara.
KAI_ULTIMO_ERROR=""
_kai_search_one() {
  local dir="$1" query="$2" topk="$3" salida rc
  salida="$(bash "$TOOLSDIR/nv-search.sh" -k "$topk" -d "$dir" -- "$query" 2>&1)"; rc=$?
  case "$rc" in
    0) printf '%s' "$salida"; return 0 ;;
    3) KAI_ULTIMO_ERROR="no hay indice para $dir (nunca se reindexo, o el indice quedo inconsistente)" ;;
    4) KAI_ULTIMO_ERROR="fallo la API de embeddings: $(printf '%s' "$salida" | head -1)" ;;
    5) KAI_ULTIMO_ERROR="el indice fue creado con OTRO modelo de embeddings -- hay que reindexar" ;;
    *) KAI_ULTIMO_ERROR="$(printf '%s' "$salida" | head -1)" ;;
  esac
  return "$rc"
}

# Busca en AMBOS índices (ecosistema + bóveda de notas) y devuelve los resultados crudos
# combinados -- sin llamar al modelo. Si un índice no existe todavía, nv-search.sh falla
# silenciosamente para ESE índice (no rompe el otro).
#
# MENTIS_CORPUS_DIR (2026-08-12, modo Study): si viene seteada, se busca SOLO ahí y no se toca
# ni el ecosistema ni la bóveda. No es una preferencia sino la definición del modo Study: un
# corpus cerrado que igual recibe el código de Mentis en cada turno no es un corpus cerrado, y
# la cita apuntaría a un archivo que el usuario nunca puso como material de estudio. Es un reemplazo
# y NO una fuente más: por eso corta antes en vez de agregarse a las otras dos.
_kai_search_raw() {
  local query="$1" topk="${2:-4}"
  local eco vault combined=""
  if [ -n "${MENTIS_CORPUS_DIR:-}" ]; then
    if [ ! -d "$MENTIS_CORPUS_DIR" ]; then
      KAI_ULTIMO_ERROR="el corpus de estudio no existe todavia ($MENTIS_CORPUS_DIR): sumale material con '/estudiar sumar <archivo>'"
      printf ''
      return 0
    fi
    _kai_search_one "$MENTIS_CORPUS_DIR" "$query" "$topk"
    return 0
  fi
  eco="$(_kai_search_one "$ECOSYSTEM_DIR" "$query" "$topk")"
  [ -n "${eco// }" ] && combined="$eco"
  if [ -d "$VAULT_DIR" ]; then
    vault="$(_kai_search_one "$VAULT_DIR" "$query" "$topk")"
    if [ -n "${vault// }" ]; then
      combined="${combined:+$combined
}$vault"
    fi
  fi
  printf '%s' "$combined"
}

MODE="${1:-}"

# --- Modo interno (pedido del usuario: Kai Vault "obligatorio antes de cada turno"): mentis-chat.sh
# invoca esto DIRECTO (no vía el dispatcher de prefijos de usuario) antes de armar el prompt.
# Sin síntesis con modelo acá -- solo retrieval, para que sea rápido en cada turno.
if [ "$MODE" = "__lookup__" ]; then
  MSG="${2:-}"
  [ -z "${MSG// }" ] && { printf ''; exit 0; }
  RAW="$(_kai_search_raw "$MSG" 3)"
  if [ -z "${RAW// }" ]; then
    if [ -n "$KAI_ULTIMO_ERROR" ]; then
      # Este texto entra en el prompt de CADA turno: tiene que decirle la verdad al modelo, no
      # dejarlo creyendo que buscó y no había nada. Ese era el agujero -- Kai Vault estuvo roto
      # 8 días y ni Mentis ni el usuario tenían forma de notarlo desde la conversación.
      printf '(Kai Vault NO pudo buscar: %s. No supongas que no hay información sobre el tema: no se pudo consultar el índice.)' "$KAI_ULTIMO_ERROR"
      exit 1
    fi
    printf '(Kai Vault: sin resultados relevantes para este mensaje)'
  else
    printf '%s' "$RAW"
  fi
  exit 0
fi

PREGUNTA="$MODE"

if [ -z "${PREGUNTA// }" ]; then
  echo "Uso: /boveda <pregunta> (busca semánticamente en todo el ecosistema Mentis + tu bóveda de notas en $VAULT_DIR). /boveda salud = estado de la bóveda de notas. /boveda reindexar = reconstruye el índice semántico (corré esto primero si es la primera vez)."
  exit 0
fi

# NO SE REINDEXA DESDE EL TELÉFONO (2026-08-20). /boveda entró a la lista blanca del modo remoto
# porque BUSCAR no escribe nada. Reindexar sí: reconstruye el índice entero del ecosistema, tarda,
# y deja el índice a medio hacer si el celular se va de la WiFi en el medio. La guarda vive acá,
# adentro de la skill, y no en la lista blanca de afuera, porque el que sabe que este subcomando
# escribe es este archivo -- una lista de nombres allá afuera no puede saberlo.
if [ "$PREGUNTA" = "reindexar" ] && [ "${MENTIS_REMOTO:-0}" = "1" ]; then
  echo "Reindexar la bóveda no se puede desde el teléfono: reconstruye el índice entero y se rompe si se corta la conexión. Buscar sí funciona. Corré '/boveda reindexar' desde la computadora."
  exit 0
fi

# --- /boveda reindexar: reconstruye el índice semántico de todo el ecosistema + la bóveda ---
if [ "$PREGUNTA" = "reindexar" ]; then
  # BUG REAL que este bloque tenía y que motivó todo este trabajo (2026-07-26): nv-index.sh no
  # existía (se perdió en el decomisionado del ecosistema `nv` el 2026-07-17), el pipe a `tail`
  # se comía el código de salida, y esto igual cerraba con "Listo. Kai Vault ya puede responder".
  # Ocho días diciendo que funcionaba mientras devolvía siempre "no encontré nada" -- y el
  # watcher de la app dejó 34 KB de "OK" falsos en kai-vault-watch.log. Ahora el resultado que
  # se reporta es el REAL, y el exit code se propaga para que el watcher registre el error.
  echo "Indexando el ecosistema de Mentis ($ECOSYSTEM_DIR)... esto puede tardar según cuántos archivos haya."
  ECO_OUT="$(bash "$TOOLSDIR/nv-index.sh" "$ECOSYSTEM_DIR" 2>&1)"; ECO_RC=$?
  printf '%s\n' "$ECO_OUT" | tail -3
  FALLOS=0
  [ "$ECO_RC" -ne 0 ] && FALLOS=$((FALLOS+1))

  VAULT_RC=0
  if [ -n "$(find "$VAULT_DIR" -maxdepth 1 -name '*.md' -print -quit 2>/dev/null)" ]; then
    echo "Indexando tu bóveda de notas ($VAULT_DIR)..."
    VAULT_OUT="$(bash "$TOOLSDIR/nv-index.sh" -x "md txt" "$VAULT_DIR" 2>&1)"; VAULT_RC=$?
    printf '%s\n' "$VAULT_OUT" | tail -3
    [ "$VAULT_RC" -ne 0 ] && FALLOS=$((FALLOS+1))
  else
    echo "(Bóveda de notas vacía todavía, se salteó -- guardá algo en $VAULT_DIR y volvé a reindexar.)"
  fi

  if [ "$FALLOS" -gt 0 ]; then
    echo "ERROR: el reindexado NO se completó. Kai Vault sigue sin poder responder."
    exit 1
  fi
  CHUNKS="$(printf '%s' "$ECO_OUT" | grep -oE 'chunks=[0-9]+' | tail -1 | cut -d= -f2)"
  echo "Listo: índice reconstruido con ${CHUNKS:-?} fragmentos."
  exit 0
fi

# --- /boveda salud: nota 0-100 + notas huérfanas de la bóveda personal (sin cambios de lógica) ---
if [ "$PREGUNTA" = "salud" ]; then
  # El bloque de abajo (notas huérfanas) mide la BÓVEDA DE NOTAS. Pero el problema real del
  # 2026-07-26 fue que el ÍNDICE estaba muerto y nadie tenía forma de enterarse: "salud" no
  # decía una palabra del índice, que es la pieza que puede romperse en silencio. Ahora se
  # reporta primero, con datos verificables (existe / cuántos fragmentos / de cuándo).
  echo "== Índice semántico =="
  KAI_CLAVE="$(printf '%s|' "$ECOSYSTEM_DIR" "${NV_EMB_MODEL:-nvidia/nemotron-3-embed-1b}" | md5sum | cut -d' ' -f1)"
  KAI_IDX="${NV_INDEXDIR:-$TOOLSDIR/index}/$KAI_CLAVE.jsonl"
  if [ -s "$KAI_IDX" ] && [ -s "${KAI_IDX%.jsonl}.vecs.npy" ]; then
    echo "  Estado: OK"
    echo "  Fragmentos: $(wc -l < "$KAI_IDX" | tr -d ' ')"
    echo "  Última actualización: $(date -r "$KAI_IDX" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    echo "  Modelo: ${NV_EMB_MODEL:-nvidia/nemotron-3-embed-1b}"
    echo "  Archivo: $KAI_IDX"
  else
    echo "  Estado: SIN ÍNDICE -- Kai Vault no puede responder nada todavía."
    echo "  Solución: corré '/boveda reindexar' (y fijate que termine sin ERROR)."
  fi
  echo
  echo "== Bóveda de notas =="

  NOTES="$(find "$VAULT_DIR" -type f -name '*.md' 2>/dev/null)"
  TOTAL=0; HUERFANAS=0; HUERFANAS_LIST=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    TOTAL=$((TOTAL+1))
    BASENAME="$(basename "$f".md)"
    HAS_OUTGOING=0
    grep -q '\[\[' "$f" 2>/dev/null && HAS_OUTGOING=1
    HAS_INCOMING=0
    grep -rlq -- "\[\[$BASENAME\]\]" "$VAULT_DIR" --include="*.md" 2>/dev/null && HAS_INCOMING=1
    if [ "$HAS_OUTGOING" -eq 0 ] && [ "$HAS_INCOMING" -eq 0 ]; then
      HUERFANAS=$((HUERFANAS+1))
      HUERFANAS_LIST="$HUERFANAS_LIST
- $BASENAME"
    fi
  done <<< "$NOTES"

  if [ "$TOTAL" -eq 0 ]; then
    echo "Tu bóveda todavía no tiene notas. Guardá algo en $VAULT_DIR (archivos.md) y volvé a preguntar."
    exit 0
  fi
  SCORE=$(( 100 - (HUERFANAS * 100 / TOTAL) ))
  echo "Salud de la bóveda: $SCORE/100 ($TOTAL notas, $HUERFANAS huérfanas -- sin ningún [[link]] hacia ni desde otra nota)."
  [ -n "$HUERFANAS_LIST" ] && echo "Huérfanas:$HUERFANAS_LIST"
  exit 0
fi

# --- /boveda <pregunta>: búsqueda SEMÁNTICA real (embeddings) en vez de grep de palabras clave ---
MATCHES="$(_kai_search_raw "$PREGUNTA" 6)"

if [ -z "${MATCHES// }" ]; then
  # Se distingue el problema real de la ausencia de resultados. El mensaje viejo decía siempre
  # lo mismo ("no encontré nada, corré /boveda reindexar") aunque la causa fuera que el índice
  # no existía o que la API estaba caída -- y mandaba a un reindexado que tampoco funcionaba.
  if [ -n "$KAI_ULTIMO_ERROR" ]; then
    echo "Kai Vault no pudo buscar: $KAI_ULTIMO_ERROR"
    echo "Probá '/boveda salud' para ver el estado del índice."
    exit 1
  fi
  echo "Busqué y no hay nada relacionado con eso, ni en el código de Mentis ni en tu bóveda de notas."
  exit 0
fi

VPROMPT="Sos Kai Vault, el índice de Mentis: parte de su ecosistema de código/scripts/docs (mentis-env) y la bóveda de notas personales del usuario. Respondé la pregunta usando SOLO los fragmentos de abajo -- nunca inventes ni completes con conocimiento externo. Si la respuesta no está en los fragmentos, decilo explícitamente. Citá el archivo:línea de origen (aparece antes de cada fragmento) para cada afirmación que hagas, así el usuario puede ir directo ahí sin tener que buscar.

FRAGMENTOS ENCONTRADOS (ordenados por relevancia):
$(printf '%s' "$MATCHES" | head -c 8000)

PREGUNTA: $PREGUNTA"

bash "$TOOLSDIR/ask-nvidia.sh" -r reason "$VPROMPT" 2>/dev/null
