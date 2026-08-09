# API-NOTES.md — `@modelcontextprotocol/sdk` (versión real instalada)

Fuente de verdad para Tasks 2-4 del plan `2026-07-07-mentis-mcp-bridge.md`. Si algo acá
difiere del código de ejemplo del plan, este archivo manda.

## Versión instalada

- Declarado en `package.json`: `^1.0.0`
- Versión real resuelta por npm: **`1.29.0`** (ver `node_modules/@modelcontextprotocol/sdk/package.json`)
- `npm install` con `^1.0.0` funcionó sin error — no hizo falta correr `npm view... versions`
  ni tocar `package.json`.
- El paquete raíz tiene `"type": "module"`, pero `require('@modelcontextprotocol/sdk/client/index.js')`
  y `require('@modelcontextprotocol/sdk/client/stdio.js')` funcionan igual vía `require()` de
  CommonJS (Node 24.16.0 en este entorno) — el subpath expone un build compatible. No hizo falta
  usar `import()` dinámico.

## Client-side API (confirmado con `node -e` contra el paquete instalado)

### Import path exacto

```js
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');
```

Exports reales de `client/index.js`: `Client`, `getSupportedElicitationModes`.
Exports reales de `client/stdio.js`: `StdioClientTransport`, `DEFAULT_INHERITED_ENV_VARS`,
`getDefaultEnvironment`.

Estos nombres coinciden EXACTAMENTE con los asumidos en el código de ejemplo de Task 2 del
plan — no hace falta renombrar nada ahí.

### Constructor de `Client`

```js
class Client extends Protocol {
  constructor(_clientInfo, options) {... }
}
```

Firma: `new Client(clientInfo, options)` — `clientInfo` es el primer arg posicional (ej.
`{ name: 'mentis-mcp-bridge', version: '1.0.0' }`), `options` es opcional (`capabilities`,
`jsonSchemaValidator`, `listChanged`, etc.). El código de ejemplo del plan (`new Client({ name:
..., version:... })`) es válido: pasa el objeto de info como primer arg y omite `options`.

### Constructor de `StdioClientTransport`

```js
class StdioClientTransport {
  constructor(server) {... }
}
```

Toma UN objeto `server` con (al menos) `command`, `args`, `env`, `stderr`. El código de ejemplo
del plan (`new StdioClientTransport({ command, args, env })`) es correcto.

### Conectar

`client.connect(transport)` — existe en `Client.prototype` (heredado indirectamente vía
`Protocol.prototype.connect`, pero se llama igual sobre la instancia de `Client`). Es async
(devuelve promise).

### Listar tools

`client.listTools()` — existe en `Client.prototype`, es async. **No verificado en este Task
con un server real corriendo** (eso lo hace Task 2 con el fixture) — la firma exacta del
resultado (`{ tools: [...] }` con qué campos por tool) se confirma ahí. Es razonable asumir
`.tools` como array (estándar del protocolo MCP) según el código de ejemplo del plan.

### Llamar una tool

`client.callTool(...)` — existe en `Client.prototype`, es async. El plan asume
`client.callTool({ name: toolName, arguments: args })` — nombre de método confirmado, forma
exacta del argumento a confirmar en Task 2 contra el fixture real.

### Cerrar la conexión

**IMPORTANTE — no es un método propio de `Client.prototype`.** `close()` NO aparece en
`Object.getOwnPropertyNames(Client.prototype)`. Client extiende `Protocol`
(`class Client extends protocol_js_1.Protocol`), y `close` vive en `Protocol.prototype`. Se
sigue llamando igual sobre una instancia de `Client` (`await client.close()`) porque JS resuelve
métodos heredados por la cadena de prototipos — el código de ejemplo del plan
(`entry.client.close()`) funciona sin cambios, pero quede anotado que el método es heredado, no
propio, por si alguna herramienta de introspección más estricta (`hasOwnProperty`) lo pasara
por alto.

### Otros métodos relevantes disponibles en `Client.prototype`

`getServerCapabilities`, `getServerVersion`, `getInstructions`, `ping`, `getPrompt`,
`listPrompts`, `listResources`, `listResourceTemplates`, `readResource`, `setLoggingLevel`.
No usados por este plan pero podrían ser útiles más adelante (ej. `getServerVersion` para
diagnóstico en logs).

## Output real del comando de introspección (Step 3, íntegro)

```
Client export: [ 'Client', 'getSupportedElicitationModes' ]
StdioClientTransport export: [
  'DEFAULT_INHERITED_ENV_VARS',
  'StdioClientTransport',
  'getDefaultEnvironment'
]
Client.prototype methods: [
  'constructor',
  '_setupListChangedHandlers',
  'registerCapabilities',
  'setRequestHandler',
  'assertCapability',
  'connect',
  'getServerCapabilities',
  'getServerVersion',
  'getInstructions',
  'assertCapabilityForMethod',
  'assertNotificationCapability',
  'assertRequestHandlerCapability',
  'assertTaskCapability',
  'assertTaskHandlerCapability',
  'ping',
  'complete',
  'setLoggingLevel',
  'getPrompt',
  'listPrompts',
  'listResources',
  'listResourceTemplates',
  'readResource',
  'subscribeResource',
  'unsubscribeResource',
  'callTool',
  'isToolTask',
  'isToolTaskRequired',
  'cacheToolMetadata',
  'getToolOutputValidator',
  'listTools',
  '_setupListChangedHandler',
  'sendRootsListChanged'
]
```

## Conclusión para Task 2 (mcp-client.js)

El código de ejemplo del plan (imports, constructor de `Client`/`StdioClientTransport`,
`connect`, `listTools`, `callTool`, `close`) es utilizable **sin cambios de nombres** contra la
versión 1.29.0 realmente instalada. La única verificación pendiente (no un mismatch conocido,
solo algo no probado todavía en este Task) es la forma exacta del objeto resultado de
`listTools()` y `callTool()` en runtime contra un server real — eso lo confirma Task 2 con el
server fixture y sus tests. No se detectó ningún discrepancia grande que amerite
NEEDS_CONTEXT.

## Server MCP candidato: `@dguido/google-workspace-mcp` (Step 5)

Verificado con `npx --yes @dguido/google-workspace-mcp --help`:

- El paquete existe en npm y `npx --yes` lo descarga e instala sin error.
- Versión resuelta: **v3.4.4**.
- Expone subcomandos: `auth` (corre el flujo de autenticación), `start` (arranca el server MCP,
  default), `version`, `help`.
- Opciones: `--profile <name>` (perfil nombrado de credenciales/tokens), `--token-path <path>`.
- Rutas default de credenciales/tokens en este entorno Windows:
  - Credentials: `C:/Users/<usuario>\.config\google-workspace-mcp\credentials.json`
  - Tokens: `C:/Users/<usuario>\.config\google-workspace-mcp\tokens.json`
  - Con `--profile <name>`: `C:/Users/<usuario>\.config\google-workspace-mcp\profiles\<name>\credentials.json`
    (y `tokens.json` análogo)

Confirma que es un candidato válido: instala vía `npx`, expone ayuda coherente con un server MCP
real de Google Workspace. **No se verificó el arranque completo con OAuth** — eso es explícitamente
fuera de alcance de este Task 1 (Step 5) y corresponde a Task 7 (verificación E2E con el usuario
completando el login manualmente). Nota para Task 7: las rutas de credenciales/tokens de arriba
son donde hay que colocar el `credentials.json` de OAuth de Google Cloud antes de correr
`auth`, y donde quedará guardado el token tras el primer login exitoso.

## Server-side API (confirmado en Task 2, `node -e` contra el paquete instalado)

Introspección hecha con el mismo patrón que Task 1 (Step 3), apuntando a
`@modelcontextprotocol/sdk/server/index.js`, `@modelcontextprotocol/sdk/server/stdio.js` y
`@modelcontextprotocol/sdk/server/mcp.js`.

### Dos APIs de servidor disponibles — se usó la de alto nivel

- `server/index.js` exporta `Server` (bajo nivel: `setRequestHandler`, sin métodos `tool`/
  `registerTool`). Requiere registrar handlers de protocolo a mano (`ListToolsRequestSchema`,
  `CallToolRequestSchema`, etc.).
- `server/mcp.js` exporta `McpServer` (alto nivel, envuelve un `Server` internamente vía
  `this.server = new Server(serverInfo, options)`) y `ResourceTemplate`. Expone `tool(...)`,
  `registerTool(name, config, cb)`, `resource(...)`, `prompt(...)`, `connect(transport)`,
  `close()`. **Se usó `McpServer` para el fixture** — es la API de alto nivel y evita reinventar
  el enrutamiento de protocolo para un fixture de tests.

### Import path exacto (server)

```js
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
```

### Constructor de `McpServer`

`new McpServer(serverInfo, options)` — mismo patrón que `Client`: `serverInfo` es
`{ name, version }`, `options` opcional. Internamente crea `new Server(serverInfo, options)`.

### Registrar una tool: `registerTool(name, config, cb)` (NO `tool(name,...rest)`)

`McpServer.prototype` tiene DOS formas de registrar tools:
- `tool(name,...rest)` — API legacy con args posicionales variádicos (`description` opcional,
  luego `inputSchema`/`outputSchema`/`annotations` en distintas combinaciones vía overloads). El
  código fuente la marca explícitamente: *"Support for this style is frozen as of protocol
  version 2025-03-26. Future additions to tool definition should NOT be added."*
- `registerTool(name, config, cb)` — API recomendada, 3 args fijos. `config` es
  `{ title, description, inputSchema, outputSchema, annotations, _meta }` (todos opcionales
  salvo que se quiera validación). **Se usó esta forma en el fixture** por ser la soportada
  activamente.

`inputSchema` en `config` espera un **zod raw shape** (objeto plano de `{campo: zodType}`, ej.
`{ text: z.string() }}`), no un JSON Schema crudo — el SDK lo convierte a JSON Schema
internamente (`getZodSchemaObject`) para exponerlo vía `listTools()`. Con `inputSchema: {}` (v.
`fail`) el resultado expuesto es `{ type: 'object', properties: {} }` sin `required`.

### `zod` no es dependencia directa del proyecto — pero resuelve igual

`mcp-bridge/package.json` (Task 1) solo declara `@modelcontextprotocol/sdk` como dependency.
`zod` es dependencia transitiva del SDK (`node_modules/zod`, v4.4.3 resuelta) y
`require('zod')` funciona sin declararla aparte porque Node la encuentra subiendo el árbol de
`node_modules`. Funciona hoy; si se quiere blindar contra un futuro cambio de resolución
transitiva de npm convendría agregar `zod` como dependency explícita — no se hizo en este Task
por no estar pedido en el brief, queda anotado como riesgo menor.

### El handler de la tool recibe `(args, extra)`

Confirmado leyendo `McpServer.prototype.executeToolHandler`: cuando la tool tiene
`inputSchema`, el handler se llama como `handler(args, extra)` (args ya parseados/validados
por zod). Sin `inputSchema`, se llama como `handler(extra)` únicamente — por eso el fixture le
da a `fail` un `inputSchema: {}` (objeto vacío pero presente) para mantener la firma
`(args, extra)` uniforme entre ambas tools.

### `StdioServerTransport`

`new StdioServerTransport()` sin argumentos usa `process.stdin`/`process.stdout` por default
(hay overload con params `_stdin`/`_stdout` para tests, no usado acá). `server.connect(transport)`
llama a `transport.start()` internamente.

### HALLAZGO CRÍTICO para `mcp-client.js` — `callTool` del lado CLIENTE no rechaza en error de tool

Verificado con un probe real end-to-end (server `McpServer` + tool `fail` que hace `throw new
Error(...)`, cliente `Client.callTool(...)` contra ese server por stdio):

```
callTool(fail) DID NOT THROW, result: {
  "content": [ { "type": "text", "text": "fail tool always fails" } ],
  "isError": true
}
```

`client.callTool(...)` **no lanza** (no rechaza la promise) cuando la tool ejecutada en el
servidor lanza un error — el protocolo MCP estándar devuelve un resultado normal con
`isError: true` y el mensaje de error como contenido de texto. Esto es el
comportamiento documentado del protocolo (errores de ejecución de tool vs. errores de
protocolo/transporte son cosas distintas), pero **difiere de lo que el test de Task 2 asume**
(`assert.rejects(() => mcpClient.callTool('fixture', 'fail', {}))`).

**Implicación directa para `mcp-client.js` (Task 2, Step 5):** la función `callTool` de
`mcp-client.js` NO puede devolver crudo lo que devuelve `client.callTool(...)` — debe inspeccionar
`result.isError` y, si es `true`, lanzar un `Error` ella misma (con el texto del contenido como
mensaje) para que el error se propague como rechazo de promise, tal como el test del brief
espera. Esto no es un mismatch de nombres de API (los nombres son correctos, calzan con lo
documentado en la sección Client-side de arriba) sino una diferencia de **forma del resultado**
que el propio Task 1 dejó marcada como pendiente de confirmar ("la firma exacta del resultado
... se confirma [en Task 2] con el fixture real" — ver sección Client-side, "Listar tools" /
"Llamar una tool" arriba). Documentado acá para que Task 3/Task 4 (que consumen `callTool` de
`mcp-client.js`) sepan que YA reciben un rechazo limpio, no tienen que repetir esta lógica.

### Output real del comando de introspección server-side (íntegro)

```
server/index.js export: [ 'Server' ]
server/stdio.js export: [ 'StdioServerTransport' ]
server/mcp.js export: [ 'McpServer', 'ResourceTemplate' ]
McpServer.prototype methods: [
  'constructor', 'experimental', 'connect', 'close',
  'setToolRequestHandlers', 'createToolError', 'validateToolInput', 'validateToolOutput',
  'executeToolHandler', 'handleAutomaticTaskPolling', 'setCompletionRequestHandler',
  'handlePromptCompletion', 'handleResourceCompletion', 'setResourceRequestHandlers',
  'setPromptRequestHandlers', 'resource', 'registerResource', '_createRegisteredResource',
  '_createRegisteredResourceTemplate', '_createRegisteredPrompt', '_createRegisteredTool',
  'tool', 'registerTool', 'prompt', 'registerPrompt', 'isConnected',
  'sendLoggingMessage', 'sendResourceListChanged', 'sendToolListChanged', 'sendPromptListChanged'
]
```

## Conclusión para Task 2 (fixture + mcp-client.js)

El fixture (`tests/fixture-mcp-server.js`) se escribió con `McpServer` + `registerTool` + `zod`
según lo confirmado arriba. `mcp-client.js` se escribió con los nombres de método ya confirmados
por Task 1 en la sección Client-side (`Client`, `StdioClientTransport`, `connect`, `listTools`,
`callTool`, `close`), **más un ajuste no anticipado por Task 1**: traducir `isError: true` del
resultado de `callTool` en un `throw` explícito, para que los errores de ejecución de tools MCP
se propaguen como rechazos de promise en la capa `mcp-client.js` (ver hallazgo crítico arriba).
