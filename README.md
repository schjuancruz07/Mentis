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

## Actualizarlo

```bash
bash mentis-actualizar.sh buscar     # ve si hay algo nuevo y qué cambió
bash mentis-actualizar.sh instalar   # lo instala (pregunta antes)
```

Nunca se actualiza solo. Antes de tocar nada hace un respaldo, y si modificaste algún archivo de
Mentis **frena y te avisa** en vez de pisarte el trabajo. Si algo sale mal:
`bash mentis-actualizar.sh volver`.

Tus conversaciones, tu memoria y tus claves no se tocan nunca: viven en archivos que las
actualizaciones ni miran.

## Lo que conviene saber antes de usarlo

Esto no es la letra chica: es lo que hay que entender **antes** de instalarlo. Mentis puede hacer
cosas reales en tu computadora, y conviene que sepas cuáles.

### Lo que escribís sale de tu computadora

Mentis usa modelos de IA en la nube (NVIDIA por defecto), así que lo que le contás viaja por
internet. Antes de mandar, se ocultan automáticamente las claves, tokens y contraseñas que
detecte; **el resto del texto va tal cual**.

Si además prendés **Google Gemini** —que viene apagado— tené en cuenta que el plan gratuito de
Google **usa lo que le mandás para entrenar sus modelos**, y hay revisores humanos que pueden
llegar a leerlo. El plan pago no. Mentis te lo avisa antes de encenderlo.

### Lo que puede hacer en tu máquina

| Capacidad | Qué significa |
|---|---|
| **Escribir y borrar archivos** | Crea, modifica y elimina archivos en la carpeta de trabajo. Es para lo que sirve, pero es real. |
| **Ejecutar comandos** | Corre programas en tu sistema. Los comandos destructivos están bloqueados salvo que habilites el modo sin frenos. |
| **Ver tu pantalla** | Puede sacar capturas de lo que tenés abierto y mandárselas al modelo para entender qué estás mirando. |
| **Manejar el mouse y el teclado** | Puede operar tu computadora como lo harías vos. |
| **Encender la cámara** | Saca fotos con la webcam. Tiene un tope de usos por turno para que no pueda quedarse sacando fotos aunque algo salga mal. |
| **Navegar la web** | Abre páginas y las opera. |
| **Controlar hardware** | Si conectás una placa Arduino o similar, puede compilar y grabarle programas: eso mueve cosas en el mundo físico. |
| **Acceder a tu teléfono** | Si lo vinculás, lee notificaciones y mensajes. |

**Todas arrancan apagadas** menos escribir archivos y ejecutar comandos, que son el corazón del
programa. Se prenden de a una, a mano, desde Conectores. Las acciones delicadas piden permiso en
una ventana antes de correr, y el botón **"Frenar ya"** aparece mientras alguna capacidad de
riesgo esté activa.

### Si conectás servicios externos

Mentis puede conectarse a **Google Workspace** (Drive, Docs, Sheets, Gmail y Calendar) y a
**GitHub**. Si lo hacés, Mentis pasa a tener acceso a tu correo, tus documentos y tus
repositorios con tus propios permisos.

GitHub arranca en **modo sólo lectura**, y ninguno de los dos se conecta hasta que vos pongas las
credenciales. Pero vale decirlo claro: conectar tu Gmail es darle acceso a tu Gmail.

### Lo que no hace

No manda nada a ningún servidor del proyecto: no hay cuentas, ni telemetría, ni servidor central.
Tus conversaciones y tu memoria quedan en tu disco. Las claves que cargues quedan en archivos
locales que nunca viajan.

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

## Si querés participar

- **[Cómo contribuir](CONTRIBUTING.md)** — cómo reportar un problema y cómo mandar código.
- **[Código de conducta](CODE_OF_CONDUCT.md)** — es corto: tratá a los demás con respeto.
- **[Seguridad](SECURITY.md)** — si encontraste un agujero, **no lo abras como issue público**:
  ahí está el canal privado.

## Licencia

[Apache 2.0](LICENSE). Podés usarlo, modificarlo y distribuirlo, incluso comercialmente, mientras
mantengas el aviso de licencia y digas qué cambiaste.
