# Instalar Mentis

Mentis es un asistente que corre **entero en tu computadora**. Habla, escucha, lee documentos,
busca en internet y puede hacer cosas en tu máquina si vos se lo permitís.

Esta copia viene **vacía**: sin conversaciones, sin memorias y sin las claves de nadie. Todo lo que
guardes a partir de ahora es tuyo y se queda acá.

---

## Si tenés Claude, pedile que lo haga por vos

Copiá y pegale esto:

> Instalá Mentis siguiendo `INSTALAR.md` que está en esta carpeta. Corré los pasos, decime qué
> falta y guiame en lo que tenga que hacer yo a mano.

Y seguí lo que te vaya diciendo. Lo único que **no** puede hacer por vos es crear la cuenta de
NVIDIA y copiar la clave: eso es tuyo.

---

## Si lo hacés a mano

### 1. Lo que tiene que estar instalado

Abrí una terminal en esta carpeta y corré:

```bash
bash mentis-instalar.sh revisar
```

Te va a decir qué falta. Lo necesario:

| programa | para qué | dónde |
|---|---|---|
| **Git Bash** | correr todo | https://git-scm.com/downloads |
| **Python 3** | el motor | https://www.python.org/downloads/ (tildá "Add to PATH") |
| **Node.js** | la ventana de Mentis | https://nodejs.org/ |

`curl` viene con Git Bash. `git` es opcional (sirve para deshacer cambios).

### 2. La clave de NVIDIA (gratis)

Mentis piensa con modelos que corren en los servidores de NVIDIA. Hace falta una clave, es
gratuita y no pide tarjeta:

1. Entrá a **https://build.nvidia.com/** y creá una cuenta.
2. Generá una API key. Empieza con `nvapi-`.
3. Copiala.

### 3. Configurar

```bash
bash mentis-instalar.sh configurar
```

Te va a pedir la clave y cómo querés que te llame. Después prueba sola que Mentis conteste.

### 4. La ventana

Una sola vez:

```bash
cd app
npm install
npm run empaquetar
```

Eso deja `dist/Mentis-win32-x64/Mentis.exe`. Hacele un acceso directo en el escritorio.

---

## Cómo se usa

- **La ventana**: abrí `Mentis.exe`. Escribile o apretá el micrófono.
- **Desde el celular**: con Mentis abierto, el servidor de la página se prende solo. Corré
  `bash mentis-web.sh prender` para ver la dirección, abrila en el teléfono y guardala en
  favoritos. Tiene que estar en la misma WiFi (o usar Tailscale, más abajo).
  Desde el celular Mentis **no puede** escribir archivos, ejecutar comandos, mirar la pantalla ni
  prender la cámara. Es a propósito.

### Lo que además sabe hacer

Ninguna de estas necesita instalar nada aparte:

- **Departamentos** (`mentis-departamento.sh correr cobranzas "..."`): perfiles de trabajo con
  libro mayor. Dejan el entregable en un archivo fijo y **se verifica contra el disco**, no contra
  lo que el modelo dice haber hecho.
- **Study y Science**: estudiar un corpus propio y ver química en 3D con datos reales de PubChem.
- **Modo Editor**: editar video entero con ffmpeg, sin línea de tiempo.
- **3D y CAD**: analizar mallas y generar piezas paramétricas en STEP.
- **Buscar imágenes por lo que se ve** (`mentis-imagenes.sh indexar` y después
  `mentis-imagenes.sh buscar "la captura del error"`).
- **Aprender mirando** (`mentis-aprender-mirando.sh grabar`): hacés una tarea, y de ahí sale una
  skill. No guarda lo que escribís, sólo la secuencia de acciones.
- **Analizar un video** siguiendo la secuencia, no cinco fotos sueltas.

---

## Ponerlo a tu gusto

Abrí **Configuración** (el engranaje) → **Apariencia**:

- **El nombre**: no es sólo la etiqueta de la ventana. Se va a presentar con ese nombre y lo va a
  usar al hablarte, también por voz. Si lo dejás vacío, se llama Mentis.
- **El color**: 6 paletas, una clara. El color que elijas también se aplica en la página del
  celular.

---

## Lo opcional

**Nada de esto hace falta.** Sin ninguna de estas claves, Mentis busca en internet, lee documentos,
te habla, mira la pantalla, maneja archivos y se acuerda de lo que hablaron. Esto es sólo lo extra:

| qué | para qué | ¿conviene? |
|---|---|---|
| **Ideogram** | generar imágenes | **Es pago.** Sólo si vas a generar imágenes seguido |
| **Runway** | generar video | **Es pago** y caro |
| **NASA** | la foto astronómica del día | **No hace falta**: ya funciona sin clave |
| **ElevenLabs** | voz más natural | **No te conviene.** Ver abajo |
| **Google Workspace** | Drive, Docs, Gmail, Calendar | Sí, si usás Google. Es el trámite más largo |
| **Tailscale** | entrar desde el celular fuera de casa | Sí, si querés usarlo desde la calle |
| **KDE Connect** | conectar el teléfono | Opcional |

Las tres primeras te las pide `bash mentis-instalar.sh configurar` y las guarda solas.

### Sobre ElevenLabs: por qué te digo que no

El plan gratis da **10 créditos por mes por API** — unos 20 caracteres, o sea media palabra. Los
10.000 caracteres que figuran en su página son para la web, **no para la API**. La voz de NVIDIA
que ya viene incluida funciona bien y no tiene ese límite.

### Google Workspace (Drive, Docs, Sheets, Gmail, Calendar)

El conector **ya está armado y activado** en Mentis. Lo único que falta son tus credenciales. Es
largo, así que conviene que se lo pidas a tu Claude:

> Ayudame a crear las credenciales OAuth de Google para Mentis: proyecto en Google Cloud, habilitar
> las APIs de Drive, Docs, Sheets, Slides, Calendar, Gmail y Contacts, y la pantalla de
> consentimiento en modo Testing con mi cuenta como usuario de prueba. Después ponelas en
> `mcp-bridge/mcp-servers.json`, en `env`, como `GOOGLE_CLIENT_ID` y `GOOGLE_CLIENT_SECRET`.

A grandes rasgos: entrás a https://console.cloud.google.com/, creás un proyecto, habilitás esas
siete APIs, configurás la pantalla de consentimiento (tipo **Externo**, en modo **Testing**, con tu
mail como usuario de prueba) y creás credenciales de **ID de cliente de OAuth** para aplicación de
escritorio.

### Tailscale (usar Mentis desde afuera de casa)

Sin esto, la página del celular anda sólo estando en la misma WiFi.

1. Creá una cuenta gratis en https://tailscale.com/
2. Instalalo en la computadora **y** en el celular, con la **misma cuenta**.
3. Prendé Tailscale en los dos.
4. Corré `bash mentis-web.sh prender`: la segunda dirección que te muestra (la que empieza con
   `100.`) es la que funciona desde cualquier lado.

Tailscale **no abre nada al mundo**: arma una red privada entre tus propios dispositivos. La
dirección `100.x.y.z` no existe fuera de esa red.

**La computadora tiene que estar prendida.** Mentis corre en tu máquina; el teléfono es una
ventana, no una copia. Con la computadora apagada no hay con quién hablar.

### Instalarlo en el celular como una app (sin Play Store)

La página del celular se puede instalar como una app de verdad: ícono propio, pantalla completa y
sin barra de direcciones. No pasa por ninguna tienda.

Hace falta un paso previo que sólo podés hacer vos, una vez y gratis:

1. Entrá a https://login.tailscale.com/admin/dns
2. En **HTTPS Certificates**, apretá **Enable**.
3. Con Mentis abierto, corré `bash mentis-web.sh https`.
4. Abrí en el celular la dirección `https://...` que te muestra.
5. Menú de Chrome → **Instalar aplicación** (o "Agregar a pantalla de inicio").

Por qué el paso 2: los navegadores sólo dejan instalar una página si viene por HTTPS. La dirección
`100.x.y.z` es HTTP, así que sin ese permiso la página funciona igual pero no se puede instalar.

Para dejar de publicarla: `bash mentis-web.sh https-apagar`.

### KDE Connect (el teléfono)

1. Instalá KDE Connect en la computadora y en el celular (está en Play Store).
2. Emparejalos: los dos tienen que estar en la misma WiFi.
3. **Ojo con el firewall de Windows.** Suele bloquear KDE Connect sin avisar, y el síntoma es que
   los dispositivos no se ven. Si pasa, hay que permitir `kdeconnectd` en el Firewall de Windows —
   pedile a tu Claude que te guíe, y tené a mano la contraseña de administrador.

---

## Si algo no anda

```bash
bash mentis-instalar.sh revisar     # qué falta
bash mentis-modelos.sh -p           # ¿los modelos contestan?
bash mentis-web.sh estado           # la página del celular
```

**"Mentis no contesta"** — casi siempre es la clave de NVIDIA o que sus servidores están saturados
(pasa, y se arregla solo). Probá `bash mentis-modelos.sh -p`: si dice SATURADO, esperá un rato.

**"Desde el celular no entra"** — `bash mentis-web.sh estado` te dice por qué. La causa más común
es que Mentis esté cerrado: la página vive con la app.

---

## Lo que tenés que saber

- **Todo se queda en tu máquina.** Las conversaciones y las memorias son archivos tuyos.
- **A los modelos de NVIDIA sí les llega lo que le escribís**, porque ahí es donde piensa. Antes de
  salir, Mentis enmascara claves, mails, CUIT y CBU que detecte, pero no le cuentes cosas que no le
  contarías a un servicio en internet.
- **Los permisos son tuyos.** Escribir archivos, ejecutar comandos, ver la pantalla y la cámara se
  activan por separado, y la cámara arranca apagada.
