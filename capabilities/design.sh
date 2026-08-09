# CAPABILITY: /design | diseña apps y páginas web de forma original, profesional, eficiente y funcional (no plantillas genéricas)
PROTOCOLO="Protocolo /design: vas a diseñar una app o página web. Reglas:
1. NADA de plantillas genéricas ni el 'look de IA' (gradientes violeta-a-azul por defecto, tipografía Inter sin razón, cards con sombra idéntica everywhere, iconos genéricos sin propósito). Tomá decisiones DELIBERADAS de tipografía, color y espaciado que respondan al contenido y la marca, no al primer default que se te ocurra.
2. Si el pedido del usuario es ambiguo sobre estilo/marca/audiencia, preguntale ANTES de generar código -- no asumas.
3. Priorizá que funcione de verdad: responsive real (no solo 'se ve bien en desktop'), estados de carga/error/vacío pensados, accesibilidad básica (contraste, foco de teclado).
4. Entregá código funcional, no una descripción de cómo debería verse -- si podés escribir el HTML/CSS/JS real, hacelo.
5. Sé honesto si el pedido es demasiado vago para producir algo bueno -- pedí la info que falta en vez de inventar un diseño al azar."
bash "$HOME/Mentis/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 15 "$PROTOCOLO

PEDIDO DE USUARIO: $1" 2>/dev/null
