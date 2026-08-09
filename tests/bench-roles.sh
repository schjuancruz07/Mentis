#!/usr/bin/env bash
# bench-roles.sh -- la tabla "rol x modelo x puntaje" de la revision total (2026-08-02).
#
# POR QUE EXISTE:
#   Los benchmarks academicos miden lo que los roles de Mentis NO hacen. Que un modelo saque 78
#   en MMLU no dice nada sobre si sirve para 'extract', cuyo unico trabajo es devolver JSON
#   parseable sin ponerse a conversar. Asi que se mide POR ROL, contra los fixtures de ese rol.
#
#   No reimplementa nada: usa nv_fixtures_de / nv_fixture_aprueba / nv_respuesta_modelo, que ya
#   existian. Lo que agrega es correr la matriz completa (varios modelos candidatos x varios
#   roles) guardando cada caso apenas termina.
#
# POR QUE GUARDA CASO POR CASO:
#   El free tier se satura. Si la corrida se corta a las dos horas y los resultados estuvieran
#   en memoria, se pierde todo. Cada linea se escribe apenas se sabe, y una corrida nueva SALTA
#   lo que ya esta en el archivo -- asi que relanzarlo continua en vez de empezar de cero.
#
# POR QUE reason/deep/ultra comparten examen:
#   Comparten fixtures a proposito (ver nv-fixtures-roles.sh). Correr los tres seria pedir tres
#   veces la misma pregunta al mismo modelo y anotar tres veces la misma respuesta. Se corre
#   'reason' y el resultado vale para los tres; el informe lo dice explicitamente.
#
# Uso:
#   bench-roles.sh -o salida.jsonl [-r rol1,rol2] [-m modelo1,modelo2] [-p pausa_ms]
set -uo pipefail

BR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR_ENG="$BR_HERE/../engine"
# shellcheck source=/dev/null
source "$BR_ENG/nv-lib.sh"
# shellcheck source=/dev/null
source "$BR_ENG/nv-modelos-lib.sh"
# shellcheck source=/dev/null
source "$BR_ENG/nv-fixtures-roles.sh"

export PYTHONIOENCODING=utf-8

BR_OUT=""
# Los roles con examen propio. 'deep' y 'ultra' no estan: comparten el de 'reason' (ver arriba).
# 'multimodal' tampoco: su examen de verdad necesita imagenes (bench-multimodal.sh).
BR_ROLES="fast,extract,code,reason,general"
# Candidatos: los que el censo del 2026-08-02 dio VIVOS. Los SATURADOS quedan afuera a proposito:
# cada llamada a un saturado cuesta 45 s de timeout y no devuelve nada, o sea 45 s de nada por
# caso. Saturado no es muerto -- pero para medir hoy, es igual de inutil.
# Actualizado 2026-08-07: salen 'deepseek-v4-pro' y 'deepseek-v4-flash' (410 Gone, fin de vida ese
# mismo dia a las 09:00) y entra el unico sobreviviente de la familia, 'deepseek-v4-flash-0731'.
# glm-5.2 se queda en la lista A PROPOSITO aunque ese dia midiera 82-94 s al primer token: el bench
# existe para medir, y sacarlo seria decidir por adelantado lo que el bench tiene que descubrir. Si
# sigue lento, que lo diga el numero.
BR_MODELOS="deepseek-ai/deepseek-v4-flash-0731,z-ai/glm-5.2,nvidia/nemotron-3-super-120b-a12b,nvidia/nemotron-3-ultra-550b-a55b,nvidia/nemotron-3-nano-30b-a3b,meta/llama-3.1-8b-instruct"
BR_PAUSA_MS=1500

while getopts ":o:r:m:p:" opt; do
  case "$opt" in
    o) BR_OUT="$OPTARG" ;;
    r) BR_ROLES="$OPTARG" ;;
    m) BR_MODELOS="$OPTARG" ;;
    p) BR_PAUSA_MS="$OPTARG" ;;
    *) echo "Uso: bench-roles.sh -o salida.jsonl [-r roles] [-m modelos] [-p pausa_ms]" >&2; exit 2 ;;
  esac
done

[ -n "$BR_OUT" ] || { echo "Falta -o <salida.jsonl>" >&2; exit 2; }
touch "$BR_OUT"

KEY="${NVIDIA_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HOME/.claude/settings.json" ]; then
  KEY="$(nv_read_setting NVIDIA_API_KEY)"
fi
[ -n "$KEY" ] || { echo "Sin NVIDIA_API_KEY." >&2; exit 1; }

# --- ya_hecho <rol> <modelo> <idx> --------------------------------------------------------------
# Marca de reanudacion. Se busca la clave exacta como texto plano: es O(n) sobre el archivo, pero
# el archivo tiene a lo sumo unos miles de lineas y esto corre una vez por caso, no por token.
#
# BUG REAL, ENCONTRADO EL 2026-08-02 EN LA PRIMERA CORRIDA: esto buscaba '"clave":"...' SIN
# espacio, y json.dumps escribe '"clave": "...' CON espacio. El grep no encontraba nunca nada, o
# sea que la reanudacion no salteaba un solo caso. Una funcion que existia y no servia -- y el
# unico sintoma era que una corrida relanzada tardaba lo mismo que desde cero.
# Ahora la salida se escribe COMPACTA (separators sin espacios), asi el grep -F literal funciona
# y sigue siendo barato. Se acepta tambien la forma vieja para no perder los datos ya escritos.
ya_hecho() {
  grep -qF -e "\"clave\":\"$1|$2|$3\"" -e "\"clave\": \"$1|$2|$3\"" "$BR_OUT" 2>/dev/null
}

BR_TOTAL=0; BR_SALTADOS=0
IFS=',' read -ra BR_RS <<< "$BR_ROLES"
IFS=',' read -ra BR_MS <<< "$BR_MODELOS"

for rol in "${BR_RS[@]}"; do
  # Se leen los fixtures UNA vez por rol y se guardan en un array: nv_fixtures_de es barato, pero
  # releerlo dentro del loop de modelos mezclaria la numeracion si alguien lo edita a mitad de una
  # corrida larga -- y una corrida larga es justo lo que esto hace.
  mapfile -t BR_FIX < <(nv_fixtures_de "$rol")
  [ "${#BR_FIX[@]}" -gt 0 ] || { echo "[bench-roles] rol '$rol' sin fixtures, salteado" >&2; continue; }

  for modelo in "${BR_MS[@]}"; do
    bien=0; total=0; suma_ms=0
    for i in "${!BR_FIX[@]}"; do
      linea="${BR_FIX[$i]}"
      [ -n "$linea" ] || continue
      total=$((total+1))
      if ya_hecho "$rol" "$modelo" "$i"; then
        BR_SALTADOS=$((BR_SALTADOS+1))
        continue
      fi
      prompt="${linea%%|||*}"
      resto="${linea#*|||}"
      tipo="${resto%%|||*}"
      esp="${resto#*|||}"

      # UNA RESPUESTA VACIA NO ES UNA RESPUESTA INCORRECTA, y confundirlas fue el error mas grave
      # de la primera corrida (2026-08-02): 167 de 540 casos volvieron vacios porque el free tier
      # se saturo, y contarlos como reprobaciones hacia que deepseek-v4-pro y glm-5.2 -- que
      # estaban perfectos -- puntuaran 0/15 en cuatro roles enteros. Un mal dia de NVIDIA se leia
      # como un modelo malo, y la tabla habria mandado a cambiar modelos que estaban bien.
      #
      # nv_respuesta_modelo devuelve "" tanto si el modelo contesto vacio como si la llamada
      # fallo, asi que no se puede distinguir mirando el texto. Se hace lo unico honesto:
      # reintentar con espera creciente, y si igual vuelve vacio, anotarlo como ERROR (ok=null)
      # para que quede FUERA del denominador en vez de contar como fallo.
      resp=""; ok="null"; intentos=0
      t0="$(date +%s%N)"
      while [ "$intentos" -lt 3 ]; do
        resp="$(nv_respuesta_modelo "$modelo" "$KEY" "$prompt" 512 0)"
        [ -n "$resp" ] && break
        intentos=$((intentos+1))
        sleep "$((intentos * 8))"
      done
      t1="$(date +%s%N)"
      ms=$(( (t1 - t0) / 1000000 ))

      if [ -n "$resp" ]; then
        if nv_fixture_aprueba "$resp" "$tipo" "$esp"; then ok=1; bien=$((bien+1)); else ok=0; fi
      fi
      suma_ms=$((suma_ms + ms))
      BR_TOTAL=$((BR_TOTAL+1))

      # El JSON se arma con python y no con printf: la respuesta del modelo puede traer comillas,
      # saltos de linea y backslashes, y un printf a mano produciria JSONL invalido justo en los
      # casos mas interesantes (los que fallaron raro).
      BR_ROL="$rol" BR_MOD="$modelo" BR_IDX="$i" BR_OK="$ok" BR_MS="$ms" \
      BR_TIPO="$tipo" BR_ESP="$esp" BR_RESP="$resp" BR_PROMPT="$prompt" \
      python3 -c '
import json, os
crudo = os.environ["BR_OK"]
d = {
  "clave": "%s|%s|%s" % (os.environ["BR_ROL"], os.environ["BR_MOD"], os.environ["BR_IDX"]),
  "rol": os.environ["BR_ROL"], "modelo": os.environ["BR_MOD"],
  "caso": int(os.environ["BR_IDX"]),
  # null = no hubo respuesta (error de transporte o saturacion), NO reprobacion.
  "ok": (None if crudo == "null" else int(crudo)),
  "ms": int(os.environ["BR_MS"]), "tipo": os.environ["BR_TIPO"],
  "esperado": os.environ["BR_ESP"], "prompt": os.environ["BR_PROMPT"][:160],
  "resp": os.environ["BR_RESP"][:300],
}
# separators sin espacios: la marca de reanudacion busca "clave":"..." literal (ver ya_hecho).
print(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
' | tr -d '\r' >> "$BR_OUT"

      case "$ok" in
        1) BR_EST="OK" ;;
        0) BR_EST="FALLO" ;;
        *) BR_EST="SIN RESPUESTA (no cuenta)" ;;
      esac
      echo "[bench-roles] $rol / $modelo / caso $i -> $BR_EST (${ms}ms)" >&2
      # La pausa NO es cortesia: sin ella el free tier empieza a devolver 404 a todo (ERR-108).
      sleep "$(awk "BEGIN{print $BR_PAUSA_MS/1000}")"
    done
    [ "$total" -gt 0 ] && echo "[bench-roles] == $rol / $modelo: $bien/$total nuevos, ${suma_ms}ms totales ==" >&2
  done
done

echo "[bench-roles] listo. $BR_TOTAL casos nuevos, $BR_SALTADOS ya estaban. Salida: $BR_OUT" >&2
