# Mentis

Un asistente que corre **entero en tu computadora**. Habla, escucha, lee tus documentos, busca en
internet, edita video, mira imágenes y hace trabajo de empresa chica — con modelos que en su
configuración de fábrica **no cuestan nada**.

No es un envoltorio de una API paga. Es un motor propio (bash + Python) con una app de escritorio
encima, y todo lo que guardás se queda en tu máquina.

> **Para instalarlo:** [INSTALAR.md](INSTALAR.md). Si tenés Claude Code, pedile que lo haga por vos.

---

## Qué hace

| | |
|---|---|
| **Conversa** | Por texto o por voz, de ida y vuelta. Se acuerda de lo que hablaron antes y lo trae solo cuando hace falta |
| **Trabaja en tu máquina** | Lee y escribe archivos, corre comandos, mira la pantalla — siempre con permiso y con la posibilidad de deshacer |
| **Departamentos** | Cobranzas y Presupuestos: perfiles con objetivo, herramientas y **libro mayor auditable** |
| **Study y Science** | Estudiar sobre un corpus propio; química en 3D con datos reales de PubChem |
| **Editor** | Editar un video entero con ffmpeg, automático, sin línea de tiempo |
| **3D y CAD** | Analizar mallas y generar piezas paramétricas en STEP |
| **Ve** | Cámara, pantalla, imágenes y video analizado como secuencia — no como fotos sueltas |
| **Busca imágenes por lo que se ve** | "la captura donde estaba el error de la cámara" y aparece |
| **Aprende mirando** | Hacés una tarea, y de ahí sale una skill |
| **Desde el celular** | Página propia, e instalable como app sin pasar por ninguna tienda |

---

## Qué lo diferencia de lo que ya es gratis

Cline y Goose son agentes gratis y muy buenos; Claude Code es de pago y también. Se comparó
capacidad por capacidad —ejecución autónoma, acceso a internet, integración con IDEs, memoria
externa, ejecución de código, contexto largo, entrada multimodal, planificación, precios y
despliegue en la nube— y en **nueve de diez hay paridad**: lo que a Mentis "le falta" ya lo dan
gratis Cline o Goose. Lo que Mentis tiene y ellos no:

1. **Departamentos con libro mayor.** El entregable se verifica **contra el disco**, no contra lo
   que el modelo dice haber hecho. Nació de un caso real: un departamento informó que había dejado
   los borradores en un archivo de 3 bytes.
2. **El conjunto local**: voz de ida y vuelta, Study, Science, 3D/CAD, modo Editor. Son
   verticales, no funciones de agente de código.
3. **El costo por turno puede ser cero.** Cline y Goose son gratis pero el modelo lo pagás vos.

Y lo que **no** tiene, dicho de frente: no es una extensión de VS Code, no corre en la nube, y
nadie probó todavía que alguien pague por él.

---

## Cómo está construido

```
mentis-*.sh          los comandos (chat, voz, departamentos, video, imágenes, celular…)
engine/              el motor: agente, modelos, streaming, búsqueda, índice vectorial
capabilities/        las skills (/recall, /where, /estudiar, /boveda…)
app/                 la app de escritorio (Electron)
tests/               los tests. Son muchos y a propósito
```

**La regla del proyecto:** nada entra sin ganarle a lo que ya hay, medido en una tarea real. Hay
cosas que se construyeron, se midieron y **se eliminaron**: la disputa cruzada entre dos
proveedores corrigió 0 casos de 16 y se borró; el reparto automático de tareas perdió 31 a 37 y
quedó apagado. Las mediciones quedan en el repositorio de desarrollo.

---

## Lo que necesita

- **Windows** con Git Bash, Python 3 y Node.js
- Una **clave de NVIDIA** (gratis) para los modelos
- ffmpeg para video y audio

Todo lo demás es opcional y el instalador te dice qué falta.

---

## Honestidad sobre el estado

Esto se usa todos los días y funciona. También:

- Hay guardas que existen porque el sistema ya falló de esa manera exacta, y cada una tiene el
  incidente escrito al lado en el código.
- Las mediciones que salieron mal están publicadas igual que las que salieron bien.
- Cuando algo no se pudo verificar, lo dice en vez de suponer.

Si encontrás algo que promete más de lo que hace, es un bug y vale reportarlo como tal.
