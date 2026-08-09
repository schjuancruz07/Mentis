# Comparativa de modelos de embeddings para Kai Vault

Fecha: 2026-07-26 17:19
Casos: 15 consultas con respuesta conocida.

## nvidia/nv-embedqa-e5-v5

- Chunks indexados: **905** (tardo 73s)
- Acierto en top-3: **5 / 15**
- Acierto en top-1: **4 / 15**
- Latencia media por busqueda: **2090 ms**

| Consulta | Esperado | Resultado |
|---|---|---|
| donde se decide que modelo de IA atiende cada tipo de pedido | `engine/ask-nvidia.sh` | fallo |
| un modelo distinto escribe los tests para verificar el codigo | `engine/nv-agent.sh` | fallo |
| matar los procesos que quedan vivos despues de frenar | `app/lib/mentis-process.js` | OK  (pos 1) |
| crear la carpeta de un proyecto nuevo con sus subdivisiones | `app/lib/project-store.js` | OK  (pos 1) |
| saber en que lugar estoy usando el wifi | `mentis-location.sh` | OK  (pos 1) |
| copia de seguridad automatica todos los dias | `mentis-backup.sh` | fallo |
| correr codigo aislado sin que toque el resto de la maquina | `engine/nv-lib.sh` | fallo |
| decidir si el mensaje es de codigo o de conversacion | `engine/nv-classify-lib.sh` | fallo |
| generar una imagen a partir de un texto | `mentis-image-gen.sh` | fallo |
| pasar un audio a texto | `mentis-transcribe.sh` | OK  (pos 1) |
| mover el mouse y escribir con el teclado solo | `mentis-computer-control.sh` | fallo |
| armar un documento de Word | `mentis-doc-gen.sh` | fallo |
| programar una tarea para que corra sola mas tarde | `capabilities/programar.sh` | OK  (pos 2) |
| agregar un conector nuevo al sistema | `capabilities/conectar.sh` | fallo |
| impedir que se ejecute un comando peligroso | `engine/nv-agent.sh` | fallo |

## nvidia/nemotron-3-embed-1b

- Chunks indexados: **904** (tardo 116s)
- Acierto en top-3: **14 / 15**
- Acierto en top-1: **7 / 15**
- Latencia media por busqueda: **1989 ms**

| Consulta | Esperado | Resultado |
|---|---|---|
| donde se decide que modelo de IA atiende cada tipo de pedido | `engine/ask-nvidia.sh` | fallo |
| un modelo distinto escribe los tests para verificar el codigo | `engine/nv-agent.sh` | OK  (pos 1) |
| matar los procesos que quedan vivos despues de frenar | `app/lib/mentis-process.js` | OK  (pos 1) |
| crear la carpeta de un proyecto nuevo con sus subdivisiones | `app/lib/project-store.js` | OK  (pos 1) |
| saber en que lugar estoy usando el wifi | `mentis-location.sh` | OK  (pos 1) |
| copia de seguridad automatica todos los dias | `mentis-backup.sh` | OK  (pos 1) |
| correr codigo aislado sin que toque el resto de la maquina | `engine/nv-lib.sh` | OK  (pos 2) |
| decidir si el mensaje es de codigo o de conversacion | `engine/nv-classify-lib.sh` | OK  (pos 3) |
| generar una imagen a partir de un texto | `mentis-image-gen.sh` | OK  (pos 3) |
| pasar un audio a texto | `mentis-transcribe.sh` | OK  (pos 1) |
| mover el mouse y escribir con el teclado solo | `mentis-computer-control.sh` | OK  (pos 2) |
| armar un documento de Word | `mentis-doc-gen.sh` | OK  (pos 3) |
| programar una tarea para que corra sola mas tarde | `capabilities/programar.sh` | OK  (pos 2) |
| agregar un conector nuevo al sistema | `capabilities/conectar.sh` | OK  (pos 3) |
| impedir que se ejecute un comando peligroso | `engine/nv-agent.sh` | OK  (pos 1) |

