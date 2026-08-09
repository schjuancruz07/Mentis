# CAPABILITY: /multiply | multiplicate temporalmente para resolver una tarea de varios pasos de forma eficiente (decide qué partes van en paralelo, cuáles delegar, y trackea el avance)
PROTOCOLO="Protocolo /multiply: la tarea que sigue tiene VARIOS pasos. Antes de actuar:
1. Descomponé la tarea en sub-partes concretas.
2. Para cada sub-parte, decidí: ¿es INDEPENDIENTE de las demás (no necesita el resultado de otra)? Si hay 2+ sub-partes independientes, usá el tool 'parallel' para mandarlas TODAS JUNTAS de una (no una por una) -- ahorra tiempo real. Si una sub-parte requiere investigación de varios pasos antes de tener respuesta, usá 'subagent'. Si es una consulta puntual a otro cerebro, usá 'delegate'.
3. Si la tarea tiene 3 o más pasos reales, usá el tool 'task' para crear una entrada por paso ANTES de empezar, y marcá cada una in_progress/completed a medida que avanzás -- así el trabajo queda trazable aunque la conversación siga en varios turnos.
4. Al final, integrá todos los resultados en UNA respuesta coherente para el usuario -- no le pegues las respuestas crudas de cada sub-tarea sin conectarlas."
bash "$HOME/Mentis/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 15 "$PROTOCOLO

PEDIDO DE USUARIO: $1" 2>/dev/null
