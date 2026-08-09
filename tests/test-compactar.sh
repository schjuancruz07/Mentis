#!/usr/bin/env bash
# test-compactar.sh -- la compactacion de contexto de mentis-chat.sh (agregada 2026-08-02).
#
# QUE SE PRUEBA Y POR QUE ASI:
#   Hasta hoy, mentis-chat.sh mandaba las ultimas 20 entradas y lo anterior lo CORTABA. Lo que
#   el usuario dijo en el mensaje 3 desaparecia sin dejar rastro. Ahora hay un resumen corrido de lo que
#   salio de la ventana.
#
#   El test NO comprueba "que la funcion exista". Sourcea mentis-chat.sh de produccion, arma un
#   historial de verdad con un dato plantado bien atras, y comprueba que ese dato sobreviva. Es la
#   unica forma de detectar el modo de falla que importa: que la compactacion corra, no falle, y
#   pierda justo el dato que se queria conservar.
#
# El unico paso que llama a un modelo esta detras de -v: lo demas (cuando compacta, cuando no,
# como degrada) es deterministico y tiene que poder correrse siempre.
set -uo pipefail
TC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC_ROOT="$(cd "$TC_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TC_VIVO=0; [ "${1:-}" = "-v" ] && TC_VIVO=1
TC_OK=0; TC_MAL=0
_ok()  { TC_OK=$((TC_OK+1));  echo "  OK   $1"; }
_mal() { TC_MAL=$((TC_MAL+1)); echo "  MAL  $1  ($2)"; }

TC_TMP="$(mktemp -d)"
trap 'rm -rf "$TC_TMP"' EXIT

# mentis-chat.sh corre su bucle principal solo si lo ejecutan directo; sourcearlo define las
# funciones y no arranca nada (guard BASH_SOURCE[0] = $0).
TOOLSDIR="$TC_ROOT/engine"
MENTIS_ENV_DIR="$TC_ROOT"
# shellcheck source=/dev/null
source "$TC_ROOT/mentis-chat.sh" 2>/dev/null || true

# EL HISTFILE SE SETEA DESPUES DE SOURCEAR, Y NO ES UN DETALLE DE ESTILO.
#
# Este test lo seteaba ANTES y sourcear lo PISABA con el history.jsonl real de Mentis. Resultado:
# el test truncó el historial de conversaciones del usuario y lo llenó con mensajes de prueba
# ("mensaje numero 3, charla intrascendente sobre el clima"). Se recuperó del respaldo diario de
# las 15:17, pero pudo no haber respaldo.
#
# Por que pasa: HISTFILE es una variable de BASH (el historial del shell), no una variable propia.
# mentis-chat.sh la usa igual para su archivo de conversacion, asi que cualquier valor que le
# ponga el caller se pierde al sourcear. Es el ERR-002 con otra ropa.
#
# La regla general, que ya estaba escrita en la memoria mentis-verify-discipline y que este test
# ignoro: ANTES de correr algo que ESCRIBE, comprobar que escribe donde se cree. Dos lineas de
# assert cuestan menos que restaurar un backup.
HISTFILE="$TC_TMP/hist.jsonl"
case "$HISTFILE" in
  "$TC_TMP"/*) : ;;
  *) echo "ABORTA: HISTFILE apunta a '$HISTFILE', fuera del temporal. Este test escribe y truncaría datos reales." >&2; exit 1 ;;
esac
[ "$(_mc_resumen_file)" = "$TC_TMP/hist.jsonl.resumen" ] || {
  echo "ABORTA: el resumen iría a '$(_mc_resumen_file)', fuera del temporal." >&2; exit 1; }

_hist() {  # <n_entradas> -- arma un historial con un dato plantado en la entrada 3
  : > "$HISTFILE"
  local i
  for i in $(seq 1 "$1"); do
    if [ "$i" = "3" ]; then
      printf '{"role":"user","content":"Mi perra se llama Kira y es una border collie de 4 anios."}\n' >> "$HISTFILE"
    else
      printf '{"role":"user","content":"mensaje numero %s, charla intrascendente sobre el clima"}\n' "$i" >> "$HISTFILE"
    fi
    printf '{"role":"assistant","content":"respuesta numero %s"}\n' "$i" >> "$HISTFILE"
  done
}

echo "== cuando NO tiene que compactar =="
_hist 5   # 10 entradas: ni siquiera llenan la ventana de 20
_mc_compactar_bg; wait 2>/dev/null
[ ! -f "$HISTFILE.resumen" ] && _ok "con la conversacion corta no gasta una llamada" || _mal "compactó sin necesidad" ""

_hist 13  # 26 entradas: caen 6, menos que el lote de 10
_mc_compactar_bg; wait 2>/dev/null
[ ! -f "$HISTFILE.resumen" ] && _ok "espera a juntar un lote antes de gastar una llamada" || _mal "compactó con menos de un lote" ""

echo "== degradar bien =="
# Sin resumen, el bloque que se inyecta tiene que quedar vacio, no romper ni meter basura.
TC_R="$(_mc_load_resumen)"
[ -z "${TC_R// }" ] && _ok "sin resumen, no inyecta nada" || _mal "inyectó algo sin tener resumen" "$TC_R"

# Un resumen ilegible no puede tumbar la conversacion.
printf 'resumen de prueba con un dato: Kira, border collie\n' > "$HISTFILE.resumen"
TC_R="$(_mc_load_resumen)"
printf '%s' "$TC_R" | grep -q "Kira" && _ok "lee el resumen cuando existe" || _mal "no leyó el resumen" "$TC_R"

# Y que la ventana textual siga siendo la de siempre: compactar no puede cambiar lo que ya andaba.
_hist 30
TC_N="$(_mc_tail_history 20 | wc -l | tr -d ' ')"
[ "$TC_N" = "20" ] && _ok "la ventana textual sigue siendo de 20 entradas" || _mal "la ventana cambió" "$TC_N"

rm -f "$HISTFILE.resumen" "$HISTFILE.resumen.hasta"

if [ "$TC_VIVO" = "1" ]; then
  echo "== compactacion real (llama al modelo) =="
  # 40 entradas: caen 20, que es mas que el lote de 10. El dato plantado (Kira) esta en la
  # entrada 5 del archivo, o sea bien adentro de la zona que se compacta.
  _hist 20
  TC_T0=$(date +%s%N)
  _mc_compactar_bg; wait 2>/dev/null
  TC_T1=$(date +%s%N)
  if [ -f "$HISTFILE.resumen" ]; then
    _ok "generó el resumen ($(( (TC_T1-TC_T0)/1000000 )) ms, en segundo plano)"
    TC_TXT="$(cat "$HISTFILE.resumen")"
    echo "  --   resumen: $(printf '%s' "$TC_TXT" | head -c 300)"
    # LA PRUEBA QUE IMPORTA: el dato de la entrada 3 tiene que haber sobrevivido a la compactacion.
    # Sin esto, el test aprobaria un resumen que dice "hablaron del clima" y perdio todo lo util.
    if printf '%s' "$TC_TXT" | grep -qi "kira"; then
      _ok "el dato concreto de la entrada 3 SOBREVIVIO a la compactacion"
    else
      _mal "el resumen perdió el dato que había que conservar" "$(printf '%s' "$TC_TXT" | head -c 200)"
    fi
    # Y que anote hasta donde llego, o la proxima vez volveria a resumir lo mismo.
    TC_H="$(cat "$HISTFILE.resumen.hasta" 2>/dev/null)"
    [ "$TC_H" = "20" ] && _ok "anota hasta donde compactó (entrada $TC_H)" || _mal "no anotó bien el avance" "hasta=$TC_H"
    # Segunda corrida sin entradas nuevas: no tiene que gastar otra llamada.
    TC_ANTES="$(cat "$HISTFILE.resumen")"
    _mc_compactar_bg; wait 2>/dev/null
    [ "$(cat "$HISTFILE.resumen")" = "$TC_ANTES" ] && _ok "no vuelve a resumir lo ya resumido" || _mal "re-resumió sin entradas nuevas" ""
  else
    _mal "no generó el resumen" "puede ser cuota agotada; reintentar"
  fi
else
  echo "  --   compactación real salteada (necesita una llamada: correr con -v)"
fi

echo
echo "== RESULTADO: $TC_OK bien, $TC_MAL mal =="
[ "$TC_MAL" -eq 0 ]
