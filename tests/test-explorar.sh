#!/usr/bin/env bash
# test-explorar.sh -- que el agente pueda MIRAR el proyecto: listar una carpeta y buscar sin que
# el resultado sea su propio eco.
#
# POR QUE EXISTE (2026-08-21). Se le pidio a Mentis investigar que capacidades tiene y cuales le
# faltan. Escribio "No" en las cinco filas de la tabla -- incluidas ejecucion autonoma, multiagente
# y generacion de documentos, que SI tiene -- despues de usar read y search once veces. No fue que
# no quisiera verificar: no pudo.
#
#   1. Pidio leer 'capabilities' para ver que skills hay. La respuesta era un ERROR que lo mandaba
#      a usar 'search'... pero search busca TEXTO ADENTRO de los archivos, no lista una carpeta.
#      La pregunta "¿que hay aca adentro?" no tenia ninguna herramienta que la contestara.
#   2. El search le devolvia resultados de.repo-publico/ (una copia entera del proyecto) y de
#.mentis-obs/ (donde el propio agente guarda sus observaciones largas). En el paso 6 se
#      encontro a si mismo: el eco de lo que habia mirado en el paso 4.
#
# Un agente que no puede mirar su propio proyecto va a inventar lo que no puede comprobar. Eso no
# es un problema del modelo.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/engine" "$SB/trabajo/capabilities" "$SB/trabajo/.repo-publico/app" "$SB/trabajo/.mentis-obs"
cp "$HERE/engine/nv-agent.sh" "$SB/engine/"
cp "$HERE"/engine/nv-*lib*.sh "$SB/engine/" 2>/dev/null || true
cp "$HERE/engine/nv-lib.sh" "$HERE/engine/nv-verify.sh" "$SB/engine/" 2>/dev/null || true
cp -r "$HERE/engine/textos" "$SB/engine/" 2>/dev/null || true
# Los.py del motor tambien: el agente llama a archivos_pedidos.py al arrancar. Si falta, con
# `set -e` la asignacion aborta el script ANTES de la primera iteracion y el turno muere sin
# decir por que -- paso al escribir este mismo test.
cp "$HERE"/engine/*.py "$SB/engine/" 2>/dev/null || true
cp "$HERE/skills-autonomas.json" "$SB/" 2>/dev/null || true

# El proyecto de mentira: dos skills de verdad, una copia del proyecto y una observacion vieja.
printf '#!/usr/bin/env bash\n# CAPABILITY: /recordar\n' > "$SB/trabajo/capabilities/recordar.sh"
printf '#!/usr/bin/env bash\n# CAPABILITY: /plan\n'     > "$SB/trabajo/capabilities/plan.sh"
printf 'MARCA_UNICA_DEL_PROYECTO en el archivo de verdad\n' > "$SB/trabajo/motor.sh"
printf 'MARCA_UNICA_DEL_PROYECTO en la COPIA publicada\n'   > "$SB/trabajo/.repo-publico/app/copia.js"
printf 'MARCA_UNICA_DEL_PROYECTO en el eco de una observacion vieja\n' > "$SB/trabajo/.mentis-obs/obs-4-1.txt"

# Stub del modelo: hace la accion que le indiquemos y despues cierra.
cat > "$SB/engine/ask-nvidia.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
N="$(cat "${STUB_STATE:?}" 2>/dev/null || echo 0)"; N=$((N+1)); echo "$N" > "$STUB_STATE"
cat > /dev/null
if [ "$N" = "1" ]; then
  printf '%s\n' "${STUB_ACCION:?}"
else
  printf '{"tool":"done","answer":"listo"}\n'
fi
STUB
chmod +x "$SB/engine/ask-nvidia.sh"

_correr() {   # _correr <json de la accion> -> la salida del agente
  rm -f "$SB/state"
  STUB_STATE="$SB/state" STUB_ACCION="$1" MENTIS_SETTINGS_FILE="$SB/nope.json" \
    bash "$SB/engine/nv-agent.sh" -d "$SB/trabajo" -m code -i 3 -w "una tarea" 2>&1
}

echo "== GUARDIA: el agente corre en el sandbox =="
SAL="$(_correr '{"tool":"read","path":"motor.sh"}')"
case "$SAL" in
  *"iter 1:"*) _ok "el agente ejecuta una iteracion" ;;
  *) _mal "el agente no arranco" "lo de abajo no significa nada"; printf '%s\n' "$SAL" | head -5
     echo "== $ok ok, $fallo fallan =="; exit 1 ;;
esac

echo ""
echo "== leer una carpeta LISTA lo que hay adentro =="
SAL="$(_correr '{"tool":"read","path":"capabilities"}')"
case "$SAL" in
  *"es un directorio, no un archivo"*) _mal "sigue rechazando el directorio" "no hay forma de saber que hay en una carpeta" ;;
  *"recordar.sh"*) _ok "lista el contenido de la carpeta" ;;
  *) _mal "no listo el contenido" "$(printf '%s' "$SAL" | grep -i 'iter 1' | head -1)" ;;
esac
case "$SAL" in
  *"plan.sh"*) _ok "y lista TODOS los archivos, no el primero" ;;
  *) _mal "listo incompleto" "faltaria la mitad de las skills" ;;
esac

echo ""
echo "== buscar no devuelve la copia del proyecto ni el propio eco =="
SAL="$(_correr '{"tool":"search","query":"MARCA_UNICA_DEL_PROYECTO"}')"
case "$SAL" in
  *"motor.sh"*) _ok "encuentra el archivo de verdad" ;;
  *) _mal "no encontro el archivo real" "la busqueda no sirve para nada" ;;
esac
case "$SAL" in
  *".repo-publico"*) _mal "devolvio la COPIA publicada" "el turno editaria un archivo que no es el que corre" ;;
  *) _ok "no devuelve.repo-publico (la copia del proyecto)" ;;
esac
case "$SAL" in
  *".mentis-obs"*) _mal "devolvio su PROPIA observacion vieja" "el turno mirando su propio eco: asi se hacen los lazos" ;;
  *) _ok "no devuelve.mentis-obs (sus propias observaciones)" ;;
esac

echo ""
echo "== escribir el placeholder del protocolo NO destruye el archivo =="
# POR QUE (2026-08-21): el protocolo se documenta con content:"<content>", y el modelo copio el
# ejemplo literal. Un plan de 4.704 bytes quedo en 9 -- y el turno cerro diciendo "redacte el
# documento, el archivo contiene la estrategia y los pasos concretos".
printf 'CONTENIDO IMPORTANTE QUE NO SE PUEDE PERDER
' > "$SB/trabajo/plan.md"
SAL="$(_correr '{"tool":"write","path":"plan.md","content":"<content>"}')"
case "$SAL" in
  *"placeholder del protocolo"*) _ok "se rechaza y se dice por que" ;;
  *) _mal "acepto el placeholder" "el archivo se destruye y el turno sigue como si nada" ;;
esac
if grep -q "CONTENIDO IMPORTANTE" "$SB/trabajo/plan.md"; then
  _ok "y el archivo que ya existia quedo intacto"
else
  _mal "DESTRUYO el archivo" "quedo: $(cat "$SB/trabajo/plan.md")"
fi

echo ""
echo "== si un write encoge un archivo, se avisa en la misma observacion =="
# No se rechaza (a veces vaciar es lo correcto), pero el modelo tiene que enterarse en el turno.
printf '%3000s' '' | tr ' ' 'x' > "$SB/trabajo/largo.md"
SAL="$(_correr '{"tool":"write","path":"largo.md","content":"resumen corto"}')"
case "$SAL" in
  *"ENCOGIO"*) _ok "avisa que el archivo se achico, con los dos tamaños" ;;
  *) _mal "no aviso del encogimiento" "3000 bytes reemplazados por 13 sin una palabra" ;;
esac
# Y un archivo nuevo, o uno chico, no tiene que disparar el aviso: seria ruido en cada write.
SAL="$(_correr '{"tool":"write","path":"nuevo.md","content":"algo"}')"
case "$SAL" in
  *"ENCOGIO"*) _mal "aviso sobre un archivo nuevo" "una alarma que suena siempre no la mira nadie" ;;
  *) _ok "no avisa al crear un archivo nuevo" ;;
esac

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
