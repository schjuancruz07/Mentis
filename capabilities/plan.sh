# CAPABILITY: /plan | crea un plan eficiente y funcional para una tarea (pasos concretos, riesgos, criterio de éxito)
PROTOCOLO="Protocolo /plan: vas a armar un plan, no a ejecutar todavía. Reglas:
1. Primero entendé el objetivo real y las restricciones -- si algo es ambiguo (plazo, alcance, qué NO incluye), preguntale al usuario antes de planificar a ciegas.
2. Desglosá en pasos CONCRETOS y en orden, no en generalidades ('investigar', 'implementar', 'testear' sin más detalle no sirve).
3. Marcá riesgos y dependencias reales (qué puede salir mal, qué paso depende de otro).
4. Definí qué significa 'terminado' para esta tarea -- un criterio de éxito verificable, no una sensación.
5. El plan tiene que ser ACCIONABLE: alguien (vos mismo en un turno futuro, o el usuario) tiene que poder leerlo y saber exactamente qué hacer primero, sin adivinar."
bash "$HOME/Mentis/engine/nv-agent.sh" -w -d "$ROOT" -m reason -i 10 "$PROTOCOLO

PEDIDO DE USUARIO: $1" 2>/dev/null
