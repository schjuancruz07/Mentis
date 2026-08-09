#!/usr/bin/env bash
# mentis-diagnostico.sh — Mentis se revisa a sí mismo y arregla lo que puede arreglar solo.
#
# Uso:
#   mentis-diagnostico.sh              # revisa todo lo rápido y repara lo mecánico
#   mentis-diagnostico.sh --mirar      # sólo mira, no toca nada
#   mentis-diagnostico.sh --completo   # además corre TODAS las suites de tests (tarda minutos)
#
# Sale con 0 si todo está sano (o quedó sano tras repararse), 1 si queda algo roto.
#
# CÓMO NO MENTIRSE (esto es lo importante de este archivo):
# Un sistema que se diagnostica con el mismo modelo que falló tiende a declararse sano. Ya pasó
# acá: Kai Vault estuvo OCHO DÍAS roto contestando "Listo" (2026-07-26). Por eso este script no
# le pregunta su opinión a ningún modelo. Todo lo que reporta sale de señales que no se pueden
# discutir: un código de salida, un HTTP, un archivo que existe o no, un proceso vivo o muerto.
# Si un chequeo no puede responderse con una de esas, no está acá.
#
# Y REPARA POCO A PROPÓSITO: sólo lo mecánico y reversible -- levantar un servidor caído, barrer
# duplicados, reindexar. Nada que toque código. Un agente que se edita a sí mismo y además se
# califica es exactamente la receta de los ocho días.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODO="reparar"
case "${1:-}" in
  --mirar) MODO="mirar" ;;
  --completo) MODO="completo" ;;
  --reporte) MODO="reporte" ;;
  "") ;;
  *) echo "Uso: mentis-diagnostico.sh [--mirar|--completo|--reporte]" >&2; exit 2 ;;
esac

# --- MODO REPORTE (2026-08-06) -----------------------------------------------------------------
# Mentis ahora lo usa mas gente, en maquinas que el usuario no tiene adelante. Cuando a alguien se le
# rompe algo, la conversacion es "no me anda" y no hay con que ayudarlo.
#
# Esto arma un archivo que la persona puede mandar. La regla que lo hace posible: NO SALE UN SOLO
# DATO PERSONAL. Ni conversaciones, ni memorias, ni claves, ni rutas con el nombre de usuario. Solo
# hechos tecnicos: que hay instalado, que contesta y que no. Si esto filtrara algo, nadie deberia
# mandarlo -- y entonces no serviria para nada.
#
# Hay un test (tests/test-diagnostico-reporte.sh) que abre el archivo generado y falla si encuentra
# rastros personales.
if [ "$MODO" = "reporte" ]; then
  DESTINO="${2:-$HERE/reporte-mentis.txt}"
  {
    echo "REPORTE DE MENTIS"
    echo "generado: $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "-- sistema"
    echo "  so           : $(uname -s 2>/dev/null || echo desconocido)"
    echo "  bash         : ${BASH_VERSION:-?}"
    echo "  python3      : $(python3 --version 2>&1 | head -1)"
    echo "  node         : $(node --version 2>&1 | head -1)"
    echo "  git          : $(git --version 2>&1 | head -1)"
    echo
    echo "-- claves cargadas (SOLO si estan o no, nunca el valor)"
    _hay_clave() {
      local v
      v="$(bash -c 'source "'"$HERE"'/engine/nv-lib.sh" 2>/dev/null; nv_read_setting '"$1" 2>/dev/null | tr -d ' \r\n')"
      [ -n "$v" ] && echo "  $1: si (${#v} caracteres)" || echo "  $1: NO"
    }
    _hay_clave NVIDIA_API_KEY
    _hay_clave ELEVENLABS_API_KEY
    for k in IDEOGRAM_API_KEY RUNWAY_API_KEY NASA_API_KEY; do
      if grep -q "^$k=." "$HERE/.custom-models-secrets.env" 2>/dev/null; then
        echo "  $k: si"
      else
        echo "  $k: NO"
      fi
    done
    echo
    echo "-- apariencia"
    echo "  nombre       : $(bash -c 'source "'"$HERE"'/engine/nv-lib.sh" 2>/dev/null; nv_nombre_ia' 2>/dev/null)"
    echo
    echo "-- modelos (una llamada real por rol principal)"
    timeout 400 bash "$HERE/mentis-modelos.sh" -p 2>&1 | sed 's/^/  /' | head -20
    echo
    echo "-- pagina del celular"
    # EL TOKEN SE TAPA, Y NO ES UN DETALLE. `mentis-web.sh estado` imprime la direccion COMPLETA,
    # con el ?t=... que es la llave para entrarle a Mentis desde la red. La primera version de este
    # reporte lo incluia entero, debajo de una linea que prometia que no habia claves adentro:
    # cualquiera que lo mandara por WhatsApp estaba regalando el acceso.
    # Se detecto leyendo el archivo generado, no revisando el codigo.
    bash "$HERE/mentis-web.sh" estado 2>&1 | sed -E 's/([?&]t=)[A-Za-z0-9_-]+/\1<TOKEN OCULTO>/g' | sed 's/^/  /' | head -6
    echo
    echo "-- ultimos errores del motor (sin el texto de lo que se pidio)"
    # Del log solo salen rol, modelo, codigo y tiempo: nunca el prompt ni la respuesta.
    if [ -f "$HERE/engine/logs/nv.jsonl" ]; then
      tail -200 "$HERE/engine/logs/nv.jsonl" 2>/dev/null | python3 -c '
import json, sys
malos = []
for l in sys.stdin:
    try:
        d = json.loads(l)
    except Exception:
        continue
    if d.get("exit") not in (0, None, ""):
        malos.append("  %s rol=%s modelo=%s exit=%s %sms" % (
            d.get("ts", "?"), d.get("rol", "?"), d.get("modelo", "?"),
            d.get("exit"), d.get("latencia_ms", "?")))
print("\n".join(malos[-10:]) if malos else "  (ninguno en las ultimas 200 llamadas)")
' 2>/dev/null
    else
      echo "  (todavia no hay registro de llamadas)"
    fi
    echo
    echo "-- suites rapidas"
    for t in test-temas test-formato test-stream test-modelos-override; do
      if [ -f "$HERE/tests/$t.sh" ]; then
        r="$(timeout 300 bash "$HERE/tests/$t.sh" 2>&1 | grep -oE "[0-9]+ (OK|ok), [0-9]+ (MAL|falla)" | tail -1)"
        echo "  $t: ${r:-sin resumen}"
      fi
    done
    echo
    echo "FIN. Este archivo se puede mandar: no tiene conversaciones, ni memorias, ni claves."
  } > "$DESTINO" 2>&1

  echo "Reporte escrito en: $DESTINO"
  echo "Podes mandarselo a quien te instalo Mentis: no lleva nada personal adentro."
  exit 0
fi

PROBLEMAS=0; REPARADOS=0; SANOS=0
INFORME=""

_ok()      { SANOS=$((SANOS+1)); printf '  ok       %s\n' "$1"; }
_roto()    { PROBLEMAS=$((PROBLEMAS+1)); printf '  ROTO     %s\n' "$1"; INFORME="${INFORME}  - $1"$'\n'; }
_reparado(){ REPARADOS=$((REPARADOS+1)); printf '  reparado %s\n' "$1"; }
_aviso()   { printf '  aviso    %s\n' "$1"; }

echo "=== Mentis se revisa a sí mismo ==="
echo

# --- 1. las piezas del motor están donde tienen que estar -----------------------------------
echo "1. Archivos del motor"
FALTAN=0
for f in mentis-chat.sh engine/nv-agent.sh engine/ask-nvidia.sh engine/nv-lib.sh mentis-tts.sh mentis-transcribe.sh; do
  [ -f "$HERE/$f" ] || { _roto "falta $f"; FALTAN=$((FALTAN+1)); }
done
[ "$FALTAN" -eq 0 ] && _ok "las 6 piezas del motor están presentes"
# Que un.sh tenga un error de sintaxis es la forma más barata de estar roto sin saberlo.
ERRSINTAXIS=0
for f in "$HERE"/*.sh "$HERE"/engine/*.sh; do
  bash -n "$f" 2>/dev/null || { _roto "error de sintaxis en $(basename "$f")"; ERRSINTAXIS=$((ERRSINTAXIS+1)); }
done
[ "$ERRSINTAXIS" -eq 0 ] && _ok "ningún script tiene errores de sintaxis"

# --- 2. servidor de voz (salida) -------------------------------------------------------------
echo
echo "2. Voz"
TTS_ESTADO="$HERE/tts-server-state.json"
TTS_PUERTO="$(grep -oE '"puerto"[: ]+[0-9]+' "$TTS_ESTADO" 2>/dev/null | grep -oE '[0-9]+$' || true)"
if [ -n "$TTS_PUERTO" ] && curl -s -m 4 "http://127.0.0.1:$TTS_PUERTO/salud" 2>/dev/null | grep -q '"ok": *true'; then
  _ok "el servidor de voz responde (puerto $TTS_PUERTO)"
else
  if [ "$MODO" = "mirar" ]; then
    _roto "el servidor de voz no responde"
  else
    # Reparación mecánica: mentis-tts.sh levanta el servidor solo al primer uso.
    DESCARTE="$(mktemp -u).wav"
    if bash "$HERE/mentis-tts.sh" "Listo." "$DESCARTE" >/dev/null 2>&1 && [ -s "$DESCARTE" ]; then
      _reparado "el servidor de voz estaba caído y se levantó"
    else
      _roto "el servidor de voz no responde y no se pudo levantar"
    fi
    rm -f "$DESCARTE" 2>/dev/null || true
  fi
fi
# Duplicados: cada arranque solía dejar uno huérfano, con su modelo en memoria (2026-07-28).
DUPES="$(powershell.exe -NoProfile -NonInteractive -Command "
  Get-CimInstance Win32_Process -Filter \"Name like '%python%'\" |
    Where-Object { \$_.CommandLine -like '*nv_tts_server*' } |
    Measure-Object | Select-Object -ExpandProperty Count" 2>/dev/null | tr -d '\r[:space:]')"
if [ -n "$DUPES" ] && [ "$DUPES" -gt 2 ] 2>/dev/null; then
  _roto "hay $DUPES servidores de voz corriendo a la vez (deberían ser 1 o 2)"
else
  _ok "no hay una pila de servidores de voz (${DUPES:-?} vivo/s)"
fi

# --- 3. servidor de transcripción (entrada) --------------------------------------------------
echo
echo "3. Oído"
if bash "$HERE/mentis-transcribe.sh" --salud 2>/dev/null | grep -qi 'ok\|listo\|true'; then
  _ok "el servidor de transcripción responde"
else
  if [ "$MODO" = "mirar" ]; then
    _roto "el servidor de transcripción no responde"
  elif bash "$HERE/mentis-transcribe.sh" --encender >/dev/null 2>&1; then
    _reparado "el servidor de transcripción estaba caído y se encendió"
  else
    _roto "el servidor de transcripción no responde y no se pudo encender"
  fi
fi

# --- 4. modelos ------------------------------------------------------------------------------
echo
echo "4. Modelos"
if [ -f "$HERE/mentis-modelos.sh" ]; then
  MODOUT="$(bash "$HERE/mentis-modelos.sh" -p -q 2>&1)"; MODRC=$?
  case "$MODRC" in
    0) _ok "todos los modelos principales responden" ;;
    3) _aviso "hay modelos saturados (free tier lleno). No es para cambiarlos: vuelve solo." ;;
    *) _roto "hay modelos principales caídos -- correr: bash mentis-modelos.sh -p" ;;
  esac
else
  _aviso "no está mentis-modelos.sh, salteo el chequeo de modelos"
fi

# --- 5. Kai Vault ----------------------------------------------------------------------------
echo
echo "5. Kai Vault (memoria del ecosistema)"
if [ -f "$HERE/capabilities/boveda.sh" ]; then
  KV="$(bash "$HERE/capabilities/boveda.sh" salud 2>&1)"; KVRC=$?
  if [ "$KVRC" -eq 0 ] && ! printf '%s' "$KV" | grep -qi 'error\|no such file\|vacio\|roto'; then
    _ok "Kai Vault responde"
  else
    _roto "Kai Vault no está sano: $(printf '%s' "$KV" | head -2 | tr '\n' ' ')"
  fi
else
  _aviso "no está boveda.sh, salteo Kai Vault"
fi

# --- 6. suites de tests (sólo con --completo) ------------------------------------------------
if [ "$MODO" = "completo" ]; then
  echo
  echo "6. Suites de tests (esto tarda)"
  if [ -d "$HERE/app" ]; then
    if (cd "$HERE/app" && npm test >/dev/null 2>&1); then _ok "los tests de la app pasan"
    else _roto "los tests de la app FALLAN -- correr: cd app && npm test"; fi
  fi
  for t in "$HERE"/tests/test-*.sh; do
    NOMBRE="$(basename "$t".sh)"
    if bash "$t" >/dev/null 2>&1; then _ok "$NOMBRE pasa"
    else _roto "$NOMBRE FALLA -- correr: bash tests/$NOMBRE.sh"; fi
  done
else
  echo
  echo "6. Suites de tests: salteadas (corré con --completo para incluirlas)"
fi

# --- resumen ---------------------------------------------------------------------------------
echo
echo "=== Resultado ==="
printf 'sanos: %s   reparados: %s   rotos: %s\n' "$SANOS" "$REPARADOS" "$PROBLEMAS"
if [ "$PROBLEMAS" -gt 0 ]; then
  echo
  echo "Lo que sigue roto y NO puedo arreglar solo:"
  printf '%s' "$INFORME"
  exit 1
fi
[ "$REPARADOS" -gt 0 ] && echo "Todo lo que estaba caído quedó levantado." || echo "Está todo bien."
exit 0
