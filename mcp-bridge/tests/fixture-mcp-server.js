'use strict';

// Server MCP minimo para tests (Task 2). Expone 2 tools de prueba: `echo` y `fail`.
// API server-side confirmada en API-NOTES.md (seccion "Server-side API"):
// - McpServer (server/mcp.js) es la API de alto nivel usada acá, no el `Server` de bajo nivel.
// - registerTool(name, config, cb) es la forma recomendada (no `tool(...)`, marcada como
//   frozen/legacy en el propio SDK).
// - inputSchema en config espera un zod raw shape, no JSON Schema crudo.
// - El handler recibe (args, extra) cuando hay inputSchema presente (incluso vacio {}).
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { z } = require('zod');

const server = new McpServer({ name: 'fixture-mcp-server', version: '1.0.0' });

server.registerTool(
  'echo',
  {
    description: 'Devuelve el texto recibido, prefijado con "echo: "',
    inputSchema: { text: z.string() }
  },
  async (args) => {
    return { content: [{ type: 'text', text: `echo: ${args.text}` }] };
  }
);

server.registerTool(
  'fail',
  {
    description: 'Siempre tira un error, para probar el manejo de errores de callTool',
    inputSchema: {}
  },
  async () => {
    throw new Error('fail tool always fails');
  }
);

const transport = new StdioServerTransport();
server.connect(transport);
