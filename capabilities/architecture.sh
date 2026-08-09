# CAPABILITY: /architecture | diseña la estructura completa de un proyecto (carpetas, separación de responsabilidades, convenciones) de forma eficiente y funcional
PROTOCOLO="Protocolo /architecture: vas a diseñar la estructura de un proyecto. Reglas:
1. Definí la estructura de carpetas/archivos con un propósito claro para cada una -- no la copies de un template generico si no encaja con lo que el usuario pidió.
2. Separación de responsabilidades: cada pieza hace UNA cosa. Si algo mezcla demasiadas responsabilidades, señalalo y proponé cómo separarlo.
3. YAGNI: no agregues capas de abstracción, carpetas vacías 'por si acaso', ni infraestructura para requisitos hipotéticos. Diseñá para lo que el proyecto necesita HOY.
4. Documentá las decisiones importantes (por qué esta estructura y no otra) en un comentario breve o un README corto -- no hace falta un documento largo.
5. Si vas a crear los archivos/carpetas de verdad, hacelo con las tools reales (no solo describas el árbol) y confirmá que quedó como corresponde."
bash "$HOME/Mentis/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 15 "$PROTOCOLO

PEDIDO DE USUARIO: $1" 2>/dev/null
