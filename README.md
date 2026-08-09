# Mentis

Un asistente personal que vive en tu computadora. Le hablás, te contesta con voz, y puede hacer
cosas de verdad: escribir archivos, buscar en internet, generar documentos e imágenes, leer un PDF,
manejar el navegador, acordarse de lo que hablaron la semana pasada.

No es una página web con una cuenta. Es un programa que corre en tu máquina, con tus archivos, y
que sigue siendo tuyo cuando lo cerrás.

---

## Qué hace

- **Habla y escucha.** Tocás el círculo y le hablás. Te contesta con voz mientras piensa, sin
  esperar a tener toda la respuesta armada.
- **Hace, no sólo responde.** Crea archivos, corre programas, arma documentos de Word y
  presentaciones, genera imágenes, busca en la web y navega páginas.
- **Se acuerda.** Recuerda lo que le contaste en conversaciones anteriores y lo trae cuando viene
  al caso.
- **Se ve trabajar.** Un panel muestra en vivo qué está haciendo paso por paso, qué archivo está
  escribiendo y en qué punto va: *"paso 3 de 10"*.
- **Trabaja aparte.** Le podés dar una tarea larga y seguir con lo tuyo; te avisa cuando termina.
- **Desde el celular.** Abre una página en tu red local para escribirle desde el teléfono, sin
  instalar nada.

## Qué necesitás

| | |
|---|---|
| **Sistema** | Windows 10 u 11. El motor corre en Git Bash. |
| **Programas** | [Git para Windows](https://git-scm.com/download/win), [Node.js](https://nodejs.org/) 20 o mayor, [Python](https://www.python.org/downloads/) 3.11 o mayor |
| **Una clave de IA** | Gratuita, de NVIDIA. Se saca en [build.nvidia.com](https://build.nvidia.com) y toma dos minutos. |
| **Espacio** | Unos 500 MB con todo instalado |

No hace falta una placa de video potente: los modelos corren en la nube, tu computadora sólo
coordina.

## Instalación

```bash
git clone https://github.com/schjuancruz07/Mentis.git
cd Mentis
bash instalar.sh
```

El instalador te va a pedir la clave de NVIDIA, instalar lo que falte y dejar la aplicación lista.
Cuando termine, abrís Mentis desde el menú de inicio.

Si algo no anda, corré `bash mentis-diagnostico.sh`: revisa todo y te dice qué falta en castellano.

## Lo que conviene saber antes de usarlo

**Lo que escribís viaja a un modelo de IA.** Mentis usa los modelos de NVIDIA en la nube, así que
lo que le contás sale de tu computadora. Antes de mandar, se ocultan automáticamente las claves,
tokens y contraseñas que detecte; el resto del texto va tal cual.

**Podés usar Google Gemini como alternativa, y viene apagado.** Si lo prendés, tené en cuenta que
el plan gratuito de Google **usa lo que le mandás para entrenar sus modelos**, y hay revisores
humanos que pueden llegar a leerlo. El plan pago no. Mentis te lo avisa antes de encenderlo.

**Las capacidades invasivas arrancan apagadas.** La cámara, el control del mouse y el acceso al
teléfono se prenden a mano, de a una, desde Conectores. La cámara además tiene un tope de usos por
turno, para que no pueda quedarse sacando fotos aunque algo salga mal.

**Puede ejecutar comandos en tu máquina.** Es parte de para qué sirve. Los comandos destructivos
están bloqueados salvo que los habilites explícitamente, y las acciones delicadas te piden permiso
en una ventana antes de correr.

## Cómo está armado

```
engine/         El motor: el agente, las llamadas a los modelos, la voz, la búsqueda
app/            La ventana (Electron)
capabilities/   Habilidades sueltas: documentos, imágenes, hardware, bóveda
mcp-bridge/     Puente para conectar servicios externos por MCP
tests/          Las pruebas. Son bastantes y se corren solas antes de cada publicación.
```

El motor es bash y Python; la ventana es Electron. Se pueden usar por separado: `mentis-chat.sh`
funciona en una consola sin abrir la aplicación.

## Sobre este proyecto

Mentis nació como un asistente personal para uso propio y creció hasta acá. El código está en
castellano —los comentarios explican **por qué** está hecho así, no qué hace la línea siguiente— y
muchas decisiones tienen al lado la medición que las justifica.

Se publica por si a alguien le sirve, entero o en partes. No hay soporte ni garantías: es un
proyecto personal, no un producto.

## Licencia

[Apache 2.0](LICENSE). Podés usarlo, modificarlo y distribuirlo, incluso comercialmente, mientras
mantengas el aviso de licencia y digas qué cambiaste.
