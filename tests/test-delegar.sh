#!/usr/bin/env bash
# test-delegar.sh -- el contrato de delegacion: darle una tarea a alguien mas y despegarse.
#
# QUE SE PRUEBA: que lanzar NO bloquee, que el estado se actualice de verdad al terminar, que
# distinga terminar de fallar, y que la tarea delegada tenga MENOS permisos que un turno normal.
#
# NO usa la red ni lanza al agente real salvo en una prueba corta y acotada: el objetivo es el
# mecanismo, no la calidad de la respuesta del modelo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$HERE/mentis-delegar.sh"

TD_TMP="$(mktemp -d)"
trap 'rm -rf "$TD_TMP"' EXIT
# ERR-119: un test jamas escribe en el estado de produccion. Las delegaciones de prueba viven en
# una carpeta propia; sin esto, ensuciarian la lista real de tareas del usuario.
export MENTIS_DELEGACIONES_DIR="$TD_TMP/delegaciones"
mkdir -p "$MENTIS_DELEGACIONES_DIR"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== lo basico =="
bash -n "$D" 2>/dev/null && _ok "compila" || _mal "compila" "error de sintaxis"
[ -x "$D" ] && _ok "es ejecutable" || _mal "es ejecutable" "falta chmod +x"

echo "== la tarea delegada tiene MENOS permisos, no mas =="
# Corre sin nadie mirando: no puede sacar fotos, manejar el mouse ni tocar la pantalla. Delegar
# es dar los mismos permisos con menos supervision, asi que se dan menos.
linea="$(grep -E 'nv-agent.sh" -w' "$D" | head -1)"
case "$linea" in
  *" -V"*) _mal "la delegacion NO habilita la camara" "tiene -V" ;;
  *)       _ok "la delegacion no habilita la camara" ;;
esac
case "$linea" in
  *" -s"*) _mal "la delegacion NO habilita la pantalla" "tiene -s" ;;
  *)       _ok "la delegacion no habilita la pantalla" ;;
esac
case "$linea" in
  *" -c"*) _mal "la delegacion NO habilita el control del mouse" "tiene -c" ;;
  *)       _ok "la delegacion no habilita el control del mouse" ;;
esac
case "$linea" in
  *" -x"*) _mal "la delegacion NO corre sin frenos" "tiene -x" ;;
  *)       _ok "la delegacion no corre sin frenos" ;;
esac
# Y la carpeta va en -d. En la primera corrida real se uso -r, que no existe, y el agente moria
# al arrancar con "opción inválida": la tarea figuraba lanzada y nunca hacia nada.
case "$linea" in
  *'-d "$MD_CARPETA"'*) _ok "la carpeta se pasa con -d (la opcion que existe)" ;;
  *)                     _mal "la carpeta va en -d" "nv-agent.sh no tiene -r y muere al arrancar" ;;
esac

echo "== lanzar no bloquea =="
T0=$(date +%s)
ID="$(bash "$D" -a inexistente -i 2 "tarea de prueba" 2>/dev/null)"
T1=$(date +%s)
if [ $((T1-T0)) -le 10 ]; then _ok "devuelve el control enseguida ($((T1-T0))s)"; else _mal "no bloquea" "tardo $((T1-T0))s"; fi
[ -n "$ID" ] && _ok "devuelve un id usable" || _mal "devuelve un id" "salio vacio"

echo "== un agente que no existe termina en 'fallo', no colgado =="
# Se espera a que el subshell escriba el estado final.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$MENTIS_DELEGACIONES_DIR/$ID.aviso" ] && break
  sleep 1
done
estado="$(python3 -c '
import json,sys
try: print(json.load(open(sys.argv[1],encoding="utf-8")).get("estado",""))
except Exception: print("")
' "$MENTIS_DELEGACIONES_DIR/$ID.json" 2>/dev/null | tr -d "\r")"
[ "$estado" = "fallo" ] && _ok "agente inexistente -> estado 'fallo'" || _mal "estado tras agente inexistente" "quedo en '$estado'"
# El bug de la primera version: el aviso se escribia pero el JSON quedaba en "corriendo" para
# siempre, porque el resultado se pasaba escapado a mano por linea de comandos.
[ "$estado" != "corriendo" ] && _ok "el estado NO se queda pegado en 'corriendo'" || _mal "el estado se actualiza" "quedo corriendo"

echo "== el aviso para la app =="
[ -f "$MENTIS_DELEGACIONES_DIR/$ID.aviso" ] && _ok "deja el archivo de aviso que la app vigila" || _mal "escribe el aviso" "la app nunca se enteraria"
if grep -q 'MD_DIR/\$MD_ID.aviso' "$D"; then
  _ok "el aviso se escribe DESPUES del estado (no avisa de algo a medio guardar)"
else
  _mal "orden del aviso" "podria avisar antes de que el resultado este escrito"
fi

echo "== listar y ver =="
bash "$D" -l >/dev/null 2>&1 && _ok "listar no explota" || _mal "listar" "salio con error"
bash "$D" -v "$ID" >/dev/null 2>&1 && _ok "ver una tarea no explota" || _mal "ver" "salio con error"
bash "$D" -v "no-existe-este-id" >/dev/null 2>&1 && _mal "ver un id inexistente" "deberia fallar" || _ok "ver un id inexistente avisa y sale"

echo "== el estado se escribe de forma atomica =="
# Si la app leyera un JSON a medio escribir, mostraria basura o se colgaria.
grep -q "os.replace(tmp, est)" "$D" && _ok "el estado se reemplaza atomicamente" || _mal "escritura atomica" "la app puede leer un json partido"

echo "== la carpeta de delegaciones NO se borra al arrancar la app =="
# Es la diferencia con el canal de aprobaciones: delegar sirve JUSTAMENTE para que la tarea
# sobreviva a que se cierre Mentis.
if grep -q "DELEGACIONES_DIR" "$HERE/app/main.js" && ! awk '/const DELEGACIONES_DIR/,/setInterval/' "$HERE/app/main.js" | grep -q "rmSync"; then
  _ok "la app no borra las delegaciones al abrir"
else
  _mal "la app conserva las delegaciones" "cerrar Mentis perderia la tarea mandada aparte"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
