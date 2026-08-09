# Mentis vs Hermes -- comparativa objetiva

Fecha: 2026-07-26 17:53 | Modelo comun: **z-ai/glm-5.2** (via NVIDIA)

Reglas fijadas ANTES de correr: misma tarea, misma carpeta vacia, verificador externo
que aprueba por exit code. Ninguno de los dos evalua su propio trabajo.

| # | Tarea | Agente | Aprobado | Segundos | Dejo el archivo |
|---|---|---|---|---|---|
| 1 | Escribi un archivo cuit.py con una funcion... | Mentis | **si** | 600s | si |
| 1 | Escribi un archivo cuit.py con una funcion... | Hermes | **si** | 34s | si |
| 2 | Escribi un archivo plata.py con una funcio... | Mentis | **si** | 300s | si |
| 2 | Escribi un archivo plata.py con una funcio... | Hermes | **si** | 42s | si |

