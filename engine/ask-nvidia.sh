#!/usr/bin/env bash
# ask-nvidia.sh — Consulta modelos de apoyo de NVIDIA NIM (API gratis).
#
# Uso:  ask-nvidia.sh [opciones] <rol|model_id> "prompt"   (prompt tambien por stdin)
# Roles: code | reason | deep | ultra | general | extract | multimodal | | fast
# (esta lista se desincronizo dos veces del `case` de abajo -- 'deep' y 'extract' seguian
#  nombrando modelos que ya no usaban. El `case "$ROLE"` es la fuente de verdad; para ver el
#  estado REAL de cada uno, correr mentis-modelos.sh, que lo parsea de ahi y lo prueba de verdad.)
#   code        -> z-ai/glm-5.2                        (codigo; flagship agentico+coding, 8d)
#   reason      -> deepseek-ai/deepseek-v4-pro          (razonamiento rapido, 1M ctx)
#   deep        -> nvidia/nemotron-3-super-120b-a12b    (razonamiento profundo; 5/5 y 13x mas rapido que mistral)
#   ultra       -> nvidia/nemotron-3-ultra-550b-a55b    (razonamiento maximo, thinking; key dedicada)
#   general     -> deepseek-ai/deepseek-v4-pro          (generalista / segunda opinion)
#   extract     -> deepseek-ai/deepseek-v4-pro          (extraccion estructurada, temp baja)
#   multimodal  -> minimaxai/minimax-m3                 (imagenes/video; lento)
#   -> deepseek-ai/deepseek-v4-pro          (conteo de carbohidratos,  del usuario)
#   fast        -> meta/llama-3.1-8b-instruct           ("cerebro rapido": saludos/confirmaciones
#                                                        cortas SOLO, smoke-test real confirmado
#                                                        830-1200ms vs 1.6-7.5s de deepseek-v4-pro)
#
# Opciones:
#   -o <archivo>  guarda la respuesta COMPLETA en <archivo> y por stdout devuelve solo un preview.
#   -n <N>        lineas de preview (default 12).
#   -b <N>        reasoning_budget para 'ultra' (default 16384).
#   -r            modo "raw": sin system prompt de rol (mantiene el expertise de -k).
#   -R            auto-refinado: el modelo se autocritica y devuelve una version mejorada (1 pasada extra).
#   -k <skill>    inyecta el expertise de una skill (acumulable). Perfiles: frontend, ux, brand-sch, copy.
#   -I <imagen>   adjunta una IMAGEN (png/jpg/webp/gif) como entrada multimodal (acumulable; rol 'multimodal').
#                 Se envia como data-URI base64; solo la "ven" modelos de vision.
#   -j            salida ESTRUCTURADA (contrato #11): RESULTADO/CONFIANZA/SUPUESTOS/RIESGOS.
#                 Por stdout devuelve un RESUMEN DETERMINISTA (#3) de esos campos (sin gastar otro modelo).
#   -q            con -j, resumen ultra-conciso (RESULTADO recortado a preview). Con -o, completo al archivo.
#   -P            desactiva el guard de privacidad (#12). Por defecto SE enmascaran secretos antes del envio.
#   -N            desactiva el ROUTER por salud (#1). Por defecto, si el modelo del rol viene
#                 degradado en la telemetria, se arranca directo por su fallback (evita el timeout).
#
# Robustez: techo de tiempo GENEROSO por rol (NVTO, ver la tabla) y un modelo de FALLBACK por rol.
# El techo no esta para apurar al modelo -- esta para que un principal que se cuelga (free tier
# saturado: acepta la conexion y no contesta nunca) caiga al fallback en vez de dejar a Mentis
# mudo para siempre. Con NVTO=0, que era el default de todos los roles, eso no pasaba nunca.
# Telemetria (#4): cada llamada se registra en logs/nv.jsonl (modelo, latencia, exit, fallback, intentos).
# Privacidad (#12): claves/tokens/emails/CUIT/CBU se enmascaran antes de salir al endpoint (salvo -P).
#
# Principio: el razonamiento interno del modelo NO vuelve al invocador (se descarta), asi que se deja
# AMPLIO (mejor calidad, gratis); solo se controla el formato final. Nunca se omite lo critico.
set -euo pipefail

URL="https://integrate.api.nvidia.com/v1/chat/completions"
# Copia inmutable de la URL de NVIDIA. $URL se pisa cuando el rol usa un proveedor externo
# (ver el bloque de modelos personalizados); esta es la que se restaura para volver a los
# fallbacks, que siempre son de NVIDIA. Ver el comentario largo arriba de generate().
URL_NVIDIA="$URL"
SETTINGS="$HOME/.claude/settings.json"

# --- libreria comun (rutas MSYS, privacidad, telemetria, contrato estructurado) ---
NVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"

# --- opciones ---
PREVIEW=12; OUTFILE=""; RAW=0; UBUDGET=16384; KSKILLS=(); REFINE=0; STRUCT=0; QUIET=0; REDACT=1; ROUTER=1; FILES=(); IMGS=(); IMGFILE=""
while getopts ":o:n:b:k:f:I:rRjqPN" opt; do
  case "$opt" in
    o) OUTFILE="$OPTARG" ;;
    n) PREVIEW="$OPTARG" ;;
    b) UBUDGET="$OPTARG" ;;
    k) KSKILLS+=("$OPTARG") ;;
    f) FILES+=("$OPTARG") ;;
    I) IMGS+=("$OPTARG") ;;
    r) RAW=1 ;;
    R) REFINE=1 ;;
    j) STRUCT=1 ;;
    q) QUIET=1 ;;
    P) REDACT=0 ;;
    N) ROUTER=0 ;;
    *) echo "ERROR: opcion invalida -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))
export NV_REDACT="$REDACT"

# --- expertise de skills a inyectar (-k, acumulable): perfil curado -> fallback SKILL.md ---
strip_fm() { awk 'NR==1 && /^---/{f=1;next} f && /^---/{f=0;next} !f{print}'; }
SKILLTEXT=""
for ks in "${KSKILLS[@]:-}"; do
  [ -z "$ks" ] && continue
  prof="$NVDIR/skill-profiles/$ks.md"
  if [ -f "$prof" ]; then
    txt="$(cat "$prof")"
  else
    sk="$(find "$HOME/.claude" -ipath "*/$ks/SKILL.md" 2>/dev/null | head -1)"
    if [ -n "$sk" ]; then
      txt="$(strip_fm < "$sk" | head -c 6000)"
    else
      echo "AVISO: skill '$ks' no encontrada (ni perfil curado ni SKILL.md); se ignora." >&2
      txt=""
    fi
  fi
  [ -n "$txt" ] && SKILLTEXT="${SKILLTEXT}${txt}"$'\n\n'
done

# --- API key principal ---
KEY="${NVIDIA_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SETTINGS" ]; then KEY="$(nv_read_setting NVIDIA_API_KEY)"; fi
[ -z "$KEY" ] && { echo "ERROR: falta NVIDIA_API_KEY (ni en env ni en settings.json)" >&2; exit 1; }

# Fecha y hora reales (2026-07-28): el modelo no tiene reloj y, si le preguntan, INVENTA la hora
# con total aplomo (bug real: "Son las 14:45, el usuario" cuando eran las 14:32). Se inyecta SOLO en los
# no la necesitan y solo les gastaria contexto. El TASK que arma mentis-chat.sh la lleva aparte
# (ver _mc_build_task), asi que el camino agentico queda cubierto tambien.
SYS_AHORA=" Ahora mismo es $(nv_ahora_texto), hora local del usuario (Argentina). Ese es el dato REAL: si te pregunta la fecha o la hora, respondé con eso y nunca lo inventes ni digas que no podés saberlo."

# --- system prompts por rol (concision SOLO en el formato; razonar libre; no omitir lo critico) ---
SYS_CODE='Sos un programador experto. Razona internamente todo lo necesario. Devolve SOLO el codigo pedido, sin bloques markdown ni texto fuera del codigo. Si faltan datos, asumi la opcion mas comun y deja los supuestos, edge-cases y advertencias importantes como comentarios dentro del codigo. Nunca omitas informacion critica para la correctitud o seguridad.'
SYS_REASON="Sos un experto en razonamiento. Pensa internamente todo lo que haga falta. En la respuesta final: conclusion en la primera linea y luego solo lo esencial para sostenerla, sin relleno ni repeticion. No recortes matices ni supuestos relevantes.${SYS_AHORA}"
SYS_GENERAL="Sos un asistente experto. Razona lo necesario antes de responder. Responde directo y completo, sin relleno: solo lo que aporta valor.${SYS_AHORA}"
SYS_EXTRACT='Sos un destilador de informacion. Te dan contenido (archivos, logs, codigo) y una pregunta. Devolve UNICAMENTE la informacion relevante a la pregunta, lo mas concisa posible: datos concretos, ubicaciones (archivo:linea si aplica), causa raiz si es un error. Nada de preambulos, resumenes generales ni contexto que no se pidio. Si la respuesta no esta en el contenido, deci exactamente "No esta en el contenido provisto".'
# Conteo de carbohidratos (pedido del usuario, 2026-07-16, tiene ): SOLO estima
# gramos de carbohidratos -- tiene PROHIBIDO calcular o sugerir dosis de , ratios
# /carbohidratos, o cualquier ajuste de tratamiento, porque eso es una decision medica
# que le corresponde al usuario y su equipo medico, no a un modelo de lenguaje.
SYS_CARBS='Sos un nutricionista especializado en conteo de carbohidratos para personas con . Te van a dar la descripcion de una comida y, si esta disponible, su peso o porcion. Estima los gramos de carbohidratos totales de la forma mas precisa posible con tu conocimiento nutricional. Respondé SIEMPRE en este formato exacto: primera linea "Carbohidratos estimados: X g" (un numero concreto, o un rango chico solo si hay incertidumbre real); despues, si la comida tiene varios componentes, un desglose breve por ingrediente; despues una linea de supuestos SOLO si asumiste porciones o preparacion que no te aclararon; y como ultima linea, siempre y textual: "Estimacion aproximada -- no reemplaza el conteo de tu equipo medico." Tenes PROHIBIDO calcular, sugerir o mencionar una dosis de , un ratio /carbohidratos, o cualquier ajuste de tratamiento -- si te lo piden, respondé que eso no lo calculas y que consulte a su equipo medico. No agregues nada mas fuera de este formato.'
# "Cerebro rapido" (pedido del usuario, 2026-07-16): SOLO para saludos/agradecimientos/confirmaciones
# cortas que ya filtro el clasificador (nv_classify_msg, tipo "trivial") -- nunca llega texto con
# una pregunta real o un pedido de herramientas a este rol. Prompt breve a proposito: el modelo
# es chico, y un system prompt largo le come proporcionalmente mas contexto/latencia que a los
# modelos grandes.
# El nombre sale de la configuracion (2026-08-06): cada persona elige como se llama su asistente.
# Va en el PROMPT y no solo en la ventana -- si el prompt siguiera diciendo "Sos Mentis", se
# presentaria como Mentis por mas que la pantalla diga otra cosa, y esa contradiccion es peor que
# no dejar cambiarlo. Devuelve "Mentis" si nadie configuro nada, asi el caso del usuario no cambia.
NOMBRE_IA="$(nv_nombre_ia 2>/dev/null)"; NOMBRE_IA="${NOMBRE_IA:-Mentis}"
SYS_FAST="Sos $NOMBRE_IA, el asistente personal del usuario. Te llega un mensaje corto y trivial (saludo, agradecimiento, confirmacion). Responde en UNA sola linea, corta, natural y cálida, en español rioplatense. No hagas preguntas de vuelta salvo que el mensaje las pida. No expliques nada de mas.${SYS_AHORA}"
# Contrato estructurado (#11): el modelo gestiona el formato en secciones delimitadas.
SYS_STRUCT='Estructura tu respuesta final EXACTAMENTE asi, cada marcador solo en su linea y sin nada antes del primero:
===RESULTADO===
(la respuesta pedida)
===CONFIANZA===
(alta | media | baja)
===SUPUESTOS===
(supuestos que tomaste, o "ninguno")
===RIESGOS===
(riesgos, edge-cases o advertencias, o "ninguno")
No agregues texto fuera de estas cuatro secciones.'

# --- rol -> modelo. NVTO = timeout (s); FBMODEL = fallback si el principal cuelga/falla ---
# NVTO: TODOS los roles estaban en 0 (= curl -m 0 = esperar para siempre), con la idea de
# "priorizar calidad sobre velocidad". El problema es que asi el fallback nunca se dispara por
# cuelgue: run_model solo cae al fallback si la llamada FALLA, y una llamada sin timeout no
# falla nunca. Medido el 2026-07-28 con mentis-modelos.sh: deepseek-v4-pro (principal de reason,
# saturado ("ResourceExhausted: Worker local total request limit reached (296/48)"), no muerto.
# Con NVTO=0 eso no es "tarda un poco mas": es Mentis mudo para siempre, sin caer nunca al
# fallback que tiene al lado esperando. Los techos de abajo son GENEROSOS (un modelo sano
# contesta 4096 tokens en 1-30 s), asi que no recortan calidad: solo convierten un cuelgue
# infinito en una caida al fallback. 'ultra' conserva el techo mas alto porque razona de verdad.
ROLE="${1:-}"; shift || true
NVEXTRA="{}"; NVKEY="$KEY"; SYS=""; FBMODEL=""; FB2MODEL=""
case "$ROLE" in
  # 2026-07-12: modelos actualizados contra el catalogo build.nvidia.com/models (smoke-test
  # real de los 4 candidatos nuevos confirmado antes de wirearlos). z-ai/glm-5.2 es un modelo
  # DISTINTO de glm-5.1 (que si estaba muerto/fuera del catalogo) -- 5.2 esta vivo, con free
  # endpoint, y es lo mas nuevo del catalogo entero (flagship agentico+coding+razonamiento).
  # Diversidad de vendor mantenida entre code/reason/deep/general (glm/deepseek/mistral).
  # MUERTE MASIVA 2026-08-07: 'deepseek-ai/deepseek-v4-pro' Y 'deepseek-ai/deepseek-v4-flash'
  # llegaron a su fin de vida el mismo dia (410 Gone, 2026-08-07T09:00:00Z). Sobrevive SOLO el
  # alias con fecha: 'deepseek-ai/deepseek-v4-flash-0731'. Si alguna vez volves a ver un 410 en
  # masa, probá el mismo modelo con sufijo antes de darlo por perdido.
  # Y en la misma revision cayo z-ai/glm-5.2 de todos los puestos de PRINCIPAL: sigue vivo, pero
  # medido dos veces ese dia tarda 82.510 y 93.820 ms hasta el primer token. Ningun rol lo espera
  # tanto. Queda solo donde un respaldo lentisimo es mejor que ninguno.
  code)       NVMODEL="deepseek-ai/deepseek-v4-flash-0731";     NVMAX=4096;  NVTEMP=0.2; NVTO=120;  SYS="$SYS_CODE";    FBMODEL="nvidia/nemotron-3-nano-30b-a3b"; FB2MODEL="nvidia/nemotron-3-super-120b-a12b" ;;
  reason)     NVMODEL="nvidia/nemotron-3-ultra-550b-a55b";      NVMAX=4096;  NVTEMP=0.6; NVTO=120;  SYS="$SYS_REASON";  FBMODEL="deepseek-ai/deepseek-v4-flash-0731"; FB2MODEL="nvidia/nemotron-3-super-120b-a12b" ;;
  # 2026-07-25: 'deep' pasa de mistral-medium-3.5 a nemotron-3-super-120b. No es por catalogo
  # (ERR-003: el catalogo miente -- kimi-k2.6 figura listado y da "Not found for account"), es
  # por medicion propia contra 5 problemas de razonamiento con respuesta verificable:
  #     mistral-medium-3.5-128b   2/5 correctas   57.8 s promedio
  #     nemotron-3-super-120b     5/5 correctas    4.4 s promedio
  # Trece veces mas rapido y mas del doble de aciertos. Mistral queda de fallback: sigue siendo
  # un vendor distinto, que es lo que le da diversidad real al ensemble de nv-verify.sh.
  deep)       NVMODEL="nvidia/nemotron-3-super-120b-a12b";      NVMAX=4096;  NVTEMP=0.6; NVTO=240;  SYS="$SYS_REASON";  FBMODEL="deepseek-ai/deepseek-v4-flash-0731"; FB2MODEL="nvidia/nemotron-3-nano-30b-a3b" ;;
  ultra)      NVMODEL="nvidia/nemotron-3-ultra-550b-a55b";      NVMAX=16384; NVTEMP=1.0; NVTO=600; SYS="$SYS_REASON";  FBMODEL="deepseek-ai/deepseek-v4-flash-0731"; FB2MODEL="nvidia/nemotron-3-super-120b-a12b"
              NVEXTRA="$(NVB="$UBUDGET" python3 -c 'import json,os;print(json.dumps({"chat_template_kwargs":{"enable_thinking":True},"reasoning_budget":int(os.environ["NVB"])}))')"
              NVKEY="${NVIDIA_API_KEY_NEMOTRON:-}"
              [ -z "$NVKEY" ] && [ -f "$SETTINGS" ] && NVKEY="$(nv_read_setting NVIDIA_API_KEY_NEMOTRON)"
              [ -z "$NVKEY" ] && NVKEY="$KEY" ;;
  # OJO: minimax-m3 quedo descartado como primario aca -- figura VIVO en el catalogo pero es
  # LENTO por diseno. "vivo" en el catalogo no es lo mismo que "rapido". general reusa el
  # modelo de reason (deepseek, confirmado rapido) -- ensemble pierde algo de diversidad de
  # modelo pero el SYS_GENERAL/temp distinto igual da una mirada distinta.
  general)    NVMODEL="nvidia/nemotron-3-super-120b-a12b";      NVMAX=4096;  NVTEMP=0.6; NVTO=120;  SYS="$SYS_GENERAL"; FBMODEL="deepseek-ai/deepseek-v4-flash-0731"; FB2MODEL="nvidia/nemotron-3-nano-30b-a3b" ;;
  # 'qwen/qwen3.5-397b-a17b' llego a su FIN DE VIDA el 2026-07-27 y NVIDIA responde 410 Gone.
  # El fallback salvaba la respuesta, pero cada llamada tardaba ~3 MINUTOS: primero agotaba el
  # intento contra el modelo muerto. Se promueve el fallback, que ya venia respondiendo bien.
  extract)    NVMODEL="nvidia/nemotron-3-nano-30b-a3b";         NVMAX=4096;  NVTEMP=0.1; NVTO=120;  SYS="$SYS_EXTRACT"; FBMODEL="nvidia/nemotron-3-super-120b-a12b"; FB2MODEL="deepseek-ai/deepseek-v4-flash-0731" ;;
  multimodal) NVMODEL="minimaxai/minimax-m3";                   NVMAX=4096;  NVTEMP=0.6; NVTO=300; SYS="$SYS_GENERAL"; FBMODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" ;;
  # Conteo de carbohidratos (pedido del usuario, 2026-07-16): mismo modelo que 'reason' (deepseek,
  # confirmado rapido), temp baja para estimaciones consistentes. SYS_CARBS ya trae prohibido
  # el calculo de dosis de  -- ver comentario junto a la definicion del prompt.
  # Smoke-test real 2026-07-16 contra el catalogo (protocolo obligatorio antes de wirear un rol
  # nuevo, ver comentario de code/reason mas arriba): mistral-7b-instruct-v0.3 (404, muerto),
  # mistral-nemo-12b-instruct (404, muerto), microsoft/phi-4-mini-instruct (410, EOL 2026-07-15),
  # google/gemma-2-9b-it (404, muerto), nvidia/nemotron-3-nano-30b-a3b (vivo pero es un modelo de
  # razonamiento, quema tokens pensando incluso en "hola" -- no sirve para "rapido"),
  # meta/llama-3.2-3b-instruct (vivo pero MAS LENTO e inestable que el 8b en 3 rondas reales:
  # 1.8-5.5s vs 0.8-1.2s). meta/llama-3.1-8b-instruct gano claro: vivo, 830-1200ms consistente,
  # respuesta limpia sin razonamiento de sobra. Fallback a general (mismo deepseek de siempre)
  # si este llega a caerse -- prioridad ahi es que ANDE, no que sea rapido.
  fast)       NVMODEL="meta/llama-3.1-8b-instruct";            NVMAX=200;   NVTEMP=0.6; NVTO=20;  SYS="$SYS_FAST";     FBMODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"; FB2MODEL="deepseek-ai/deepseek-v4-flash-0731" ;;
  "")         echo "Uso: ask-nvidia.sh [-o archivo] [-n N] [-b N] [-f archivo] [-r] [-R] [-j] [-q] [-P] [-N] [-k skill] <code|reason|deep|ultra|general|extract|multimodal|fast|model_id> \"prompt\"" >&2; exit 1 ;;
  *)          NVMODEL="$ROLE";                                  NVMAX=4096;  NVTEMP=0.6; NVTO=0; SYS="$SYS_GENERAL"; FBMODEL="" ;;
esac

# --- PRESUPUESTOS DE VIDA (2026-08-03) ----------------------------------------------------------
# Reemplazan al timeout total como criterio de corte. El problema del timeout total es que NO
# distingue "esta pensando" de "esta colgado": solo mide reloj. Por eso 120 s por modelo, tres
# modelos en cadena, daban una cola de 303-309 s (p99 medido: 296 s) -- y bajar el numero tampoco
# servia, porque glm-5.2 tarda 64 s en respuestas perfectamente sanas.
#
# Con streaming se mide lo que importa: cuanto hace que no llega un token.
#   NVTTFT  cuanto se espera el PRIMER token. Si no llega, no va a llegar -> al fallback.
#   NVSIL   cuanto silencio se tolera DESPUES de que empezo. Si se callo, se colgo.
#   NVTECHO red de seguridad absoluta.
#
# LOS NUMEROS SALEN DE MEDICION, no de una regla del pulgar (tests/calibrar-streaming.py,
# 2026-08-03, sobre los modelos realmente cableados):
#   peor primer token de un modelo SANO....... 10.136 ms  (nemotron-3-ultra)
#   peor silencio de un modelo SANO...........  8.159 ms  (glm-5.2, en una respuesta buena)
# Un presupuesto de silencio de 5 s -- que suena razonable -- habria matado respuestas sanas de
# glm-5.2. Por eso se mide antes de elegir.
#
# Dos clases, porque no es lo mismo esperar un saludo que esperar que alguien razone:
#   INTERACTIVO   lo que el usuario espera mirando la pantalla.
#   DELIBERATIVO  code/reason/deep/ultra: pueden pensar todo lo que quieran MIENTRAS emitan algo.
# RECALIBRADO 2026-08-06, y el motivo importa mas que los numeros.
#
# Los valores viejos (12 s interactivo) salieron de medir, el 2026-08-03, el peor primer token de
# los modelos de ESE dia -- 10.136 ms -- y redondear. Nadie se pregunto cuanto necesita pensar un
# modelo bueno. El resultado fue tratar la lentitud como si fuera una falla: glm-5.2, que mide
#
# el usuario lo dijo mejor: era como pedirle a un modelo de razonamiento que no razone.
#
# LO QUE MOSTRO LA MEDICION NUEVA (8 rondas x 6 modelos x 2 tipos de prompt, con el primer token
# de CONTENIDO separado del primer token de cualquier tipo -- ver nv_stream.py):
#
#   modelo                        ¿razona?   señal de vida   primer contenido (peor caso)
#   meta/llama-3.1-8b               no            0,9 s              0,9 s
#   nemotron-3-nano-30b             SI            1,5 s              5,1 s
#   nemotron-3-super-120b           SI            2,1 s             12,6 s
#   z-ai/glm-5.2                    no           13,1 s             13,1 s
#   nemotron-3-ultra-550b           SI           37,6 s             39,4 s
#
# Dos conclusiones:
#
#   1. glm-5.2 necesitaba hasta 13,1 s y el presupuesto era 12. Se lo estaba perdiendo POR TRES
#      SEGUNDOS -- y como no emite razonamiento, no tiene forma de avisar que sigue vivo.
#   2. Los que razonan dan señal de vida en 1-2 s aunque el contenido tarde 12-40 s. Para ellos el
#      presupuesto de primer token nunca fue el problema: una vez que hablan, quien manda es el
#      presupuesto de SILENCIO, que corre entre token y token (ver nv_stream.py).
#
# Asi que el arreglo es subir el plazo de la PRIMERA señal, con margen sobre el peor caso medido, y
# acompañarlo con un silencio que aguante la pausa entre "termino de pensar" y "empieza a escribir"
# (medida: hasta 15 s en nemotron-3-ultra).
case "$ROLE" in
  code|reason|deep|ultra)
    # 45 s de señal: nemotron-3-ultra llego a tardar 37,6 s en dar el primer token estando sano.
    NVTTFT="${NV_TTFT:-45}"; NVSIL="${NV_SILENCIO:-45}"; NVTECHO="${NV_TECHO:-$([ "$NVTO" -gt 0 ] 2>/dev/null && echo "$NVTO" || echo 600)}" ;;
  multimodal)
    # minimax-m3 (su fallback) tarda 9,1 s en el primer token y 74 s en total: con presupuesto
    # interactivo se lo cortaria estando sano.
    NVTTFT="${NV_TTFT:-45}"; NVSIL="${NV_SILENCIO:-45}"; NVTECHO="${NV_TECHO:-300}" ;;
  *)
    # 18 s = los 13,1 s peores de glm-5.2 mas margen. Con 12 se lo perdia; con 18 entra siempre y
    # el usuario igual no espera mas de lo que ya esperaba cuando el turno caia al fallback (que le
    # costaba ~21 s y encima le daba la respuesta del suplente).
    NVTTFT="${NV_TTFT:-18}"; NVSIL="${NV_SILENCIO:-25}"; NVTECHO="${NV_TECHO:-90}" ;;
esac

# --- OVERRIDE AUTOMATICO (2026-08-01): la tabla de arriba es el default, no la ultima palabra ---
# Cuando un modelo se muere (404/410), el reparador escribe el reemplazo en modelos-override.json y
# esto lo aplica sin que nadie edite este archivo. Ver nv_override_rol en nv-lib.sh para el porque
# y para el costo (cero si no hay overrides, que es el caso normal).
#
# Va DESPUES del case y ANTES de customModels a proposito: lo que el usuario eligio a mano gana siempre.
# Solo se aplica a los roles con nombre -- si alguien llamo a ask-nvidia.sh con un id de modelo
# suelto (la rama '*'), ya dijo exactamente que queria y no hay nada que sobrescribirle.
case "$ROLE" in
  code|reason|deep|ultra|general|extract|multimodal|fast)
    NVO_LINEA="$(nv_override_rol "$ROLE")"
    if [ -n "$NVO_LINEA" ]; then
      NVO_M="${NVO_LINEA%%|*}"; NVO_RESTO="${NVO_LINEA#*|}"
      NVO_FB="${NVO_RESTO%%|*}"; NVO_FB2="${NVO_RESTO#*|}"
      [ "$QUIET" = "1" ] || echo "AVISO: rol '$ROLE' con modelo reemplazado: '$NVMODEL' -> '$NVO_M' (ver modelos-override.json)." >&2
      NVMODEL="$NVO_M"; FBMODEL="$NVO_FB"; FB2MODEL="$NVO_FB2"
    fi ;;
esac

# Modelos personalizados por rol (pedido del usuario, 2026-07-13, exclusivo de Mentis): SOLO se
# activa si el llamador exporto MENTIS_SETTINGS_FILE (mentis-chat.sh lo hace; nv.sh/nv-once.sh/
# fable5v2j y cualquier otro consumidor de ask-nvidia.sh NO lo tocan, cero riesgo de regresion
# para el resto del ecosistema). Cubre proveedores "openai-compatible" (mismo formato de
# payload que ya arma run_model: OpenAI, Groq, OpenRouter, Ollama/LM Studio local, etc.).
#
# GEMINI (2026-08-07): el comentario que estaba aca decia que Gemini quedaba sin wirear "porque
# tiene formato propio". Se verifico contra la API real y NO es asi: Google expone sus modelos en
# /v1beta/openai/chat/completions con el mismo payload y el mismo SSE, asi que entra por este
# mismo camino sin una linea de parseo nueva. Se acepta provider "gemini" como sinonimo de
# "openai-compatible" para que la config se lea sola. Lo unico propio de Gemini es la cuota
# diaria del tier gratuito, que vive en nv-gemini-lib.sh.
#
# DOS DIFERENCIAS con un custom model cualquiera, y las dos son a proposito:
#   1. NO se borran los fallbacks. Antes, activar un modelo custom hacia FBMODEL=""/FB2MODEL="",
#      o sea que si el custom fallaba el turno se moria. Para Gemini eso es inaceptable: el tier
#      gratuito SE ACABA todos los dias, y el dia que se acaba Mentis tiene que seguir andando.
#      Ahora la cadena de NVIDIA queda intacta abajo, de red.
#   2. Si ya no queda cuota, ni se intenta: se deja el modelo de NVIDIA y listo. Gastar 30 s en
#      un 429 seguro seria pagar la espera dos veces.
if [ -n "${MENTIS_SETTINGS_FILE:-}" ] && [ -f "$MENTIS_SETTINGS_FILE" ]; then
  MC_CUSTOM_JSON="$(MC_ROLE_K="$ROLE" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    cm = (d.get("customModels") or {}).get(os.environ["MC_ROLE_K"])
    prov = (cm or {}).get("provider")
    # "gemini" entra por el mismo camino que "openai-compatible" (ver comentario de arriba).
    if cm and prov in ("openai-compatible", "gemini") and cm.get("baseUrl") and cm.get("model"):
        if not (prov == "gemini" and not cm.get("enabled", False)):
            print(json.dumps(cm))
except Exception:
    pass
' "$MENTIS_SETTINGS_FILE" 2>/dev/null)"
  if [ -n "$MC_CUSTOM_JSON" ]; then
    MC_URL="$(printf '%s' "$MC_CUSTOM_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["baseUrl"])' | tr -d '\r')"
    MC_MODEL="$(printf '%s' "$MC_CUSTOM_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["model"])' | tr -d '\r')"
    MC_KEYREF="$(printf '%s' "$MC_CUSTOM_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("keyRef",""))' | tr -d '\r')"
    MC_PROV="$(printf '%s' "$MC_CUSTOM_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("provider",""))' | tr -d '\r')"
    MC_SECRETS="$(dirname "$MENTIS_SETTINGS_FILE")/.custom-models-secrets.env"
    MC_KEY=""
    if [ -n "$MC_KEYREF" ] && [ -f "$MC_SECRETS" ]; then
      MC_KEY="$(grep "^CUSTOM_MODEL_KEY_${MC_KEYREF}=" "$MC_SECRETS" | head -1 | sed "s/^CUSTOM_MODEL_KEY_${MC_KEYREF}=//" | tr -d '\r')"
    fi
    MC_USAR=1
    if [ "$MC_PROV" = "gemini" ]; then
      # La cuota se consulta ANTES de tocar la red. Si no queda, este bloque no hace nada y el
      # rol sigue con su modelo de NVIDIA como cualquier otro dia.
      [ -f "$NV_HOME/nv-gemini-lib.sh" ] &&. "$NV_HOME/nv-gemini-lib.sh"
      if type -t nv_gemini_hay_cuota >/dev/null 2>&1 && ! nv_gemini_hay_cuota; then
        MC_USAR=0
        [ "$QUIET" = "1" ] || echo "AVISO: Gemini sin cuota por hoy; el rol '$ROLE' sigue con NVIDIA." >&2
      fi
    fi
    if [ -n "$MC_KEY" ] && [ "$MC_USAR" = "1" ]; then
      # Se pisa el PRINCIPAL y se dejan los fallbacks de NVIDIA intactos (ver punto 1 arriba).
      URL="$MC_URL"; NVMODEL="$MC_MODEL"; NVKEY="$MC_KEY"
      [ "$QUIET" = "1" ] || echo "AVISO: usando modelo personalizado para el rol '$ROLE': $NVMODEL en $URL" >&2
      if [ "$MC_PROV" = "gemini" ] && type -t nv_gemini_sumar >/dev/null 2>&1; then
        nv_gemini_sumar
      fi
    fi
  fi
fi

[ "$RAW" = "1" ] && SYS=""
# ROUTER por salud (#1, extendido 2026-07-04): si el modelo del rol viene degradado, busca el
# PRIMER sano en la cadena (fallback o fallback2) y arranca directo por ahi -- antes solo miraba
# un salto, y si el primer fallback tambien estaba degradado se perdian ambos timeouts antes de
# llegar al segundo fallback (bug real: costaba ~60-120s extra por llamada). El degradado no se
# usa ni como respaldo (ya sabemos que esta mal). nv_model_health ya hace reprueba/exploracion.
if [ "$ROUTER" = "1" ] && [ -n "$FBMODEL" ] && [ "$(nv_model_health "$NVMODEL")" = "degraded" ]; then
  # Se restaura la URL junto con la key, por lo mismo que en generate(): si el rol venia con un
  # proveedor externo (Gemini), $URL apunta ahi, y estos reemplazos son SIEMPRE modelos de NVIDIA.
  # Sin esto, el router mandaba "deepseek-ai/..." al servidor de Google y Google contestaba
  # "Please pass a valid API key" -- se perdia el primer salto entero y la respuesta llegaba
  # recien en el segundo. Visto en vivo el 2026-08-07.
  if [ "$(nv_model_health "$FBMODEL")" = "ok" ]; then
    echo "AVISO: router: '$NVMODEL' degradado (telemetria); arranco por '$FBMODEL'." >&2
    NVMODEL="$FBMODEL"; NVKEY="$KEY"; URL="$URL_NVIDIA"; FBMODEL="$FB2MODEL"; FB2MODEL=""
  elif [ -n "$FB2MODEL" ] && [ "$(nv_model_health "$FB2MODEL")" = "ok" ]; then
    echo "AVISO: router: '$NVMODEL' y '$FBMODEL' degradados (telemetria); arranco por '$FB2MODEL'." >&2
    NVMODEL="$FB2MODEL"; NVKEY="$KEY"; URL="$URL_NVIDIA"; FBMODEL=""; FB2MODEL=""
  fi
fi
# -j define el formato; resuelve la contradiccion con SYS_CODE (que pedia "solo codigo").
if [ "$STRUCT" = "1" ]; then
  case "$ROLE" in
    code) SYS="Sos un programador experto. Razona internamente. $SYS_STRUCT (En RESULTADO va SOLO codigo, sin markdown.)" ;;
    *)    SYS="Sos un experto. Razona internamente lo necesario. $SYS_STRUCT" ;;
  esac
fi

# --- prompt: args o stdin ---
if [ "$#" -gt 0 ]; then NVPROMPT="$*"; else NVPROMPT="$(cat)"; fi
# --- input de archivos (#5, -f acumulable): se antepone su contenido al prompt (acotado) ---
NV_FILE_MAX="${NV_FILE_MAX:-200000}"   # cota de bytes por archivo
FILECTX=""
for fp in "${FILES[@]:-}"; do
  [ -z "$fp" ] && continue
  if [ -f "$fp" ]; then
    FILECTX="${FILECTX}=== ARCHIVO: $fp ===
$(head -c "$NV_FILE_MAX" "$fp")

"
  else
    echo "AVISO: archivo '-f $fp' no existe; se ignora." >&2
  fi
done
[ -n "$FILECTX" ] && NVPROMPT="${FILECTX}=== PEDIDO ===
$NVPROMPT"
[ -z "${NVPROMPT// }" ] && { echo "ERROR: prompt vacio" >&2; exit 1; }
# --- guard de privacidad antes de cualquier envio (cubre tambien el contenido de archivos) ---
# Con el camino de streaming la guarda vive DENTRO de nv_stream.py: la llamada suelta a nv_redact
# costaba 1.152 ms por turno (medido con PS4/EPOCHREALTIME el 2026-08-03), y casi todo eso era
# arrancar el interprete, no enmascarar. Por el camino viejo (NV_STREAM_OFF=1) se sigue aplicando
# aca, asi que ningun camino manda nada sin enmascarar.
if [ "${NV_STREAM_OFF:-0}" = "1" ]; then
  NVPROMPT="$(printf '%s' "$NVPROMPT" | nv_redact)"
fi

# --- imagenes (-I, acumulable): cada una -> data-URI base64, una por linea en un tempfile que
# lee el armador del payload. Solo las usan modelos de vision (rol 'multimodal'). ---
if [ "${#IMGS[@]}" -gt 0 ]; then
  IMGFILE="$(mktemp)"; trap 'rm -f "$IMGFILE"' EXIT
  for ip in "${IMGS[@]}"; do
    [ -f "$ip" ] || { echo "AVISO: imagen '-I $ip' no existe; se ignora." >&2; continue; }
    case "${ip,}" in
      *.png) mime=image/png ;; *.jpg|*.jpeg) mime=image/jpeg ;;
      *.webp) mime=image/webp ;; *.gif) mime=image/gif ;;
      *) mime=image/png ;;
    esac
    printf 'data:%s;base64,%s\n' "$mime" "$(base64 -w0 "$ip" 2>/dev/null)" >> "$IMGFILE"
  done
fi
# firma de las imagenes para la clave de cache (si hay)
IMG_SIG=""; [ -n "$IMGFILE" ] && [ -f "$IMGFILE" ] && IMG_SIG="$(python3 -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$IMGFILE" 2>/dev/null || true)"

# --- parseo de respuesta (exit: 0 ok | 2 transitorio | 3 no-JSON/vacio | 4 definitivo) ---
parse() {
python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: sys.exit(3)
# Gemini devuelve los errores envueltos en una LISTA -- [{"error": {...}}] -- mientras que NVIDIA
# y OpenAI los mandan como objeto suelto. Sin esta linea, d.get("error") tiraba AttributeError y
# el proceso moria con exit 1, un codigo que run_model no clasifica: gastaba un reintento al pedo
# y, por el camino de streaming, el JSON del error terminaba mostrandose como si fuera la
# respuesta del modelo. Medido el 2026-08-07 con un modelo inexistente a proposito.
if isinstance(d, list): d = d[0] if d and isinstance(d[0], dict) else {}
if "choices" in d:
    m=d["choices"][0]["message"]
    c=(m.get("content") or "").strip() or (m.get("reasoning_content") or "").strip()
    if not c: sys.exit(3)
    print(c); sys.exit(0)
st=str((d.get("error") or {}).get("code") or d.get("status") or "")
sys.stderr.write("API: "+json.dumps(d)[:300])
sys.exit(2 if st in ("401","429","500","502","503","504") else 4)
'
}

# --- run_model <prompt> <model> <key> [fallback?]: llama con reintentos, loguea telemetria ---
run_model() {
  local pr="$1" model="$2" key="$3" is_fb="${4:-false}" payload resp out rc attempt t0 t1 ms eff_to
  payload=$(NVMODEL="$model" NVMAX="$NVMAX" NVTEMP="$NVTEMP" NVPROMPT="$pr" NVEXTRA="$NVEXTRA" NVSYS="$SYS" NVSKILL="$SKILLTEXT" NVIMAGES="$IMGFILE" python3 -c '
import json,os
sysparts=[]
if os.environ.get("NVSKILL").strip(): sysparts.append("Aplica rigurosamente el siguiente expertise en tu respuesta:\n\n"+os.environ["NVSKILL"].strip())
if os.environ.get("NVSYS"): sysparts.append(os.environ["NVSYS"])
msgs=[]
if sysparts: msgs.append({"role":"system","content":"\n\n---\n\n".join(sysparts)})
imgf=os.environ.get("NVIMAGES","")
imgs=[]
if imgf and os.path.exists(imgf):
    with open(imgf,encoding="utf-8") as fh:
        imgs=[ln.strip() for ln in fh if ln.strip()]
if imgs:
    content=[{"type":"text","text":os.environ["NVPROMPT"]}]
    for u in imgs: content.append({"type":"image_url","image_url":{"url":u}})
    msgs.append({"role":"user","content":content})
else:
    msgs.append({"role":"user","content":os.environ["NVPROMPT"]})
p={"model":os.environ["NVMODEL"],"messages":msgs,
   "temperature":float(os.environ["NVTEMP"]),"top_p":0.95,
   "max_tokens":int(os.environ["NVMAX"]),"stream":False}
p.update(json.loads(os.environ["NVEXTRA"]))
print(json.dumps(p))')
  eff_to="$NVTO"
  if [ "$NV_BUDGET" -lt "$eff_to" ] 2>/dev/null; then eff_to="$NV_BUDGET"; fi
  # payload va a un archivo temporal (--data-binary @archivo) en vez de "-d $payload": con
  # imagenes adjuntas (-I) el JSON en base64 supera el limite de argv del SO ("Argument list
  # too long"), algo que no pasaba con prompts de solo texto.
  local payload_file; payload_file="$(mktemp)"
  printf '%s' "$payload" > "$payload_file"
  rc=1; attempt=0; t0="$(nv_now_ms)"
  for attempt in 1 2; do
    resp="$(curl -s -m "$eff_to" -H "Expect:" -H "Authorization: Bearer $key" -H "Content-Type: application/json" --data-binary "@$payload_file" "$URL" || true)"
    out="$(printf '%s' "$resp" | parse)"; rc=$?
    [ $rc -eq 0 ] && break
    [ $rc -eq 4 ] && break            # definitivo (404/400): al fallback
    [ $rc -eq 3 ] && break            # timeout/cuelgue: no reintentar el mismo lento -> al fallback
    [ $attempt -lt 2 ] && sleep 1     # solo rc=2 (429/5xx con cuerpo): un reintento
  done
  rm -f "$payload_file"
  t1="$(nv_now_ms)"; ms=$((t1 - t0))
  nv_log rol="$ROLE" modelo="$model" latencia_ms="$ms" exit="$rc" fallback="$is_fb" intentos="$attempt" veredicto=
  [ $rc -ne 0 ] && return 1
  printf '%s' "$out"
}

# --- run_model_stream: el mismo contrato que run_model, por streaming -----------------------------
# Reemplaza TRES procesos (python para armar el JSON + curl + python para parsear) por UNO.
# Medido en esta maquina: arrancar el interprete cuesta ~446 ms y un saludo por el rol 'fast'
# gastaba 4.254 ms de los cuales solo 1.543 ms eran el modelo.
#
# Pero el motivo principal no es ese: es que con streaming se puede saber si el modelo sigue
# VIVO (ver los presupuestos mas arriba) y se puede empezar a mostrar la respuesta antes de que
# termine. Con "stream": false hasta un "hola" se sentia lento -- no tardaba en pensar, tardaba
# en terminar de escribir.
#
# NV_STREAM_OFF=1 vuelve al camino viejo con curl. Es la unica forma de que un problema en
# produccion no dependa de que yo este disponible para arreglarlo.
run_model_stream() {
  local pr="$1" model="$2" key="$3" is_fb="${4:-false}" out rc attempt t0 t1 ms meta_file techo
  techo="$NVTECHO"
  if [ "$NV_BUDGET" -lt "$techo" ] 2>/dev/null && [ "$NV_BUDGET" -gt 0 ] 2>/dev/null; then techo="$NV_BUDGET"; fi
  meta_file="$(mktemp)"
  rc=1; attempt=0; t0="$(nv_now_ms)"
  for attempt in 1 2; do
    # stderr del helper pasa tal cual: NVMETA (metricas) y NVTHINK (razonamiento en vivo).
    # nv-agent.sh y la app ya saben ignorar lineas de servicio. Las metricas ADEMAS se escriben
    # a NV_META_FILE, asi no hace falta interceptar stderr con `tee` -- ese tee costaba dos
    # procesos por llamada (~150 ms en MSYS) para leer una linea que el helper ya tenia escrita.
    out="$(NVMODEL="$model" NVMAX="$NVMAX" NVTEMP="$NVTEMP" NVPROMPT="$pr" NVEXTRA="$NVEXTRA" \
           NVSYS="$SYS" NVSKILL="$SKILLTEXT" NVIMAGES="$IMGFILE" NVKEY="$key" NVURL="$URL" \
           NV_TTFT="$NVTTFT" NV_SILENCIO="$NVSIL" NV_TECHO="$techo" NV_EMITIR="${NV_EMITIR:-0}" \
           NV_ANSWER_STDERR="${NV_ANSWER_STDERR:-0}" \
           NV_META_FILE="$meta_file" \
           python3 "$NVDIR/nv_stream.py")"
    rc=$?
    [ $rc -eq 0 ] && break
    [ $rc -eq 4 ] && break            # definitivo: al fallback
    [ $rc -eq 3 ] && break            # se colgo o se callo: no se reintenta al mismo -> al fallback
    [ $attempt -lt 2 ] && sleep 1     # solo rc=2 (429/5xx/529): un reintento
  done
  t1="$(nv_now_ms)"; ms=$((t1 - t0))
  # ttft_ms es el dato nuevo que antes no existia: separa "tardo en arrancar" de "tardo en
  # escribir". Sin el no se puede saber si un modelo esta saturado o simplemente da respuestas
  # largas, que es la confusion que tenia la telemetria vieja.
  #
  # Se extrae con expansion de bash y no con grep: es una sola linea que ya esta en memoria, y
  # un grep aca serian otros ~76 ms en el camino de cada llamada.
  local meta_linea="" ttft=""
  [ -s "$meta_file" ] && meta_linea="$(<"$meta_file")"
  if [[ "$meta_linea" =~ \"ttft_ms\":[[:space:]]*([0-9]+) ]]; then
    ttft="${BASH_REMATCH[1]}"
  fi
  rm -f "$meta_file"
  nv_log rol="$ROLE" modelo="$model" latencia_ms="$ms" exit="$rc" fallback="$is_fb" intentos="$attempt" ttft_ms="${ttft:-}" veredicto=
  [ $rc -ne 0 ] && return 1
  printf '%s' "$out"
}

# Un solo punto de entrada para el resto del script: asi el interruptor de emergencia vive en un
# lugar y no hay que acordarse de tocarlo en cada llamador.
call_model() {
  if [ "${NV_STREAM_OFF:-0}" = "1" ]; then
    run_model "$@"
  else
    run_model_stream "$@"
  fi
}

# --- generate <prompt>: cadena principal -> fallback -> fallback2 (#6, evita el SPOF de gpt-oss) ---
# --- DISPARADOR DEL REPARADOR (2026-08-01) ------------------------------------------------------
# Cuando el principal de un rol falla, se lanza el reparador EN SEGUNDO PLANO Y DESPRENDIDO. Tres
# cosas que son deliberadas:
#
#   1. NO se decide aca si el modelo esta muerto. Aca solo se sabe "no respondio", que puede ser
#      muerte o saturacion. Decidirlo requiere sondear, y sondear le agregaria segundos al turno
#      del usuario, que esta esperando. El reparador ya sabe distinguir MUERTO de SATURADO y se va
#      solo si no hay nada que hacer, asi que un disparo de mas es barato.
#   2. Se desprende de verdad (nohup + &) y sale de la carpeta antes de arrancar: si heredara el
#      cwd de la app, bloquearia el empaquetado (ERR-106).
#   3. Tiene su propio freno de tiempo. Sin esto, un modelo saturado durante media hora lanzaria
#      un reparador en CADA llamada. El freno de 1-cambio-cada-24h no alcanza para eso: limita los
#      cambios, no las corridas.
_dispara_reparador() {
  [ "${NV_AUTOREPARAR:-1}" = "1" ] || return 0
  local rol="$1" script marca ahora antes
  script="$NVDIR/../mentis-modelos-reparar.sh"
  [ -f "$script" ] || return 0
  marca="$NVDIR/logs/reparar-$rol.ultimo"
  ahora="$(date +%s)"
  if [ -f "$marca" ]; then
    antes="$(cat "$marca" 2>/dev/null || echo 0)"
    [ $(( ahora - ${antes:-0} )) -lt "${NV_AUTOREPARAR_ESPERA:-1800}" ] && return 0
  fi
  mkdir -p "$NVDIR/logs" 2>/dev/null || true
  echo "$ahora" > "$marca" 2>/dev/null || true
  ( cd "${HOME:-/}" 2>/dev/null || cd /
    nohup bash "$script" -r "$rol" >>"$NVDIR/logs/reparar.log" 2>&1 & ) 2>/dev/null
  echo "AVISO: lanzado el chequeo de reemplazo para el rol '$rol' (en segundo plano, no demora este turno)." >&2
}

# OJO CON $URL AL CAER AL FALLBACK (2026-08-07). $URL es global y la usan run_model (curl) y
# run_model_stream (NVURL). Cuando el principal es de otro proveedor -- Gemini, o cualquier custom
# model -- $URL apunta a ESE proveedor. Los fallbacks, en cambio, son modelos de NVIDIA. Sin
# restaurar la URL, un fallback mandaria "nvidia/nemotron-..." al servidor de Google y fallaria
# siempre, justo en el momento en que mas se lo necesita.
# Antes esto no podia pasar porque activar un custom model borraba los fallbacks; ahora que se
# conservan a proposito (para que Gemini degrade a NVIDIA al quedarse sin cuota), hay que
# devolver la URL a su lugar en cada salto. La key ya se cambiaba bien: $NVKEY para el principal,
# $KEY para los fallbacks.
generate() {
  local r
  if r="$(call_model "$1" "$NVMODEL" "$NVKEY" false)"; then printf '%s' "$r"; return 0; fi
  if [ -n "$FBMODEL" ]; then
    echo "AVISO: '$NVMODEL' no respondio; usando fallback '$FBMODEL'." >&2
    _dispara_reparador "$ROLE"
    URL="$URL_NVIDIA"
    if r="$(call_model "$1" "$FBMODEL" "$KEY" true)"; then printf '%s' "$r"; return 0; fi
  fi
  if [ -n "$FB2MODEL" ]; then
    echo "AVISO: fallback '$FBMODEL' tampoco respondio; usando 2do fallback '$FB2MODEL'." >&2
    URL="$URL_NVIDIA"
    if r="$(call_model "$1" "$FB2MODEL" "$KEY" true)"; then printf '%s' "$r"; return 0; fi
  fi
  echo "ERROR: ni el modelo del rol ni sus fallbacks respondieron." >&2
  return 1
}

# --- CACHE opt-in: solo si NV_CACHE=1 (off por defecto -> comportamiento identico al original).
# Cachea la salida CRUDA del modelo por hash de lo que determina la respuesta (rol, modelo final
# tras router, system, expertise, prompt ya redactado, limites, temp, extra, refine). El formateo
# (-j/-o) se aplica igual despues, sobre cache o fresco. TTL configurable. ---
CACHE_HIT=0; CACHEFILE=""
if [ "${NV_CACHE:-0}" = "1" ]; then
  NV_CACHE_DIR="${NV_CACHE_DIR:-$NVDIR/cache}"; NV_CACHE_TTL="${NV_CACHE_TTL:-86400}"
  mkdir -p "$NV_CACHE_DIR" 2>/dev/null || true
  CKEY="$(printf '%s\x1f' "$ROLE" "$NVMODEL" "$NVMAX" "$NVTEMP" "$NVEXTRA" "$REFINE" "$SYS" "$SKILLTEXT" "$NVPROMPT" "$IMG_SIG" \
          | python3 -c 'import hashlib,sys;print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  [ -n "$CKEY" ] && CACHEFILE="$NV_CACHE_DIR/$CKEY"
  if [ -n "$CACHEFILE" ] && [ -f "$CACHEFILE" ]; then
    age="$(python3 -c 'import os,sys,time;print(int(time.time()-os.path.getmtime(sys.argv[1])))' "$CACHEFILE" 2>/dev/null || echo 999999999)"
    if [ "$age" -lt "$NV_CACHE_TTL" ]; then
      OUT="$(cat "$CACHEFILE")"; CACHE_HIT=1
      echo "AVISO: cache HIT (edad ${age}s); no se llamo al modelo." >&2
    fi
  fi
fi

# --- generar; con -R, pasada extra de auto-critica y mejora ---
if [ "$CACHE_HIT" = "0" ]; then
  OUT="$(generate "$NVPROMPT")" || exit 1
  if [ "$REFINE" = "1" ]; then
    OUT="$(generate "Tarea original:
$NVPROMPT

Primera respuesta producida:
$OUT

Critica internamente esta respuesta: detecta debilidades concretas (correctitud, completitud, claridad, seguridad, estilo) y produce una version mejorada que las corrija. Si la primera ya es optima, devolvela tal cual. Devolve SOLO la version final mejorada, sin tu critica ni preambulos.")" || exit 1
  fi
  # guardar en cache (solo si esta activa y se pudo armar la clave)
  [ "${NV_CACHE:-0}" = "1" ] && [ -n "$CACHEFILE" ] && printf '%s' "$OUT" > "$CACHEFILE" 2>/dev/null || true
fi

# --- salida ---
if [ "$STRUCT" = "1" ]; then
  # estructurada: a archivo va solo RESULTADO completo; a stdout, resumen determinista.
  PARSED="$(printf '%s' "$OUT" | nv_parse_structured)"
  if [ -n "$OUTFILE" ]; then
    printf '%s' "$PARSED" | python3 -c 'import sys,re;r=sys.stdin.read();m=re.search(r"<<<RESULTADO\n(.*?)\nRESULTADO>>>",r,re.S);sys.stdout.write((m.group(1) if m else r).rstrip()+"\n")' > "$OUTFILE"
    printf '%s' "$PARSED" | NV_QUIET="$QUIET" NV_PREVIEW="$PREVIEW" nv_summarize
    echo "...[RESULTADO completo guardado en $OUTFILE]"
  else
    printf '%s' "$PARSED" | NV_QUIET="$QUIET" NV_PREVIEW="$PREVIEW" nv_summarize
  fi
else
  # no estructurada: comportamiento clasico (directo, o archivo + preview).
  if [ -n "$OUTFILE" ]; then
    printf '%s\n' "$OUT" > "$OUTFILE"
    total=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
    printf '%s\n' "$OUT" | head -n "$PREVIEW"
    echo "...[$total lineas totales guardadas en $OUTFILE]"
  elif [ "$QUIET" = "1" ]; then
    printf '%s\n' "$OUT" | head -n "$PREVIEW"
  else
    printf '%s\n' "$OUT"
  fi
fi
