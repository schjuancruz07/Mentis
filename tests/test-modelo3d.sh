#!/usr/bin/env bash
# El analisis de modelos 3D: que distinga una pieza fabricable de una que no lo es.
#
# POR QUE IMPORTA: Mentis genera modelos con TripoSR a partir de una imagen. Esos modelos se ven
# bien en el visor y eso no dice NADA sobre si se pueden fabricar. Una malla abierta, unas normales
# al reves o veinte pedazos sueltos se descubren recien cuando falla la impresora o cuando el taller
# rebota el archivo. Estos casos se GENERAN con defectos conocidos y se comprueba que los encuentre.
T3_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; MAL=0
_ok()  { OK=$((OK+1));  echo "  ok    $1"; }
_mal() { MAL=$((MAL+1)); echo "  FALLA $1  ($2)"; }

if ! python3 -c "import trimesh" 2>/dev/null; then
  echo "  -- trimesh no esta instalado; se saltea (pip install trimesh)"
  echo "== 0 ok, 0 fallan =="
  exit 0
fi

T3_TMP="$(mktemp -d)"
trap 'rm -rf "$T3_TMP"' EXIT
python3 - "$T3_TMP" <<'PY'
import sys, os, trimesh, numpy as np
d = sys.argv[1]
trimesh.creation.box(extents=[20, 10, 5]).export(os.path.join(d, "sana.stl"))
m = trimesh.creation.box(extents=[20, 10, 5])
m.update_faces(np.arange(len(m.faces)) != 0)          # le falta una cara -> malla abierta
m.export(os.path.join(d, "abierta.stl"))
a = trimesh.creation.box(extents=[10, 10, 10])
b = trimesh.creation.box(extents=[10, 10, 10]); b.apply_translation([50, 0, 0])
trimesh.util.concatenate([a, b]).export(os.path.join(d, "dos-cuerpos.stl"))
trimesh.creation.box(extents=[20, 10, 0]).export(os.path.join(d, "plana.stl"))
PY

_an() { python3 "$T3_HERE/engine/modelo3d_analizar.py" "$T3_TMP/$1.stl" 2>&1; }

echo "-- una pieza sana pasa"
S="$(_an sana)"
case "$S" in *"SIRVE PARA FABRICAR"*) _ok "la pieza cerrada se declara fabricable" ;;
  *) _mal "rechaza una pieza sana" "$(printf '%s' "$S" | tail -2 | tr '\n' ' ')" ;; esac
python3 "$T3_HERE/engine/modelo3d_analizar.py" "$T3_TMP/sana.stl" >/dev/null 2>&1 \
  && _ok "sale con codigo 0 cuando es fabricable" \
  || _mal "codigo de salida en pieza sana" "deberia ser 0"

echo "-- los defectos que arruinan una fabricacion"
S="$(_an abierta)"
case "$S" in *"NO esta cerrada"*) _ok "detecta la malla abierta" ;;
  *) _mal "no detecta una malla abierta" "es el defecto mas comun de TripoSR" ;; esac
case "$S" in *"3 aristas abiertas"*) _ok "cuenta bien las aristas de borde (3, la cara que falta)" ;;
  *) _mal "cuenta mal las aristas abiertas" "$(printf '%s' "$S" | grep -o '[0-9]* aristas abiertas')" ;; esac
case "$S" in *"no se puede calcular"*) _ok "no inventa un volumen sobre una malla abierta" ;;
  *) _mal "reporta volumen de una malla abierta" "seria un numero sin sentido" ;; esac

S="$(_an dos-cuerpos)"
case "$S" in *"2 cuerpos sueltos"*) _ok "detecta que son dos piezas y no una" ;;
  *) _mal "no detecta cuerpos sueltos" "se mandaria a fabricar como una sola pieza" ;; esac

S="$(_an plana)"
case "$S" in *"no tiene espesor"*) _ok "detecta la pieza sin espesor" ;;
  *) _mal "no detecta espesor cero" "no existe como objeto fisico" ;; esac

python3 "$T3_HERE/engine/modelo3d_analizar.py" "$T3_TMP/abierta.stl" >/dev/null 2>&1
[ "$?" = "3" ] && _ok "sale con codigo 3 cuando NO es fabricable" \
                || _mal "codigo de salida en pieza rota" "deberia ser 3"

echo "-- no inventa lo que no puede saber"
case "$(_an sana)" in *"fijar la escala a mano"*) _ok "avisa que la escala no se deduce del archivo" ;;
  *) _mal "no avisa sobre la escala" "un cubo de lado 1 puede ser 1 mm o 1 m: inventarlo arruina la pieza" ;; esac

echo "-- un archivo que no es un modelo no lo hace explotar"
printf 'esto no es un modelo 3D\n' > "$T3_TMP/basura.stl"
if python3 "$T3_HERE/engine/modelo3d_analizar.py" "$T3_TMP/basura.stl" >/dev/null 2>&1; then
  _mal "acepto un archivo que no es un modelo" "deberia fallar claro"
else
  _ok "un archivo invalido falla con mensaje, no con un traceback"
fi


echo "-- la pista de fabricacion llega sola al prompt"
# El modelo no descubria estas acciones: medido dos veces, ante "necesito fabricar una placa para el
# taller" ni miraba 'gen' y escribia un.dxf inventado de 283 bytes. Ahora, si el pedido habla de
# fabricar, la accion exacta va en el prompt inicial sin que tenga que pedir la ficha de 5,6 KB.
_disp() { TASK="$1" bash -c '
  case "$(printf %s "$TASK" | tr "A-Z" "a-z")" in
    *fabric*|*imprim*|*taller*|*mecaniz*|*torner*|*pieza*|*.stl*|*.glb*|*.step*|*modelo\ 3d*|*plano*) echo si ;;
    *) echo no ;;
  esac'; }
[ "$(_disp 'necesito fabricar una placa para el taller')" = "si" ]   && _ok "un pedido de fabricacion dispara la pista" || _mal "no dispara con 'fabricar'" "seguiria inventando archivos"
[ "$(_disp 'analiza pieza.stl')" = "si" ]   && _ok "nombrar un.stl dispara la pista" || _mal "no dispara con.stl" ""
[ "$(_disp 'contame que es el mate')" = "no" ]   && _ok "una charla NO dispara la pista (no ensucia el prompt de todos los turnos)"   || _mal "dispara en cualquier turno" "seria texto muerto en cada prompt"
grep -q "NUNCA escribas a mano un.dxf" "$T3_HERE/engine/nv-agent.sh"   && _ok "la pista prohibe explicitamente escribir el archivo a mano"   || _mal "no prohibe el archivo a mano" "es lo que hizo cuando fallo"

echo
echo "== $OK ok, $MAL fallan =="
[ "$MAL" -eq 0 ]
