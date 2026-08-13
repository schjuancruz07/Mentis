# CAPABILITY: /design | diseña apps y páginas web de forma original, profesional, eficiente y funcional (no plantillas genéricas)
#
# BUCLE GENERADOR-EVALUADOR (2026-08-11). Antes esto era un prompt y nada más: se le pedía al modelo
# que cuidara el contraste y el responsive, y se confiaba en que lo hiciera. Pedirle algo al modelo
# es una sugerencia, no una garantía -- la misma lección que dejó la cámara (ERR-133).
#
# Ahora, cuando el entregable es una página, lo MIDE una herramienta después de generarlo
# (eval/duelo-design/juez.js: paleta de la marca, tipografía, contraste real calculado sobre lo que
# el navegador pinta, autocontenido, sin errores de consola, sin desborde en pantalla angosta). Si
# algo no llega, las fallas concretas vuelven al modelo como pedido de corrección y se mide otra
# vez. Hasta dos rondas.
#
# POR QUE DOS Y NO MÁS: en la tercera ronda ya no está corrigiendo, está probando cosas. Si a la
# segunda no llegó, es mejor entregar lo que hay diciendo QUÉ falta que seguir gastando turnos --
# y con el detalle en la mano el usuario decide si lo arregla él o lo vuelve a pedir distinto.
#
# SI EL ENTREGABLE NO ES UNA PÁGINA (un logo, una imagen, un documento), no hay nada que medir con
# esta vara y el bucle no corre. Se dice explícitamente en vez de callarlo: un "listo" sin control
# se parece demasiado a un "listo" con control.

PROTOCOLO="Protocolo /design: vas a diseñar una app o página web. Reglas:
1. NADA de plantillas genéricas ni el 'look de IA' (gradientes violeta-a-azul por defecto, tipografía Inter sin razón, cards con sombra idéntica everywhere, iconos genéricos sin propósito). Tomá decisiones DELIBERADAS de tipografía, color y espaciado que respondan al contenido y la marca, no al primer default que se te ocurra.
2. Si el pedido del usuario es ambiguo sobre estilo/marca/audiencia, preguntale ANTES de generar código -- no asumas.
3. Priorizá que funcione de verdad: responsive real (no solo 'se ve bien en desktop'), estados de carga/error/vacío pensados, accesibilidad básica (contraste, foco de teclado).
4. Entregá código funcional, no una descripción de cómo debería verse -- si podés escribir el HTML/CSS/JS real, hacelo.
5. Sé honesto si el pedido es demasiado vago para producir algo bueno -- pedí la info que falta en vez de inventar un diseño al azar.
6. Si hacés una página, que sea AUTOCONTENIDA: nada de traer tipografías, hojas de estilo ni scripts de un servidor ajeno. Se abre sin internet o no sirve.
7. LA TIPOGRAFIA DE LA MARCA YA ESTA EN LA MAQUINA, no hay que bajarla: las cinco familias de Mentis viven en $MENTIS_RAIZ/app/renderer/assets/fonts/ como.woff2, con su fuentes.css al lado. Si la página va a vivir dentro de Mentis, referencialas por ruta relativa. Si es un archivo suelto que se va a mandar por ahí, COPIA el.woff2 al lado del html y declará el @font-face vos.
8. Y SI NINGUNA DE LAS DOS SE PUEDE (no tenés cómo copiar el archivo), usá la sans del sistema -- 'Segoe UI', system-ui, sans-serif -- y decilo en la respuesta. Un <link> a fonts.googleapis.com NO es una opción: rompe la página sin internet y le avisa a un servidor ajeno cada vez que alguien la abre. Entre una fuente distinta y una llamada a un CDN, siempre la fuente distinta.
9. Cuando termines de escribir el archivo, decí su ruta en una línea aparte."

MENTIS_RAIZ="$HOME/Mentis"
JUEZ="$MENTIS_RAIZ/eval/duelo-design/juez.js"

_design_pagina_mas_nueva() {
  # La página más nueva de la carpeta de trabajo. Se busca así y no por un nombre fijo porque el
  # nombre lo elige el modelo según lo que le pidieron, y forzarle uno sería empeorar el entregable
  # para que la medición sea más cómoda.
  find "$ROOT" -maxdepth 3 -name '*.html' -newermt '-12 hours' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1
}

bash "$MENTIS_RAIZ/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 15 "$PROTOCOLO

PEDIDO DE USUARIO: $1" 2>/dev/null

PAGINA="$(_design_pagina_mas_nueva)"
if [ -z "$PAGINA" ] || [ ! -f "$PAGINA" ]; then
  echo
  echo "[design] El entregable no es una página web, así que no corrió el control de calidad automático (mide contraste, paleta, responsive y errores; sólo aplica a HTML)."
  exit 0
fi

for RONDA in 1 2; do
  echo
  echo "[design] Control de calidad sobre $(basename "$PAGINA") (ronda $RONDA de 2):"
  if SALIDA="$(node "$JUEZ" "$PAGINA" 2>&1)"; then
    printf '%s\n' "$SALIDA"
    echo "[design] Pasa las reglas medibles. Lo que ninguna herramienta puede decir es si además está lindo: eso miralo vos."
    exit 0
  fi
  printf '%s\n' "$SALIDA"

  FALLAS="$(printf '%s\n' "$SALIDA" | grep '^  FALLA' || true)"
  if [ "$RONDA" = "2" ]; then
    echo
    echo "[design] Quedó con eso sin resolver después de dos intentos. Te lo entrego igual, con el detalle de arriba, en vez de seguir dando vueltas."
    exit 1
  fi

  echo "[design] Corrigiendo..."
  bash "$MENTIS_RAIZ/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 10 "Escribiste el archivo $PAGINA y un control de calidad automático encontró estos problemas concretos:

$FALLAS

EMPEZÁ leyendo ese archivo con 'read' -- no lo busques con 'search', ya sabés dónde está. Después arreglá EXACTAMENTE eso con 'edit' y nada más: no rehagas el diseño ni toques lo que ya estaba bien.

Dos cosas que suelen trabar esta corrección:
- Si la falla es que carga algo de afuera y era una tipografía: las de Mentis están en $MENTIS_RAIZ/app/renderer/assets/fonts/ (copiá el.woff2 al lado del html y declará el @font-face), y si no podés copiarla, sacá el <link> y usá 'Segoe UI', system-ui, sans-serif. Una fuente distinta es mejor que una llamada a un CDN.
- Si la falla es de contraste, se mide sobre el color que el navegador TERMINA pintando: cambiá el color del texto o el de su fondo hasta que llegue, no alcanza con declararlo bien en otro lado." 2>/dev/null
done
