'use strict';

// Fixture MCP server remoto (HTTP), para probar de verdad el transporte remoto agregado a
// mcp-client.js (pedido del usuario, 2026-07-13: "que funcione con todo tipo de conectores", no
// solo procesos locales por stdio). A diferencia de fixture-mcp-server.js (stdio, corre como
// proceso hijo), este corre EN PROCESO como servidor HTTP real en un puerto efimero -- no usa
// express (no es una dependencia declarada del bridge), maneja el request Node crudo y se lo
// pasa a StreamableHTTPServerTransport.handleRequest, que es agnostico de framework.
const http = require('http');
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StreamableHTTPServerTransport } = require('@modelcontextprotocol/sdk/server/streamableHttp.js');
const { z } = require('zod');

function buildServer() {
  const server = new McpServer({ name: 'fixture-mcp-http-server', version: '1.0.0' });
  server.registerTool(
    'echo',
    { description: 'Devuelve el texto recibido, prefijado con "echo-http: "', inputSchema: { text: z.string() } },
    async (args) => ({ content: [{ type: 'text', text: `echo-http: ${args.text}` }] })
  );
  server.registerTool(
    'fail',
    { description: 'Siempre tira un error', inputSchema: {} },
    async () => { throw new Error('fail-http tool always fails'); }
  );
  return server;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => { data += c; });
    req.on('end', () => {
      if (!data) return resolve(undefined);
      try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

// requireAuth: si se pasa, exige ese valor exacto en el header Authorization (para probar que
// los headers con placeholders "${VAR}" resueltos de mcp-servers.json llegan de verdad).
function startFixtureHttpServer({ requireAuth } = {}) {
  const httpServer = http.createServer(async (req, res) => {
    if (req.method !== 'POST' || req.url !== '/mcp') {
      res.writeHead(404).end();
      return;
    }
    if (requireAuth && req.headers.authorization !== requireAuth) {
      res.writeHead(401).end(JSON.stringify({ error: 'unauthorized' }));
      return;
    }
    const server = buildServer();
    try {
      const parsedBody = await readJsonBody(req);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      await server.connect(transport);
      await transport.handleRequest(req, res, parsedBody);
      res.on('close', () => { transport.close(); server.close(); });
    } catch (err) {
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32603, message: String(err) }, id: null }));
      }
    }
  });

  return new Promise((resolve) => {
    httpServer.listen(0, '127.0.0.1', () => {
      const { port } = httpServer.address();
      resolve({
        url: `http://127.0.0.1:${port}/mcp`,
        close: () => new Promise((r) => httpServer.close(r))
      });
    });
  });
}

module.exports = { startFixtureHttpServer };
