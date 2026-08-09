#!/usr/bin/env bash
# mentis-modelos-guardia.sh -- el chequeo que faltaba: no "¿está vivo?" sino "¿llega a tiempo?".
#
# POR QUE EXISTE (ERR-128, 2026-08-07):
#   carbohidratos con  -- venía respondiendo con un modelo que tardaba 82 y 94
#   SEGUNDOS en emitir el primer token, contra un presupuesto de 18 s. Cada consulta esperaba de
#   gusto y se iba al fallback. Nadie se enteró en tres días.
#
#   Lo importante: ninguna herramienta que ya existía podía verlo.
#     - mentis-modelos.sh pregunta "¿el modelo contesta?". glm-5.2 contestaba. Daba VIVO.
#     - mentis-modelos-reparar.sh es REACTIVO: se dispara cuando un turno real ya falló, y
#       este caso nunca fallaba -- el fallback lo tapaba siempre.
#   El agujero es que "vivo" y "sirve" no son lo mismo. Un modelo puede estar perfectamente vivo
#   y ser inservible para su rol, y eso es invisible salvo que se mida contra el presupuesto.
#
# QUE HACE:
#   Para cada rol, mide el TIEMPO HASTA EL PRIMER TOKEN de su modelo principal y lo compara con
#   lo que ESE rol está dispuesto a esperar. Tres resultados: OK, LENTO (vivo pero fuera de
#   presupuesto) y MUERTO.
#
# QUE NO HACE, A PROPOSITO:
#   NO cambia ni un modelo. Sólo mira y avisa. Es la lección de ERR-119 y ERR-131: lo que mide no
#   escribe. Si hay que cambiar algo, lo hace mentis-modelos-reparar.sh, que tiene los frenos.
#
# Uso:
#   mentis-modelos-guardia.sh              # todos los roles, tabla legible
#   mentis-modelos-guardia.sh -r # un rol
#   mentis-modelos-guardia.sh -q           # silencioso: sólo el resumen (para correr programado)
#   mentis-modelos-guardia.sh -n 3         # N mediciones por modelo (default 2)
#
# Exit: 0 todo OK | 1 hay algún LENTO | 2 hay algún MUERTO.
# Se eligió que MUERTO pese más que LENTO para que un cron pueda distinguirlos por el código.

set -uo pipefail
MG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MG_ENG="$MG_HERE/engine"
MG_ASK="$MG_ENG/ask-nvidia.sh"

# shellcheck source=/dev/null
. "$MG_ENG/nv-lib.sh"        2>/dev/null
# shellcheck source=/dev/null
. "$MG_ENG/nv-modelos-lib.sh" 2>/dev/null

MG_ROL=""; MG_QUIET=0; MG_N=2
while getopts ":r:qn:h" opt; do
  case "$opt" in
    r) MG_ROL="$OPTARG" ;;
    q) MG_QUIET=1 ;;
    n) MG_N="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "opcion invalida: -$OPTARG" >&2; exit 64 ;;
  esac
done

MG_KEY="${NVIDIA_API_KEY:-}"
if [ -z "$MG_KEY" ] && [ -f "$MG_ENG/.nv-secrets" ]; then
  # shellcheck source=/dev/null
. "$MG_ENG/.nv-secrets" 2>/dev/null
  MG_KEY="${NVIDIA_API_KEY:-}"
fi
if [ -z "$MG_KEY" ]; then
  echo "ERROR: no hay NVIDIA_API_KEY (ni en el entorno ni en engine/.nv-secrets)." >&2
  exit 64
fi

# Los roles que de verdad usa una conversación. 'multimodal' queda afuera porque su examen
# necesita imágenes y se mide en otro lado; 'ultra' y 'deep' entran porque aunque se usen poco,
# son los que más caro pagan un modelo caído (presupuestos de 45 s y más).
MG_ROLES="${MG_ROL:-fast extract code general reason deep ultra}"

# --- modelo principal de un rol, con el override YA aplicado -----------------------------------
# Se pregunta por el camino real -- override primero, tabla default después -- porque medir el
# default cuando producción usa otro modelo es medir algo que nadie ejecuta. Ese fue exactamente
# el error de ERR-119: 46 horas midiendo el modelo equivocado.
mg_modelo_de() {
  local rol="$1" linea m
  linea="$(nv_override_rol "$rol" 2>/dev/null)"
  m="${linea%%|*}"
  if [ -n "$m" ] && [ "$m" != "$linea" ]; then printf '%s' "$m"; return 0; fi
  [ -n "$linea" ] && { printf '%s' "$linea"; return 0; }
  # Sin override: sale de la tabla de ask-nvidia.sh, la misma que lee producción.
  # OJO CON LA ARITMETICA: 'NVMODEL="' son 9 caracteres, asi que el contenido empieza en
  # RSTART+9 y mide RLENGTH-10 (los 9 del prefijo mas la comilla final). Con RSTART+10 se pierde
  # la primera letra del vendor y salen cosas como "vidia/nemotron..." o "eta/llama...", que
  # despues dan MUERTO porque ese modelo no existe. Visto en la primera corrida real: los tres
  # roles sin override (fast, deep, ultra) reportaron muerto un modelo que estaba perfecto.
  awk -v rol="$rol" '
    $0 ~ "^[[:space:]]*" rol "\\)" {
      if (match($0, /NVMODEL="[^"]+"/)) { print substr($0, RSTART+9, RLENGTH-10); exit }
    }' "$MG_ASK"
}

total=0; n_ok=0; n_lento=0; n_muerto=0
declare -a MG_PROBLEMAS=()

[ "$MG_QUIET" = "1" ] || {
  printf '%-9s %-44s %9s %9s  %s\n' "ROL" "MODELO PRINCIPAL" "PRESUP." "1er TOKEN" "ESTADO"
  printf '%s\n' "--------------------------------------------------------------------------------------------"
}

for rol in $MG_ROLES; do
  modelo="$(mg_modelo_de "$rol")"
  [ -n "$modelo" ] || continue
  total=$((total+1))

  presup="$(nv_ttft_rol "$rol" "$MG_ASK")"
  [ -n "$presup" ] || presup=18
  presup_ms=$(( presup * 1000 ))

  # Se mide varias veces y se toma el PEOR, no el promedio. Un modelo que a veces tarda 90 s es
  # un modelo que a veces no sirve, y el promedio lo esconde detrás de las corridas buenas.
  peor=0; hubo=0
  for _i in $(seq 1 "$MG_N"); do
    ms="$(nv_probar_ttft "$modelo" "$MG_KEY" "$MG_ENG" 100 2>/dev/null)"
    if [ -n "$ms" ]; then
      hubo=1
      [ "$ms" -gt "$peor" ] 2>/dev/null && peor="$ms"
    fi
  done

  if [ "$hubo" = "0" ]; then
    estado="MUERTO"; n_muerto=$((n_muerto+1)); ttft_txt="sin respuesta"
    MG_PROBLEMAS+=("$rol: '$modelo' NO emitio primer token en 100 s (muerto o saturado)")
  elif [ "$peor" -gt "$presup_ms" ]; then
    estado="LENTO"; n_lento=$((n_lento+1)); ttft_txt="$(printf "%'d" "$peor" 2>/dev/null || echo "$peor") ms"
    MG_PROBLEMAS+=("$rol: '$modelo' tarda ${peor} ms y el rol espera ${presup_ms} ms -- cae al fallback en cada turno")
  else
    estado="ok"; n_ok=$((n_ok+1)); ttft_txt="$(printf "%'d" "$peor" 2>/dev/null || echo "$peor") ms"
  fi

  [ "$MG_QUIET" = "1" ] || printf '%-9s %-44s %8ss %9s  %s\n' "$rol" "$modelo" "$presup" "$ttft_txt" "$estado"
done

[ "$MG_QUIET" = "1" ] || printf '%s\n' "--------------------------------------------------------------------------------------------"

if [ "${#MG_PROBLEMAS[@]}" -gt 0 ]; then
  echo ""
  echo "HAY QUE MIRAR ESTO:"
  for p in "${MG_PROBLEMAS[@]}"; do echo "  - $p"; done
  echo ""
  echo "Nada se cambio solo. Para buscar reemplazo con examen de rol:"
  echo "./mentis-modelos-reparar.sh -r <rol>"
else
  [ "$MG_QUIET" = "1" ] || echo "Los $total roles miden dentro de su presupuesto."
fi

[ "$n_muerto" -gt 0 ] && exit 2
[ "$n_lento" -gt 0 ] && exit 1
exit 0
