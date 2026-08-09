'use strict';
// Integracion REAL (no mocks) del transporte remoto agregado a mcp-client.js (pedido del usuario,
// 2026-07-13: conectores mas alla de procesos locales por stdio). Levanta un servidor MCP HTTP
// de verdad (tests/fixture-mcp-http-server.js) en un puerto efimero y habla con el via
// StreamableHTTPClientTransport, igual que hablaria con un conector remoto real.
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const mcpClient = require('./mcp-client');
const { startFixtureHttpServer } = require('./tests/fixture-mcp-http-server');

function writeConfig(entries) {
  const configPath = path.join(os.tmpdir(), `mcp-remote-test-config-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(configPath, JSON.stringify(entries), 'utf-8');
  return configPath;
}

test('conector remoto tipo http: conecta, lista tools y ejecuta una tool real', async () => {
  const fixture = await startFixtureHttpServer();
  const configPath = writeConfig([{ name: 'remote-fixture', type: 'http', enabled: true, url: fixture.url }]);
  try {
    const status = await mcpClient.loadServers(configPath);
    assert.strictEqual(status.length, 1);
    assert.strictEqual(status[0].connected, true, JSON.stringify(status));
    assert.strictEqual(status[0].type, 'http');

    const tools = mcpClient.listAllTools();
    const names = tools.filter((t) => t.server === 'remote-fixture').map((t) => t.name).sort();
    assert.deepStrictEqual(names, ['echo', 'fail']);

    const result = await mcpClient.callTool('remote-fixture', 'echo', { text: 'hola remoto' });
    assert.ok(JSON.stringify(result).includes('echo-http: hola remoto'));

    assert.deepStrictEqual(mcpClient.connectorStatus(), status);
  } finally {
    await mcpClient.shutdownAll();
    await fixture.close();
    fs.rmSync(configPath, { force: true });
  }
});

test('conector remoto resuelve placeholders ${VAR} en headers (Authorization real)', async () => {
  process.env.TEST_MCP_TOKEN = 'secreto-123';
  const fixture = await startFixtureHttpServer({ requireAuth: 'Bearer secreto-123' });
  const configPath = writeConfig([{
    name: 'remote-auth', type: 'http', enabled: true, url: fixture.url,
    headers: { Authorization: 'Bearer ${TEST_MCP_TOKEN}' }
  }]);
  try {
    const status = await mcpClient.loadServers(configPath);
    assert.strictEqual(status[0].connected, true, 'debe conectar con el header resuelto correctamente: ' + JSON.stringify(status));
  } finally {
    await mcpClient.shutdownAll();
    await fixture.close();
    fs.rmSync(configPath, { force: true });
    delete process.env.TEST_MCP_TOKEN;
  }
});

test('un conector caido NO tira abajo a los demas (resiliencia)', async () => {
  const fixture = await startFixtureHttpServer();
  const configPath = writeConfig([
    { name: 'roto', type: 'http', enabled: true, url: 'http://127.0.0.1:1/mcp' }, // puerto inexistente
    { name: 'sano', type: 'http', enabled: true, url: fixture.url }
  ]);
  try {
    const status = await mcpClient.loadServers(configPath);
    const roto = status.find((s) => s.name === 'roto');
    const sano = status.find((s) => s.name === 'sano');
    assert.strictEqual(roto.connected, false);
    assert.ok(roto.error, 'el roto tiene que traer un mensaje de error legible');
    assert.strictEqual(sano.connected, true, 'el sano tiene que seguir funcionando pese al otro roto');

    const result = await mcpClient.callTool('sano', 'echo', { text: 'sigo vivo' });
    assert.ok(JSON.stringify(result).includes('sigo vivo'));
    await assert.rejects(() => mcpClient.callTool('roto', 'echo', {}), /servidor MCP desconocido/);
  } finally {
    await mcpClient.shutdownAll();
    await fixture.close();
    fs.rmSync(configPath, { force: true });
  }
});

test('enabled:false se salta sin conectar', async () => {
  const configPath = writeConfig([{ name: 'apagado', type: 'http', enabled: false, url: 'http://127.0.0.1:1/mcp' }]);
  try {
    const status = await mcpClient.loadServers(configPath);
    assert.strictEqual(status.length, 1);
    assert.strictEqual(status[0].enabled, false);
    assert.strictEqual(status[0].connected, false);
    assert.strictEqual(status[0].error, null, 'no debe intentar conectar, asi que no hay error');
    assert.strictEqual(mcpClient.listAllTools().length, 0);
  } finally {
    await mcpClient.shutdownAll();
    fs.rmSync(configPath, { force: true });
  }
});

test('reloadServers reconecta reflejando cambios del config (toggle en vivo)', async () => {
  const fixture = await startFixtureHttpServer();
  const configPath = writeConfig([{ name: 'toggle-me', type: 'http', enabled: false, url: fixture.url }]);
  try {
    let status = await mcpClient.loadServers(configPath);
    assert.strictEqual(status[0].connected, false);
    assert.strictEqual(mcpClient.listAllTools().length, 0);

    // La UI reescribiria mcp-servers.json con enabled:true y llamaria a /reload -> reloadServers.
    fs.writeFileSync(configPath, JSON.stringify([{ name: 'toggle-me', type: 'http', enabled: true, url: fixture.url }]), 'utf-8');
    status = await mcpClient.reloadServers(configPath);
    assert.strictEqual(status[0].connected, true, JSON.stringify(status));
    assert.strictEqual(mcpClient.listAllTools().length, 2);
  } finally {
    await mcpClient.shutdownAll();
    await fixture.close();
    fs.rmSync(configPath, { force: true });
  }
});
