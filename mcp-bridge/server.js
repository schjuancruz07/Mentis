'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const mcpClient = require('./mcp-client');
const { logCall } = require('./call-logger');

const STATE_FILE = process.env.MCP_BRIDGE_STATE_FILE || path.join(__dirname, '..', 'mcp-bridge-state.json');
const CONFIG_FILE = process.env.MCP_SERVERS_CONFIG_FILE || path.join(__dirname, 'mcp-servers.json');

// Token de auth (investigacion 2026-07-14: la spec oficial de MCP -- "stdio Transport Security
// in Proxy Scenarios", modelcontextprotocol.io/docs/tutorials/security/security_best_practices --
// recomienda explicitamente "require an authorization token" para un proxy HTTP local como este,
// en vez de confiar en que 127.0.0.1 sea suficiente. El vector real: una pestaña de navegador con
// contenido malicioso puede mandar un POST a un puerto localhost sin que CORS lo bloquee del lado
// del request (bloquea LEER la respuesta, no ENVIAR el pedido) -- justo el patron de CVE-2025-49596
// contra el MCP Inspector oficial de Anthropic. El token se genera una vez por proceso, se guarda
// en el mismo STATE_FILE que ya comparten main.js/nv-agent.sh para el puerto, asi que ambos
// llamadores legitimos lo leen del mismo lugar sin config nueva.
const AUTH_TOKEN = crypto.randomBytes(24).toString('hex');

function isAuthorized(req) {
  const header = req.headers['x-mentis-token'];
  if (typeof header !== 'string' || header.length !== AUTH_TOKEN.length) return false;
  try {
    return crypto.timingSafeEqual(Buffer.from(header), Buffer.from(AUTH_TOKEN));
  } catch {
    return false;
  }
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

const ready = mcpClient.loadServers(CONFIG_FILE);

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') {
      return sendJson(res, 200, { ok: true });
    }
    if (!isAuthorized(req)) {
      return sendJson(res, 401, { error: 'falta o es invalido el header X-Mentis-Token' });
    }
    if (req.method === 'GET' && req.url === '/tools') {
      return sendJson(res, 200, { tools: mcpClient.listAllTools() });
    }
    if (req.method === 'GET' && req.url === '/connectors') {
      return sendJson(res, 200, { connectors: mcpClient.connectorStatus() });
    }
    // Conectores (pedido del usuario, 2026-07-13): la UI edita mcp-servers.json (enabled:true/false)
    // y pega acá para que el bridge YA levantado tome el cambio sin reiniciar la conversación.
    if (req.method === 'POST' && req.url === '/reload') {
      const status = await mcpClient.reloadServers(CONFIG_FILE);
      return sendJson(res, 200, { connectors: status });
    }
    if (req.method === 'POST' && req.url === '/call') {
      const body = await readBody(req);
      logCall(body.server, body.name, body.args);
      const result = await mcpClient.callTool(body.server, body.name, body.args);
      return sendJson(res, 200, { result });
    }
    if (req.method === 'POST' && req.url === '/shutdown') {
      await mcpClient.shutdownAll();
      sendJson(res, 200, { ok: true });
      setTimeout(() => { server.close(); process.exit(0); }, 50);
      return;
    }
    sendJson(res, 404, { error: 'ruta desconocida' });
  } catch (err) {
    sendJson(res, 500, { error: String(err && err.message ? err.message : err) });
  }
});

if (require.main === module) {
  const startListening = () => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      fs.writeFileSync(STATE_FILE, JSON.stringify({ pid: process.pid, port, token: AUTH_TOKEN }), 'utf-8');
    });
  };
  //.catch() de defensa en profundidad (bug real encontrado en auditoria 2026-07-14): loadServers
  // ya no tira por un mcp-servers.json invalido (se maneja adentro), pero si algun dia rechaza
  // por otra razon no prevista, esto evita que Node mate el proceso entero por unhandled
  // rejection antes de escuchar el puerto -- el bridge arranca igual, sin conectores.
  ready.then(startListening).catch((err) => {
    console.error(`[mcp-bridge] loadServers rechazo inesperado, arrancando igual sin conectores: ${err && err.message ? err.message : err}`);
    startListening();
  });
}

module.exports = { server, ready, STATE_FILE, AUTH_TOKEN };
