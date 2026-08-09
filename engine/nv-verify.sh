#!/usr/bin/env bash
# nv-verify.sh — Tanda 2: orquestador con verificacion (ensemble + juez + loop).
# Convierte "preguntar a un modelo" en "obtener una respuesta PROBADA".
# Reutiliza ask-nvidia.sh como subproceso (hereda privacidad, telemetria y fallback).
#
# Uso:
#   nv-verify.sh [opciones] code "requerimiento"   -> genera codigo y lo VERIFICA ejecutando tests
#   nv-verify.sh [opciones] text "requerimiento"   -> ensemble de modelos + juez que elige/sintetiza
#
# Opciones:
#   -L <python|node|bash>  lenguaje para 'code' (default python)
#   -i <N>                 iteraciones de correccion POR NIVEL de la escalera en 'code' (default 2)
#   -e "<roles>"           ESCALERA barato->caro de autores en 'code' (default "code deep ultra").
#                          Sube de nivel cuando un nivel agota sus intentos. Gobernada por NV_BUDGET.
#   -A <rol>               fija un autor UNICO (desactiva la escalera; = comportamiento Tanda 2).
#   -m "<roles>"           roles del ensemble en 'text' (default "reason deep general")
#   -T <rol>               rol TESTER que genera los asserts; DEBE != autor (default general)
#   -J <rol>               rol JUEZ en 'text' (default general)
#   -o <archivo>           guarda el resultado final completo en <archivo>
#   -q                     salida concisa
#
# REGLA INVARIANTE: autor != verificador. En 'code' los tests los escribe otro modelo (-T),
# nunca el autor; y la aprobacion es OBJETIVA (exit code de un harness de asserts ejecutado en
# sandbox), no opinion. El exit code del codigo crudo del autor NO se usa como prueba (un script
# puede salir 0 con logica rota): solo cuenta el harness de asserts.
set -euo pipefail

NVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$NVDIR/nv-lib.sh"
ASK="$NVDIR/ask-nvidia.sh"

LANG_C="python"; MAXITER=2; MODELS="reason deep general"; ESCALA="code deep ultra"; TESTER="general"; JUDGE="general"; OUTFILE=""; QUIET=0
while getopts ":L:i:m:A:e:T:J:o:q" opt; do
  case "$opt" in
    L) LANG_C="$OPTARG" ;;
    i) MAXITER="$OPTARG" ;;
    m) MODELS="$OPTARG" ;;
    A) ESCALA="$OPTARG" ;;     # autor unico -> escalera de un solo nivel
    e) ESCALA="$OPTARG" ;;
    T) TESTER="$OPTARG" ;;
    J) JUDGE="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    q) QUIET=1 ;;
    *) echo "ERROR: opcion invalida -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))
MODE="${1:-}"; shift || true
REQ="${*:-}"
if [ -z "$MODE" ] || [ -z "${REQ// }" ]; then echo "Uso: nv-verify.sh [opciones] <code|text> \"requerimiento\"" >&2; exit 1; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
START_MS="$(nv_now_ms)"
budget_exceeded() { local now; now="$(nv_now_ms)"; [ $(( (now - START_MS)/1000 )) -ge "$NV_BUDGET" ]; }

# ext y plantilla de asserts por lenguaje
case "$LANG_C" in
  python) EXT=py;  TESTHINT='Escribi asserts de Python. Una falla debe lanzar AssertionError (corta con exit!=0).' ;;
  node|js) EXT=js; TESTHINT='Escribi tests en Node usando require("assert") o process.exit(1) en caso de falla.' ;;
  bash|sh) EXT=sh; TESTHINT='Escribi checks de bash: cada verificacion que falle debe "exit 1".' ;;
  *) echo "ERROR: lenguaje no soportado: $LANG_C" >&2; exit 1 ;;
esac

# ---------- MODO CODE: escalera de autores; cada nivel: autor -> tester(otro) -> sandbox -> loop ----------
run_code() {
  local author tester iter feedback="" test_feedback="" author_code test_code combined onlytest rc mrc out mout verdict="fail"
  local finalfile="$TMP/final.$EXT" used_level=""
  # router-por-calidad (#3): reordenar la escalera por passrate historico (mejor primero).
  # Sin datos de nv-eval, mantiene el orden original. Solo si hay mas de un nivel.
  if [ "$(echo "$ESCALA" | wc -w)" -gt 1 ]; then
    local ranked; ranked="$(nv_rank_roles "$ESCALA" "$LANG_C")"
    [ -n "$ranked" ] && [ "$ranked" != "$ESCALA" ] && { echo "AVISO: router-calidad reordeno la escalera: $ranked" >&2; ESCALA="$ranked"; }
  fi
  for author in $ESCALA; do
    if budget_exceeded; then echo "AVISO: presupuesto de tiempo agotado antes del nivel '$author'." >&2; break; fi
    tester="$TESTER"
    [ "$tester" = "$author" ] && tester="reason"   # garantizar autor != verificador
    used_level="$author"
    for iter in $(seq 1 "$MAXITER"); do
      if budget_exceeded; then echo "AVISO: presupuesto agotado en nivel '$author' iter $iter." >&2; break 2; fi
      # 1) AUTOR genera/corrige (solo definiciones, sin demo ejecutable)
      local aprompt="Requerimiento: $REQ
Lenguaje: $LANG_C. Devolve SOLO definiciones (funciones/clases), sin codigo de demostracion que se ejecute al cargar el archivo, sin prints sueltos, sin markdown."
      [ -n "$feedback" ] && aprompt="$aprompt

La version anterior fallo los tests. Salida del error:
$feedback

Corregi el codigo para que pase. Devolve el codigo completo corregido."
      author_code="$(printf '%s' "$aprompt" | "$ASK" -r "$author" 2>/dev/null)" || { echo "ERROR: autor '$author' no respondio." >&2; break; }
      printf '%s\n' "$author_code" > "$finalfile"
      # 2) TESTER (otro modelo) escribe el harness de asserts asumiendo el codigo ya definido arriba
      local tprompt="Requerimiento: $REQ
Codigo $LANG_C que lo implementa (asumilo YA definido arriba en el mismo archivo; NO lo repitas):
$author_code

Escribi SOLO un bloque de tests que verifique el requerimiento sobre ese codigo. $TESTHINT
Los tests DEBEN invocar las funciones/clases reales del codigo y comparar su salida; sin redefinir el codigo, sin markdown, sin explicaciones."
      [ -n "$test_feedback" ] && tprompt="$tprompt

$test_feedback"
      test_code="$(printf '%s' "$tprompt" | "$ASK" -r "$tester" 2>/dev/null)" || { echo "ERROR: tester '$tester' no respondio." >&2; break; }
      # 3) combinar autor + harness y ejecutar en sandbox
      combined="$TMP/combined.$EXT"; { printf '%s\n\n' "$author_code"; printf '%s\n' "$test_code"; } > "$combined"
      if out="$(nv_sandbox_run "$LANG_C" "$combined")"; then rc=0; else rc=$?; fi
      if [ "$rc" = "0" ]; then
        # MUTATION CHECK (#1): el harness SIN la implementacion DEBE fallar. Si pasa igual,
        # los tests no ejercitan el codigo (falso VERIFICADO) -> se exige al tester mejores tests.
        onlytest="$TMP/onlytest.$EXT"; printf '%s\n' "$test_code" > "$onlytest"
        if mout="$(nv_sandbox_run "$LANG_C" "$onlytest")"; then mrc=0; else mrc=$?; fi
        if [ "$mrc" = "0" ]; then
          echo "AVISO: nivel '$author' iter $iter: los tests pasan SIN la implementacion (no la ejercitan); pido mejores tests." >&2
          test_feedback="IMPORTANTE: tus tests anteriores pasaron incluso sin la implementacion (la redefinian o no la usaban). Escribi tests que INVOQUEN las funciones reales del codigo del autor y comparen su salida con lo esperado; deben fallar si esa implementacion falta o es incorrecta."
          nv_log rol="verify-code" modelo="$author+$tester" latencia_ms=$(( $(nv_now_ms) - START_MS )) exit=0 fallback=false intentos="$iter" veredicto=fail-mutation
          continue
        fi
        verdict="pass"
        nv_log rol="verify-code" modelo="$author+$tester" latencia_ms=$(( $(nv_now_ms) - START_MS )) exit=0 fallback=false intentos="$iter" veredicto=pass
        nv_record_quality "$author" "$LANG_C" 1
        break 2
      fi
      nv_log rol="verify-code" modelo="$author+$tester" latencia_ms=$(( $(nv_now_ms) - START_MS )) exit="$rc" fallback=false intentos="$iter" veredicto=fail
      nv_record_quality "$author" "$LANG_C" 0
      feedback="$out"
      echo "AVISO: nivel '$author' iter $iter fallo (rc=$rc); reinyectando feedback." >&2
    done
    [ "$verdict" = "pass" ] && break
    echo "AVISO: nivel '$author' agoto $MAXITER intentos; escalando al siguiente nivel." >&2
  done
  # salida
  local code; code="$(cat "$finalfile" 2>/dev/null)"
  if [ -n "$OUTFILE" ]; then printf '%s\n' "$code" > "$OUTFILE"; fi
  if [ "$verdict" = "pass" ]; then
    echo "[VERIFICADO: tests PASARON en sandbox $LANG_C | nivel: $used_level]"
  else
    echo "[NO VERIFICADO: la escalera ($ESCALA) no logro pasar los tests. Ultimo error:]"
    printf '%s\n' "$feedback" | head -n 8
    echo "[--- codigo del ultimo intento (revisar a mano) ---]"
  fi
  if [ "$QUIET" = "1" ] && [ "$verdict" = "pass" ]; then
    printf '%s\n' "$code" | head -n "${NV_PREVIEW:-15}"
    [ -n "$OUTFILE" ] && echo "...[codigo completo en $OUTFILE]"
  else
    printf '%s\n' "$code"
  fi
}

# ---------- MODO TEXT: ensemble paralelo -> juez; si confianza baja, escala con 'ultra' ----------
run_text() {
  local round models="$MODELS" judge_out="" conf has_ultra
  for round in 1 2; do
    local rol f i=0 listing=""; local -a files=()
    # 1) ensemble en paralelo
    for rol in $models; do
      f="$TMP/ens_${round}_$i"; files+=("$f")
      ( "$ASK" -r "$rol" "$REQ" > "$f" 2>/dev/null ) &
      i=$((i+1))
    done
    wait || true
    # 2) armar el listado de candidatas para el juez
    i=0
    for rol in $models; do
      listing="$listing
=== CANDIDATA $((i+1)) (modelo: $rol) ===
$(cat "${files[$i]}" 2>/dev/null)
"
      i=$((i+1))
    done
    # 3) JUEZ (otro modelo) evalua con rubrica y elige/sintetiza (estructurado -> [CONFIANZA: X])
    local jprompt="Requerimiento del usuario: $REQ

Tenes varias respuestas candidatas de distintos modelos:
$listing

Evalualas con esta rubrica: correctitud, completitud, ausencia de errores y riesgos. Elegi la mejor o sintetiza una superior combinando lo mejor de cada una. Si las candidatas se contradicen entre si, baja la confianza y explicita la discrepancia en RIESGOS."
    judge_out="$(printf '%s' "$jprompt" | "$ASK" -j "$JUDGE" 2>/dev/null)" || judge_out=""
    conf="$(printf '%s' "$judge_out" | head -1 | tr 'A-Z' 'a-z' | grep -oE 'baja|media|alta' | head -1)"
    nv_log rol="verify-text-judge" modelo="$JUDGE" latencia_ms=$(( $(nv_now_ms) - START_MS )) exit=0 fallback=false intentos="$(echo "$models"|wc -w)" veredicto="judged-${conf:-na}"
    # escalar UNA vez: solo si confianza baja, primera ronda, hay presupuesto y ultra no esta aun
    case " $models " in *" ultra "*) has_ultra=1 ;; *) has_ultra=0 ;; esac
    if [ "$round" = "1" ] && [ "$conf" = "baja" ] && [ "$has_ultra" = "0" ] && ! budget_exceeded; then
      echo "AVISO: juez con confianza baja; escalando ensemble con 'ultra'." >&2
      models="$models ultra"; continue
    fi
    break
  done
  # salida
  if [ -n "$OUTFILE" ]; then printf '%s\n' "$judge_out" > "$OUTFILE"; fi
  if [ "$QUIET" = "1" ]; then printf '%s\n' "$judge_out" | head -n $(( ${NV_PREVIEW:-12} + 2 )); else printf '%s\n' "$judge_out"; fi
}

case "$MODE" in
  code) run_code ;;
  text) run_text ;;
  *) echo "ERROR: modo invalido '$MODE' (use code|text)" >&2; exit 1 ;;
esac
