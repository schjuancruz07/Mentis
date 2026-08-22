#!/usr/bin/env bash
# test-preview-vivo.sh -- la cadena que muestra qué está haciendo Mentis mientras lo hace.
#
# POR QUE EXISTE:
#   el usuario reportó que "nunca funcionó" ver las tareas en vivo ni la previsualización. Al medirlo,
#   TODAS las piezas andaban: nv-agent.sh emitía las líneas, mentis-chat.sh las reenviaba,
#   mentis-process.js las partía, main.js las mandaba al renderer y el renderer las parseaba y
#   dibujaba. Lo que fallaba era una sola cosa: **el panel nunca se abría**.
#
#   #status-panel nace con la clase `collapsed` (display:none) y el único lugar que la sacaba era
#   renderScreenPreview -- o sea, sólo las capturas de pantalla. Un `write` o un `read` escribían
#   adentro de un cajón cerrado, y al empezar el turno siguiente se limpiaba. Funcionaba entero,
#   a puertas cerradas.
#
#   La lección para este test: no alcanza con verificar que cada eslabón anda. Hay que verificar
#   que el resultado LLEGA A VERSE.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$HERE/app/renderer/renderer.js"
H="$HERE/app/renderer/index.html"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el emisor =="
if grep -q 'echo "\[nv-agent\] PRESUPUESTO: \$MAXIT" >&2' "$A"; then
  _ok "nv-agent.sh anuncia su presupuesto de pasos"
else
  _mal "nv-agent.sh anuncia el presupuesto" "sin eso no se puede decir 'paso 3 de 10'"
fi
# Va a stderr y no a stdout a propósito: stdout es la respuesta del turno.
if grep -qE 'echo "\[nv-agent\] iter \$it: done" >&2' "$A"; then
  _ok "los pasos siguen yendo por stderr (que es lo que lee la app)"
else
  _mal "los pasos van por stderr" "si pasan a stdout, se mezclan con la respuesta"
fi

echo "== el panel se ABRE, que era el bug =="
if grep -q "function abrirPanelSiHaceFalta" "$R"; then
  _ok "existe la función que abre el panel"
else
  _mal "existe abrirPanelSiHaceFalta" "sin ella el panel se llena cerrado, como antes"
fi
# Tiene que llamarse desde el manejador de pasos, no sólo desde las capturas.
if awk '/^function handleAgentLogLine/,/^}/' "$R" | grep -q "abrirPanelSiHaceFalta"; then
  _ok "se abre ante CUALQUIER paso, no sólo ante capturas"
else
  _mal "se abre ante cualquier paso" "vuelve a depender de que haya una captura de pantalla"
fi

echo "== respeta que el usuario lo cierre =="
if grep -q "panelCerradoPorJuan" "$R"; then
  _ok "recuerda si el usuario lo cerró a mano"
else
  _mal "recuerda si el usuario lo cerró" "se le abriria en la cara en cada paso"
fi
if awk '/^function abrirPanelSiHaceFalta/,/^}/' "$R" | grep -q "if (panelCerradoPorJuan) return"; then
  _ok "y no lo reabre mientras siga cerrado por decisión"
else
  _mal "no reabre si lo cerró" "la decision del usuario tiene que ganar"
fi
# Pero un turno nuevo empieza de cero: cerrarlo una vez no es cerrarlo para siempre.
if grep -q "panelCerradoPorJuan = false" "$R"; then
  _ok "un turno nuevo vuelve a permitir que se abra"
else
  _mal "un turno nuevo resetea la decision" "cerrarlo una vez lo apagaria para siempre"
fi

echo "== progreso: 'paso 3 de 10' =="
if grep -q "PRESUPUESTO_LOG_RE" "$R"; then
  _ok "el renderer lee la línea del presupuesto"
else
  _mal "el renderer lee el presupuesto" "no podria mostrar el total"
fi
if grep -q 'id="status-progreso"' "$H"; then
  _ok "existe el lugar donde mostrarlo"
else
  _mal "existe #status-progreso en el HTML" "actualizarProgreso escribiria en la nada"
fi
if grep -q "cerca-del-limite" "$R"; then
  _ok "avisa cuando quedan 2 pasos o menos"
else
  _mal "avisa cuando esta por quedarse sin pasos" "el turno puede cortarse sin aviso"
fi

echo "== las cuatro cosas que pidió el usuario siguen cableadas =="
for par in "appendLiveStep:los pasos que va dando" \
           "renderFilePreview:el contenido de lo que crea" \
           "actualizarProgreso:en qué punto está" \
           "renderScreenPreview:las capturas de pantalla"; do
  fn="${par%%:*}"; desc="${par##*:}"
  if grep -q "function $fn" "$R"; then _ok "$desc"; else _mal "$desc" "falta la funcion $fn"; fi
done

echo "== el regex sigue casando con lo que se emite de verdad =="
# Se compara el formato del emisor contra el del parseador. Si alguien cambia uno, esto lo caza.
if grep -q 'TASK_LOG_RE = /\^\\\[nv-agent\\\] iter' "$R" && grep -q '\[nv-agent\] iter \$it' "$A"; then
  _ok "emisor y parseador usan el mismo formato '[nv-agent] iter N:'"
else
  _mal "emisor y parseador coinciden" "si cambia uno de los dos, el panel deja de dibujar en silencio"
fi

echo ""

# --- EJECUTADO, no grepeado (2026-08-18) --------------------------------------------------------
# Las aserciones de arriba comprueban que las funciones EXISTAN. El bug que motivo este archivo era
# otro: todas las piezas existian y andaban, y el panel igual no se abria. preview-panel-ejecuta.js
# extrae abrirPanelSiHaceFalta del renderer y la corre contra un DOM de mentira. Se verifico
# reinyectando el bug historico (la funcion sin el remove('collapsed')): lo encuentra.
if node "$(dirname "${BASH_SOURCE[0]}")/preview-panel-ejecuta.js" > /tmp/pv-ejec.$$ 2>&1; then
  _ok "EJECUTADO: el panel se abre con actividad y respeta que el usuario lo cierre ($(grep -o 'casos: [0-9]*' /tmp/pv-ejec.$$))"
else
  _mal "EJECUTADO: la apertura del panel no se comporta" "$(head -3 /tmp/pv-ejec.$$ | tr '
' ' ')"
fi
rm -f /tmp/pv-ejec.$$

echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
