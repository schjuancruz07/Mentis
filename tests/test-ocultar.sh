#!/usr/bin/env bash
# test-ocultar.sh -- que `.hidden` oculte de verdad, para todos y para siempre.
#
# POR QUE EXISTE:
#   Dos veces se escapó el mismo bug. ERR-124: `#panel { display:flex }` le ganaba a `[hidden]` y
#   el panel del celular no se podía cerrar. Y el 2026-08-08, el usuario mandó una captura donde el
#   panel de "Publicar una actualización" se veía CON EL SWITCH APAGADO.
#
#   La causa de fondo era la misma y no era el panel: no existía una regla `.hidden` global. Cada
#   elemento traía la suya (`#toast.hidden{display:none}` y así 24 veces), o sea que ocultar algo
#   dependía de que quien lo agregara se acordara. Los dos elementos del modo administrador
#   nacieron sin ella.
#
#   Peor todavía: `#admin-switch-fila` tampoco la tenía, así que el switch de administrador se
#   veía en las copias de OTRAS personas -- justo lo contrario de lo que promete el comentario de
#   index.html ("en las copias de las otras personas ni aparece").
#
# Este test mira el CSS y el HTML como texto. No necesita navegador: lo que se prueba es que la
# regla exista y que nadie la pise, que es donde falló.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS="$HERE/app/renderer/style.css"
HTML="$HERE/app/renderer/index.html"

ok=0; fallo=0
_ok()  { ok=$((ok+1));    printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== la regla global existe =="
if grep -qE '^\.hidden\s*\{[^}]*display:\s*none\s*!important' "$CSS"; then
  _ok "existe '.hidden { display: none !important }'"
else
  _mal "existe la regla global.hidden" "sin ella, cada panel nuevo nace visible"
fi

# El !important no es cosmético: los paneles se seleccionan por id, y un id le gana a una clase.
# Si alguien lo saca "porque !important es feo", #admin-panel vuelve a verse siempre.
if grep -qE '^\.hidden\s*\{[^}]*!important' "$CSS"; then
  _ok "la regla global lleva !important (le gana a los selectores de id)"
else
  _mal "la regla global lleva !important" "un '#panel { display:flex }' la pisaria"
fi

echo "== los elementos del modo administrador =="
# Los dos que fallaron. Se chequean por nombre porque son los que el usuario reportó, y porque el de la
# fila es el que decide si el switch aparece en la máquina de otra persona.
for el in admin-panel admin-switch-fila; do
  if grep -qE "id=\"$el\"[^>]*class=\"[^\"]*hidden" "$HTML"; then
    _ok "#$el arranca con class=\"hidden\" en el HTML"
  else
    _mal "#$el arranca oculto" "tiene que nacer oculto y mostrarse solo si corresponde"
  fi
done

# Que nadie le devuelva un display incondicional al panel. Se acepta dentro de la propia regla
# `#admin-panel {... display:flex... }` (asi se ve cuando NO esta oculto); lo que no puede pasar
# es que exista `#admin-panel.hidden { display: algo }` que lo resucite.
if grep -qE '#admin-panel\.hidden\s*\{[^}]*display:\s*(flex|block|grid|inline)' "$CSS"; then
  _mal "nadie resucita #admin-panel cuando esta oculto" "hay una regla.hidden que le devuelve el display"
else
  _ok "nadie resucita #admin-panel cuando esta oculto"
fi

echo "== la unica excepcion, y que siga siendo la unica =="
# #voz-estado se DESVANECE en vez de desaparecer: reserva su lugar debajo del nucleo para que el
# cuerpo digital no salte. Necesita recuperar el display a mano.
if grep -qE '#voz-estado\.hidden\s*\{[^}]*display:\s*block\s*!important' "$CSS"; then
  _ok "#voz-estado conserva su display (se desvanece, no desaparece)"
else
  _mal "#voz-estado conserva su display" "con la regla global se saldria del layout y el cuerpo saltaria"
fi
# Si aparece una excepción nueva, que sea una decisión y no un accidente: este contador la caza.
n_excep="$(grep -cE '\.hidden\s*\{[^}]*display:\s*(block|flex|grid|inline)' "$CSS" || true)"
if [ "$n_excep" -le 1 ]; then
  _ok "hay a lo sumo UNA excepcion a la regla global (hay $n_excep)"
else
  _mal "hay a lo sumo UNA excepcion" "aparecieron $n_excep; cada una es un elemento que puede no ocultarse"
fi

echo "== el panel esta fuera de la barra lateral =="
# Pedido del usuario (2026-08-08): estaba en el medio de la navegación diaria para una tarea que hace
# una sola persona muy de vez en cuando.
if awk '/<aside id="sidebar">/,/<\/aside>/' "$HTML" | grep -q 'id="admin-panel"'; then
  _mal "#admin-panel esta fuera del sidebar" "sigue adentro de <aside id=\"sidebar\">"
else
  _ok "#admin-panel ya no vive en la barra lateral"
fi
if grep -qE '#admin-panel\s*\{[^}]*position:\s*fixed' "$CSS"; then
  _ok "#admin-panel esta anclado a la franja de abajo a la derecha"
else
  _mal "#admin-panel anclado abajo a la derecha" "sin position:fixed vuelve al flujo del documento"
fi

echo "== tipografia: nada escrito a mano =="
# Dos veces se escapó una familia hardcodeada al pasar todo a Courier.
sueltas="$(grep -nE 'font-family:\s*(ui-monospace|Consolas|Georgia|-apple-system|"Segoe|"Cascadia|"JetBrains)' "$CSS" | grep -v '^\s*/\*' || true)"
if [ -z "$sueltas" ]; then
  _ok "todas las font-family salen de las variables"
else
  _mal "todas las font-family salen de las variables" "quedaron sueltas: $(printf '%s' "$sueltas" | head -2 | tr '\n' ' ')"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
