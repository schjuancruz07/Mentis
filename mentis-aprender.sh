#!/usr/bin/env bash
# mentis-aprender.sh -- el learning loop con frenos (2026-07-27).
#
# POR QUE EXISTE:
#   Mentis ya aprendia solo, y por eso mismo se envenenaba solo. En un solo dia genero tres
#   memorias falsas sobre el usuario, cada una por un motivo distinto:
#     1. una nacio de una transcripcion ROTA ("decime, quedia y soy por favor") y concluyo que
#        el usuario "valora respuestas extremadamente concisas";
#     2. otra nacio del PROPIO MENSAJE DE ERROR de Mentis ("las tareas se completen con el
#        formato esperado") -- aprendio de si mismo;
#     3. la tercera era una memoria de la memoria anterior (el slug empezaba con "auto-auto-").
#   Ninguna barrera entre observar y creer. Este script es esa barrera.
#
# LAS CINCO REGLAS (en orden de cuanto atajan por lo que cuestan):
#   1. Se aprende SOLO de lo que dijo el usuario, nunca de lo que dijo Mentis. Corta 2 y 3 de raiz.
#   2. No se aprende de turnos que fallaron. La memoria del "formato esperado" nacio de uno.
#   3. No se aprende de transcripciones dudosas (ver mentis-transcribe.sh --confianza). Ataca
#      el caso 1 en su origen: si Mentis no entendio bien, no tiene nada que aprender.
#   4. Antes de crear, se pregunta si ya lo sabe -- por SIGNIFICADO, no por slug. Hoy habia tres
#      memorias diciendo casi lo mismo porque nadie pregunto.
#   5. Nace PROVISIONAL. Se vuelve firme al confirmarse (se repite, o el usuario la confirma), y si no
#      se confirma, caduca sola. Solo las firmes se le inyectan al modelo.
#   6. Una memoria que declara una LIMITACION ("no puedo X", "esta bloqueado") vence en 2 dias,
#      no en 7: las herramientas se arreglan, y una memoria asi impide volver a intentarlo. Salio
#      de un caso real -- Mentis se nego a buscar en la web durante semanas por un bug de UNA
#      linea en el navegador, y como no intentaba nunca descubria que ya funcionaba.
#
# Uso:
#   mentis-aprender.sh destilar <archivo_mensaje_juan> [--turno-fallo] [--confianza N]
#   mentis-aprender.sh confirmar <slug>     -> el usuario la valida a mano: pasa a firme
#   mentis-aprender.sh caducar              -> borra provisionales vencidas
#   mentis-aprender.sh estado               -> que hay firme, que hay provisional
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ":$PATH:" in
  *:/usr/bin:*) : ;;
  *) PATH="/usr/bin:/bin:$PATH"; export PATH ;;
esac

MEMDIR="${MENTIS_MEMDIR:-$HERE/memoria}"
INDEX="$MEMDIR/indice.md"
# Dias que sobrevive una memoria provisional sin confirmarse. Corto a proposito: si un rasgo de
# el usuario es real, va a volver a aparecer en una semana. Si no volvio a aparecer, no era un rasgo.
DIAS_CADUCIDAD="${MENTIS_MEM_CADUCIDAD:-7}"
# Confianza minima de la transcripcion (avg_logprob de Whisper, negativo; mas cerca de 0 = mejor)
CONFIANZA_MINIMA="${MENTIS_MEM_CONFIANZA_MIN:--0.75}"

_estado_de() {            # imprime 'firme' | 'provisional' | '' (no existe)
  local f="$MEMDIR/$1.md"
  [ -f "$f" ] || { printf ''; return; }
  grep -m1 '^estado:' "$f" 2>/dev/null | sed 's/^estado: *//' | tr -d '\r'
}

_visto_de() {
  local f="$MEMDIR/$1.md"
  [ -f "$f" ] || { printf '0'; return; }
  local v; v="$(grep -m1 '^visto:' "$f" 2>/dev/null | sed 's/^visto: *//' | tr -d '\r ')"
  printf '%s' "${v:-1}"
}

case "${1:-}" in

  destilar)
    ARCHIVO="${2:-}"
    TURNO_FALLO=0; CONFIANZA=""
    shift 2 2>/dev/null || true
    while [ $# -gt 0 ]; do
      case "$1" in
        --turno-fallo) TURNO_FALLO=1 ;;
        --confianza)   CONFIANZA="${2:-}"; shift ;;
      esac
      shift
    done
    [ -f "$ARCHIVO" ] || { echo "ERROR: falta el archivo con el mensaje del usuario" >&2; exit 2; }

    # --- REGLA 2: de un turno que fallo no se aprende nada ---------------------------------
    if [ "$TURNO_FALLO" = "1" ]; then
      echo "no-aprendo: el turno fallo (regla 2)" >&2
      exit 0
    fi

    # --- REGLA 3: de una transcripcion dudosa tampoco ---------------------------------------
    if [ -n "$CONFIANZA" ]; then
      if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" \
           "$CONFIANZA" "$CONFIANZA_MINIMA" 2>/dev/null; then
        echo "no-aprendo: transcripcion de baja confianza ($CONFIANZA < $CONFIANZA_MINIMA) (regla 3)" >&2
        exit 0
      fi
    fi

    MSG="$(cat "$ARCHIVO")"
    [ -z "${MSG// }" ] && exit 0

    # --- REGLA 1: al destilador SOLO le llega lo que dijo el usuario ------------------------------
    # La respuesta de Mentis no se pasa ni como contexto. Es lo que hace imposible que Mentis
    # aprenda de si mismo, que fue el origen de dos de las tres memorias falsas.
    MEM_PROMPT="Esto es un mensaje que el usuario le escribio a su asistente. ¿Dice algo que valga la pena recordar PERMANENTEMENTE sobre el usuario o sus proyectos: una preferencia suya, una correccion de como quiere que se trabaje, una decision de proyecto, un dato de referencia estable?

Mensaje del usuario:
$MSG

Reglas para responder:
- Si es charla casual, una pregunta puntual, o un pedido que no revela nada duradero sobre el usuario: respondé EXACTAMENTE NADA.
- Si el mensaje parece mal transcripto o no se entiende: respondé EXACTAMENTE NADA.
- No deduzcas rasgos de personalidad a partir de UN mensaje corto.
- El hecho tiene que estar DICHO por el usuario, no inferido de lo que vos supongas.

Si hay algo memorable, respondé en EXACTAMENTE 3 lineas y nada mas:
TIPO: user|feedback|project|reference
NOMBRE: slug-corto-en-minusculas-con-guiones
CONTENIDO: una o dos oraciones con el hecho concreto."

    RESP="$(printf '%s' "$MEM_PROMPT" | bash "$HERE/engine/ask-nvidia.sh" -r extract 2>/dev/null)"
    [ -z "${RESP// }" ] && exit 0
    printf '%s' "$RESP" | grep -qi '^[[:space:]]*NADA' && exit 0

    TIPO="$(printf '%s' "$RESP" | grep -i '^TIPO:' | head -1 | sed 's/^[Tt][Ii][Pp][Oo]: *//' | tr -d '\r')"
    NOMBRE="$(printf '%s' "$RESP" | grep -i '^NOMBRE:' | head -1 | sed 's/^[Nn][Oo][Mm][Bb][Rr][Ee]: *//' | tr -d '\r')"
    CONTENIDO="$(printf '%s' "$RESP" | grep -i '^CONTENIDO:' | head -1 | sed 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Ii][Dd][Oo]: *//' | tr -d '\r')"
    if [ -z "$TIPO" ] || [ -z "$NOMBRE" ] || [ -z "$CONTENIDO" ]; then exit 0; fi

    # Nunca aprender DE una memoria: un slug que ya empieza con auto- indica que el destilador
    # esta masticando algo que el mismo escribio (asi nacio "auto-auto-...").
    case "$NOMBRE" in auto-*|auto_*) echo "no-aprendo: el slug sale de otra memoria (regla 1)" >&2; exit 0 ;; esac
    SLUG="auto-$(printf '%s' "$NOMBRE" | tr -cs 'a-zA-Z0-9-' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40 | sed 's/^-*//;s/-*$//')"

    # --- REGLA 4: ¿ya lo sabe? Se pregunta por SIGNIFICADO ---------------------------------
    YA="$(bash "$HERE/mentis-recordar.sh" --memorias "$CONTENIDO" 2>/dev/null | head -1)"
    SLUG_PARECIDO="$(printf '%s' "$YA" | sed -n 's/^\([a-z0-9-]*\)\.md.*/\1/p')"
    if [ -n "$SLUG_PARECIDO" ] && [ -f "$MEMDIR/$SLUG_PARECIDO.md" ]; then
      # --- REGLA 5: verla de nuevo es la CONFIRMACION que la vuelve firme ------------------
      VISTO=$(( $(_visto_de "$SLUG_PARECIDO") + 1 ))
      python3 "$HERE/engine/memoria_estado.py" --archivo "$MEMDIR/$SLUG_PARECIDO.md" \
        --visto "$VISTO" $( [ "$VISTO" -ge 2 ] && echo "--estado firme" ) >/dev/null 2>&1
      echo "confirmada: $SLUG_PARECIDO (visto $VISTO)" >&2
      exit 0
    fi

    # --- REGLA 6: las limitaciones tecnicas NO son permanentes ------------------------------
    # Esta regla nacio de un caso real (2026-07-27): Mentis guardo "la busqueda web esta
    # bloqueada por CAPTCHAs" y durante SEMANAS se nego a intentar buscar. La causa verdadera
    # era un bug de UNA linea en el navegador (openUrl sacaba la foto de la pagina antes de que
    # terminara de cargar). Como no intentaba, nunca descubria que ya podia: la memoria se
    # cumplia sola.
    # Un hecho sobre el usuario ("prefiere respuestas cortas") no caduca. Un hecho sobre el ESTADO DE
    # UNA HERRAMIENTA caduca siempre, porque las herramientas se arreglan. Se marca aparte para
    # que venza rapido y se vuelva a comprobar en vez de darse por sabido para siempre.
    ES_LIMITACION=0
    case "$(printf '%s' "$CONTENIDO" | tr '[:upper:]' '[:lower:]')" in
      *"no puedo"*|*"no funciona"*|*"esta bloquead"*|*"está bloquead"*|*"no hay acceso"*|\
      *"no esta disponible"*|*"no está disponible"*|*"sin instalar"*|*"no se puede"*|*"fall"*)
        ES_LIMITACION=1 ;;
    esac

    # --- REGLA 5: nace PROVISIONAL --------------------------------------------------------
    bash "$HERE/mentis-memory.sh" save "$TIPO" "$SLUG" "$CONTENIDO" "$CONTENIDO" >/dev/null 2>&1 || exit 0
    if [ "$ES_LIMITACION" = "1" ]; then
      python3 "$HERE/engine/memoria_estado.py" --archivo "$MEMDIR/$SLUG.md" \
        --estado provisional --visto 1 --limitacion si \
        --origen "limitacion observada $(date '+%Y-%m-%d %H:%M') -- volver a comprobarla antes de darla por cierta" >/dev/null 2>&1
      echo "nueva (limitacion, caduca pronto): $SLUG" >&2
    else
      python3 "$HERE/engine/memoria_estado.py" --archivo "$MEMDIR/$SLUG.md" \
        --estado provisional --visto 1 --origen "conversacion $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1
      echo "nueva (provisional): $SLUG" >&2
    fi
    ;;

  confirmar)
    SLUG="${2:-}"; [ -n "$SLUG" ] || { echo "Uso: mentis-aprender.sh confirmar <slug>" >&2; exit 2; }
    [ -f "$MEMDIR/$SLUG.md" ] || { echo "ERROR: no existe la memoria '$SLUG'" >&2; exit 1; }
    python3 "$HERE/engine/memoria_estado.py" --archivo "$MEMDIR/$SLUG.md" --estado firme --visto 99
    echo "firme: $SLUG"
    ;;

  caducar)
    BORRADAS=0
    for f in "$MEMDIR"/*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in indice.md) continue ;; esac
      [ "$(grep -m1 '^estado:' "$f" 2>/dev/null | sed 's/^estado: *//' | tr -d '\r')" = "provisional" ] || continue
      # REGLA 6: una limitacion tecnica vence mucho antes que un hecho sobre el usuario. Una
      # herramienta rota se arregla; una memoria que dice "no puedo" impide volver a intentarlo
      # y se cumple sola.
      LIMITE="$DIAS_CADUCIDAD"
      if grep -q '^limitacion: si' "$f" 2>/dev/null; then
        LIMITE="${MENTIS_MEM_CADUCIDAD_LIMITACION:-2}"
      fi
      # date -r: mtime. Una provisional que nadie confirmo en N dias no era un rasgo real.
      EDAD_DIAS=$(( ( $(date +%s) - $(date -r "$f" +%s 2>/dev/null || date +%s) ) / 86400 ))
      if [ "$EDAD_DIAS" -ge "$LIMITE" ]; then
        SLUG="$(basename "$f".md)"
        rm -f "$f"
        grep -v "^- \[$SLUG\]" "$INDEX" > "$INDEX.tmp" 2>/dev/null && mv "$INDEX.tmp" "$INDEX"
        echo "caducada: $SLUG (${EDAD_DIAS}d sin confirmarse)"
        BORRADAS=$((BORRADAS+1))
      fi
    done
    echo "$BORRADAS provisional(es) caducada(s)"
    ;;

  estado)
    FIRMES=0; PROVI=0; VIEJAS=0
    for f in "$MEMDIR"/*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in indice.md) continue ;; esac
      case "$(grep -m1 '^estado:' "$f" 2>/dev/null | sed 's/^estado: *//' | tr -d '\r')" in
        firme)       FIRMES=$((FIRMES+1)) ;;
        provisional) PROVI=$((PROVI+1)) ;;
        *)           VIEJAS=$((VIEJAS+1)) ;;
      esac
    done
    echo "firmes:       $FIRMES  (son las unicas que se le inyectan al modelo)"
    echo "provisionales: $PROVI  (caducan a los $DIAS_CADUCIDAD dias si no se confirman)"
    echo "sin estado:    $VIEJAS  (anteriores a este sistema; se tratan como firmes)"
    ;;

  *)
    echo "Uso: mentis-aprender.sh {destilar <archivo> [--turno-fallo] [--confianza N]|confirmar <slug>|caducar|estado}" >&2
    exit 2
    ;;
esac
