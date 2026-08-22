#!/usr/bin/env bash
# test-modalidades.sh -- plan / work / off: que "plan" no pueda tocar nada, de verdad.
#
# POR QUE EXISTE (idea 7 del usuario, 2026-08-21). La modalidad no es un consejo al modelo: es un
# recorte de banderas, igual que el modo remoto. La diferencia importa -- una instruccion escrita
# en el prompt ("no toques nada") es una sugerencia que el modelo cumple casi siempre, y "casi
# siempre" no sirve para decidir si algo se escribe en el disco del usuario.
#
# Se prueba con el nv-agent de mentira que anota las banderas con las que lo llamaron: asi se ve
# EXACTAMENTE con que permisos correria el turno, sin gastar una llamada a ningun modelo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/engine" "$SB/nocap" "$SB/work"
cp "$HERE/mentis-chat.sh" "$SB/"
cp "$HERE"/engine/nv-*lib*.sh "$SB/engine/" 2>/dev/null || true
cp "$HERE/engine/nv-lib.sh" "$HERE/engine/nv-classify-lib.sh" "$SB/engine/" 2>/dev/null || true
cp -r "$HERE/engine/textos" "$SB/engine/" 2>/dev/null || true
cp "$HERE/modos.json" "$HERE/skills-autonomas.json" "$SB/" 2>/dev/null || true
printf '{}' > "$SB/nodisp.json"

cat > "$SB/engine/nv-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MC_TEST_FLAGS"
echo "listo"
STUB
chmod +x "$SB/engine/nv-agent.sh"

_flags() {   # _flags <banderas del chat...> -> las banderas que recibio el agente
  local marca="$SB/f-$RANDOM.txt"; : > "$marca"
  # MENTIS_MODO y no la bandera -m: `-m` elige el ROL del modelo (code, reason...), que es
  # otra cosa que el MODO (Mentis, Code, Study). La modalidad se aplica segun el MODO, asi
  # que un test que use -m estaria probando el modo guardado en el estado -- que es lo que
  # paso: se creia estar probando Code y se probaba Mentis, donde la modalidad NO aplica.
  CAPABILITIES_DIR="$SB/nocap" MENTIS_DISPARADORES="$SB/nodisp.json" MENTIS_MODO="${MODO_PRUEBA:-code}" \
  MC_TEST_FLAGS="$marca" STATEFILE="$SB/state.json" WORKSPACE_DEFAULT="$SB/work" \
    bash "$SB/mentis-chat.sh" -H "$SB/hist.jsonl" "$@" <<< "una pregunta
salir" >/dev/null 2>&1
  cat "$marca" 2>/dev/null
}

echo "== GUARDIA: el sandbox ejecuta de verdad =="
BASE="$(_flags -m code)"
if [ -n "${BASE// }" ]; then
  _ok "el chat llamo al agente (banderas: ${BASE:0:50}...)"
else
  _mal "el chat NO llamo al agente" "lo de abajo no significa nada"
  echo "== $ok ok, $fallo fallan =="; exit 1
fi

echo ""
echo "== sin modalidad, todo sigue como antes (esto es lo que no se puede romper) =="
case " $BASE " in
  *" -w "*) _ok "por defecto el agente recibe -w, como siempre" ;;
  *)        _mal "se perdio -w sin pedir ninguna modalidad" "se rompio el uso de todos los dias" ;;
esac
OFF="$(_flags -m code -M off)"
case " $OFF " in
  *" -w "*) _ok "'-M off' se comporta igual que no pasar nada" ;;
  *)        _mal "'off' saco permisos" "off tiene que ser exactamente el comportamiento de siempre" ;;
esac

echo ""
echo "== modalidad PLAN: las manos atadas =="
PLAN="$(_flags -m code -M plan)"
if [ -z "${PLAN// }" ]; then
  _mal "con -M plan el chat no llego a llamar al agente" "la modalidad no puede romper el turno"
else
  _ok "con 'plan' el turno sigue corriendo (banderas: ${PLAN:0:50}...)"
  case " $PLAN " in
    *" -w "*) _bad_w=1; _mal "PLAN TODAVIA PUEDE ESCRIBIR Y EJECUTAR (-w)" "es lo unico que la modalidad tiene que impedir" ;;
    *)        _ok "sin -w: no escribe archivos ni ejecuta comandos" ;;
  esac
  case " $PLAN " in
    *" -K "*) _mal "plan puede correr skills solas (-K)" "cinco de ellas dejan algo hecho despues del turno" ;;
    *)        _ok "sin -K: ninguna skill corre sola" ;;
  esac
  case " $PLAN " in
    *" -x "*) _mal "plan conserva -x" "los comandos peligrosos son justo lo que no puede tocar" ;;
    *)        _ok "sin -x" ;;
  esac
  # Pero SI tiene que poder mirar: un plan que no puede leer el proyecto es una adivinanza.
  case " $PLAN " in
    *" -b "*) _ok "conserva la web (-b): puede investigar para planear" ;;
    *)        _mal "plan perdio la navegacion" "no podria averiguar nada para armar el plan" ;;
  esac
fi

echo ""
echo "== modalidad WORK: ejecuta =="
WORK="$(_flags -m code -M work)"
case " $WORK " in
  *" -w "*) _ok "'work' conserva -w" ;;
  *)        _mal "'work' no puede escribir" "es exactamente lo contrario de lo que quiere decir" ;;
esac

echo ""
echo "== en la charla comun la modalidad NO se aplica =="
# El modo "mentis" a secas es conversar: no hay nada que planear, y meterle modalidades le sacaria
# permisos a la charla de todos los dias sin que nadie lo haya pedido.
CHARLA="$(MODO_PRUEBA=mentis _flags -M plan)"
if [ -z "${CHARLA// }" ]; then
  _mal "el modo mentis con -M plan no llamo al agente" "la charla comun no puede romperse"
else
  case " $CHARLA " in
    *" -w "*) _ok "en la charla comun, 'plan' no le saca nada" ;;
    *)        _mal "'plan' recorto la charla comun" "ahi no aplica: es conversar, no construir" ;;
  esac
fi

echo ""
echo "== el prompt le DICE en que modalidad esta =="
# Sacarle las banderas no alcanza: si el prompt no lo dice, el modelo intenta, se come el rechazo
# y quema iteraciones. Es ERR-098, que en este proyecto ya aparecio tres veces.
case "$PLAN" in
  *"MODALIDAD PLAN"*) _ok "en 'plan' el prompt se lo explica" ;;
  *) _mal "el prompt no menciona la modalidad" "el modelo va a intentar escribir y chocar" ;;
esac
case "$PLAN" in
  *"NO vas a tocar nada"*) _ok "y le dice con todas las letras que no toca nada" ;;
  *) _mal "no le explica que no puede tocar nada" "" ;;
esac
case "$WORK" in
  *"MODALIDAD WORK"*) _ok "en 'work' tambien se lo dice" ;;
  *) _mal "'work' no se anuncia en el prompt" "" ;;
esac
case "$OFF" in
  *"MODALIDAD PLAN"*|*"MODALIDAD WORK"*) _mal "'off' anuncia una modalidad" "off es no tener ninguna" ;;
  *) _ok "'off' no agrega nada al prompt" ;;
esac

echo ""
echo "== una modalidad inventada se rechaza al arrancar =="
SAL="$(printf 'salir\n' | bash "$SB/mentis-chat.sh" -M inventada 2>&1 | head -2)"
case "$SAL" in
  *"modalidad invalida"*) _ok "se rechaza con un mensaje que dice cuales hay" ;;
  *) _mal "acepto una modalidad que no existe" "un error de tipeo daria permisos por accidente: $SAL" ;;
esac

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
