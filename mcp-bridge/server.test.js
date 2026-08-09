'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const http = require('http');
const path = require('path');
const fs = require('fs');
const os = require('os');

function req(port, method, urlPath, body, token) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) };
    if (token) headers['X-Mentis-Token'] = token;
    const r = http.request(
      { host: '127.0.0.1', port, path: urlPath, method, headers },
      (res) => {
        let chunks = '';
        res.on('data', (c) => { chunks += c; });
        res.on('end', () => { resolve({ status: res.statusCode, body: chunks ? JSON.parse(chunks) : null }); });
      }
    );
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

test('server responde /health, /tools con el fixture, y /call invoca echo', async () => {
  const testStateFile = path.join(os.tmpdir(), `mcp-bridge-test-state-${Date.now()}.json`);
  const testConfigFile = path.join(os.tmpdir(), `mcp-bridge-test-config-${Date.now()}.json`);
  fs.writeFileSync(testConfigFile, JSON.stringify([
    { name: 'fixture', command: 'node', args: [path.join(__dirname, 'tests', 'fixture-mcp-server.js')] }
  ]), 'utf-8');
  process.env.MCP_BRIDGE_STATE_FILE = testStateFile;
  process.env.MCP_SERVERS_CONFIG_FILE = testConfigFile;
  delete require.cache[require.resolve('./server')];
  delete require.cache[require.resolve('./mcp-client')];
  const { server, ready, AUTH_TOKEN } = require('./server');
  const mcpClient = require('./mcp-client');

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  await ready;
  const port = server.address().port;

  try {
    // /health no exige token (es el unico endpoint de bajo valor que queda sin proteger).
    const health = await req(port, 'GET', '/health');
    assert.strictEqual(health.status, 200);
    assert.strictEqual(health.body.ok, true);

    // Sin token o con uno invalido, cualquier otro endpoint tiene que rechazar con 401 (hardening
    // 2026-07-14 -- recomendacion oficial de la spec MCP para un proxy HTTP local).
    const noToken = await req(port, 'GET', '/tools');
    assert.strictEqual(noToken.status, 401);
    const badToken = await req(port, 'GET', '/tools', null, 'token-invalido-de-largo-distinto');
    assert.strictEqual(badToken.status, 401);

    const tools = await req(port, 'GET', '/tools', null, AUTH_TOKEN);
    assert.strictEqual(tools.status, 200);
    assert.strictEqual(tools.body.tools.length, 2);

    const called = await req(port, 'POST', '/call', { server: 'fixture', name: 'echo', args: { text: 'ping' } }, AUTH_TOKEN);
    assert.strictEqual(called.status, 200);
    assert.ok(JSON.stringify(called.body).includes('ping'));

    const badServer = await req(port, 'POST', '/call', { server: 'noexiste', name: 'echo', args: {} }, AUTH_TOKEN);
    assert.strictEqual(badServer.status, 500);
  } finally {
    await mcpClient.shutdownAll();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(testStateFile, { force: true });
    fs.rmSync(testConfigFile, { force: true });
    delete process.env.MCP_BRIDGE_STATE_FILE;
    delete process.env.MCP_SERVERS_CONFIG_FILE;
  }
});
