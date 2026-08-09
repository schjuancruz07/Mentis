'use strict';

// Nombres de import/metodo confirmados en API-NOTES.md (Task 1, seccion Client-side API) —
// coinciden con el codigo de ejemplo del brief de Task 2, sin cambios de nombres.
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const { SSEClientTransport } = require('@modelcontextprotocol/sdk/client/sse.js');
const { CallToolResultSchema } = require('@modelcontextprotocol/sdk/types.js');
const fs = require('fs');
const path = require('path');

let servers = {}; // name -> { client, tools }

// Secretos reales (ej. GOOGLE_CLIENT_SECRET) NO viven en mcp-servers.json -- ese JSON solo
// tiene placeholders "${VAR}" y se puede compartir/pegar sin exponer nada. Los valores reales
// se leen de un archivo separado (.secrets.env, junto al JSON, KEY=VALUE por linea) que no se
// versiona (ver mcp-bridge/.gitignore).
function loadSecretsFile(secretsPath) {
  const secrets = {};
  if (!fs.existsSync(secretsPath)) return secrets;
  const raw = fs.readFileSync(secretsPath, 'utf-8');
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    secrets[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
  }
  return secrets;
}

function resolveEnvPlaceholders(envObj, secrets) {
  const resolved = {};
  for (const [key, value] of Object.entries(envObj || {})) {
    if (typeof value !== 'string') { resolved[key] = value; continue; }
    resolved[key] = value.replace(/\$\{([A-Z0-9_]+)\}/g, (_match, name) => {
      if (secrets[name] !== undefined) return secrets[name];
      if (process.env[name] !== undefined) return process.env[name];
      return '';
    });
  }
  return resolved;
}

// Un solo string (URL, un header) con el mismo formato de placeholder "${VAR}" que ya usaba env.
function resolveStringPlaceholders(str, secrets) {
  if (typeof str !== 'string') return str;
  return str.replace(/\$\{([A-Z0-9_]+)\}/g, (_match, name) => {
    if (secrets[name] !== undefined) return secrets[name];
    if (process.env[name] !== undefined) return process.env[name];
    return '';
  });
}

// Conectores remotos (pedido del usuario, 2026-07-13: "que funcione con todo tipo de conectores",
// no solo procesos locales por stdio). type por defecto "stdio" para no romper config vieja.
// "http" = StreamableHTTPClientTransport (MCP moderno), "sse" = SSEClientTransport (legacy).
// OJO (investigacion 2026-07-14): el repo real de "@dguido/google-workspace-mcp" fue ARCHIVADO
// por su dueño el 2026-03-11 -- github.com/dguido/google-workspace-mcp, sin sucesor recomendado.
// Ultima version publicada: 3.4.4 (congelada, sin futuros parches de seguridad/bugs). Por eso
// mcp-servers.json lo pinnea explicito a esa version en vez de dejar que `npx` resuelva
// "@latest" (que hoy da lo mismo, pero deja de ser cierto si alguna vez alguien retoma el repo
// con una version rota). Si en algun momento hace falta migrar, el fork mas activo visto en la
// investigacion es github.com/taylorwilsdon/google_workspace_mcp.
function buildTransport(srv, secrets) {
  const type = srv.type || 'stdio';
  if (type === 'stdio') {
    return new StdioClientTransport({
      command: srv.command,
      args: srv.args || [],
      env: {...process.env,...resolveEnvPlaceholders(srv.env, secrets) }
    });
  }
  if (type === 'http' || type === 'sse') {
    if (!srv.url) throw new Error(`conector remoto '${srv.name}' de tipo '${type}' necesita "url"`);
    const url = new URL(resolveStringPlaceholders(srv.url, secrets));
    const headers = {};
    for (const [k, v] of Object.entries(srv.headers || {})) headers[k] = resolveStringPlaceholders(v, secrets);
    const opts = Object.keys(headers).length > 0 ? { requestInit: { headers } } : undefined;
    return type === 'http' ? new StreamableHTTPClientTransport(url, opts) : new SSEClientTransport(url, opts);
  }
  throw new Error(`tipo de conector desconocido: '${type}' (server '${srv.name}')`);
}

// Estado por conector (pedido del usuario, 2026-07-13: ver cuáles están activos/desactivados) --
// incluye los que fallaron al conectar, no solo los que quedaron levantados con éxito.
let lastStatus = [];

function readConfig(configPath) {
  return JSON.parse(fs.readFileSync(configPath, 'utf-8'));
}

// Resiliencia (mejora encontrada al agregar soporte multi-conector, 2026-07-13): antes UN solo
// server que fallara al conectar (ej. sin API key, servidor caído) tiraba abajo TODA la carga
// -- con más de un conector configurado eso apagaría los que sí funcionan. Ahora cada uno se
// conecta en su propio try/catch; uno roto queda listado como error, no bloquea a los demás.
async function loadServers(configPath) {
  let config;
  try {
    config = readConfig(configPath);
  } catch (err) {
    // Bug real encontrado en auditoria 2026-07-14: si mcp-servers.json queda invalido (ej. una
    // edicion a medias desde la UI de conectores), este throw escapaba de loadServers() sin que
    // nada en server.js tuviera un.catch() -- Node mataba el proceso entero por unhandled
    // rejection, sin escribir el STATE_FILE, y el sintoma visible desde nv-agent.sh era el
    // generico "no se pudo iniciar/conectar al puente MCP" (la causa real quedaba enterrada en
    // server.log.err). Ahora se loguea acá mismo y el bridge sigue arriba sin servers, en vez de
    // morir.
    lastStatus = [];
    console.error(`[mcp-client] mcp-servers.json invalido, arrancando sin conectores: ${err && err.message ? err.message : err}`);
    return lastStatus;
  }
  const secrets = loadSecretsFile(path.join(path.dirname(configPath), '.secrets.env'));
  const status = [];
  for (const srv of config) {
    const enabled = srv.enabled !== false;
    if (!enabled) {
      status.push({ name: srv.name, type: srv.type || 'stdio', enabled: false, connected: false, toolCount: 0, error: null });
      continue;
    }
    try {
      const transport = buildTransport(srv, secrets);
      const client = new Client({ name: 'mentis-mcp-bridge', version: '1.0.0' });
      await client.connect(transport);
      const toolsResult = await client.listTools();
      servers[srv.name] = { client, tools: toolsResult.tools || [] };
      status.push({ name: srv.name, type: srv.type || 'stdio', enabled: true, connected: true, toolCount: (toolsResult.tools || []).length, error: null });
    } catch (err) {
      status.push({ name: srv.name, type: srv.type || 'stdio', enabled: true, connected: false, toolCount: 0, error: String(err && err.message ? err.message : err) });
    }
  }
  lastStatus = status;
  return status;
}

function connectorStatus() {
  return lastStatus;
}

function listAllTools() {
  const out = [];
  for (const [name, entry] of Object.entries(servers)) {
    for (const t of entry.tools) {
      out.push({ server: name, name: t.name, description: t.description || '', inputSchema: t.inputSchema || {} });
    }
  }
  return out;
}

async function callTool(serverName, toolName, args) {
  const entry = servers[serverName];
  if (!entry) {
    throw new Error(`servidor MCP desconocido: ${serverName}`);
  }
  // HALLAZGO Task 7 (verificacion E2E real, ver ERR-032 en la bitacora): NO usamos
  // entry.client.callTool() de alto nivel -- valida result.structuredContent contra el
  // outputSchema que la tool haya declarado, y tira un McpError si no coincide o falta,
  // AUNQUE la tool ya se haya ejecutado bien del lado del servidor (create_text_file/
  // update_text_file de @dguido/google-workspace-mcp declaran outputSchema pero no siempre
  // devuelven structuredContent -- un bug de ESE paquete, no nuestro). Llamamos directo al
  // metodo de protocolo de bajo nivel que callTool() usa por debajo, sin la validacion extra.
  const result = await entry.client.request(
    { method: 'tools/call', params: { name: toolName, arguments: args || {} } },
    CallToolResultSchema
  );
  // HALLAZGO Task 2 (ver API-NOTES.md, "HALLAZGO CRITICO para mcp-client.js"): el protocolo MCP
  // NO rechaza la promise cuando la tool ejecutada en el servidor lanza un error — devuelve un
  // resultado normal con isError:true y el mensaje como contenido de texto. Lo traducimos acá a
  // un throw real para que los callers de mcp-client.js (Task 3/4) reciban un rechazo de
  // promise limpio, como es estandar en JS.
  if (result && result.isError) {
    const message = extractErrorText(result) || `la tool '${toolName}' del servidor '${serverName}' devolvio isError:true`;
    throw new Error(message);
  }
  return result;
}

function extractErrorText(result) {
  if (!Array.isArray(result.content)) return null;
  const textPart = result.content.find((part) => part && part.type === 'text' && typeof part.text === 'string');
  return textPart ? textPart.text : null;
}

async function shutdownAll() {
  // Bug real encontrado en auditoria 2026-07-14: a diferencia de loadServers (que aisla cada
  // conector en su propio try/catch a proposito, ver comentario arriba), esto NO lo hacia -- si
  // el close() de un cliente tiraba (proceso hijo ya muerto, transporte remoto caido), el for
  // cortaba ahi mismo: los servers restantes nunca se cerraban Y `servers = {}` tampoco se
  // ejecutaba, dejando el mapa con entradas obsoletas. Se llama desde /reload y /shutdown -- una
  // reconexion pedida por la UI de conectores podia quedar a mitad de camino.
  for (const entry of Object.values(servers)) {
    try {
      await entry.client.close();
    } catch (err) {
      console.error(`[mcp-client] error cerrando un conector (se sigue con el resto): ${err && err.message ? err.message : err}`);
    }
  }
  servers = {};
}

// Activar/desactivar un conector desde la UI (pedido del usuario, 2026-07-13) sin tener que
// reiniciar toda la conversación: cierra todo lo conectado y vuelve a cargar desde el JSON
// (que la UI ya actualizó con el nuevo enabled:true/false antes de llamar esto).
async function reloadServers(configPath) {
  await shutdownAll();
  return loadServers(configPath);
}

module.exports = { loadServers, reloadServers, listAllTools, callTool, shutdownAll, connectorStatus };
