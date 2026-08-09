'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const mcpClient = require('./mcp-client');

function writeTestConfig() {
  const configPath = path.join(os.tmpdir(), `mcp-test-config-${Date.now()}.json`);
  const config = [
    {
      name: 'fixture',
      command: 'node',
      args: [path.join(__dirname, 'tests', 'fixture-mcp-server.js')]
    }
  ];
  fs.writeFileSync(configPath, JSON.stringify(config), 'utf-8');
  return configPath;
}

test('loadServers conecta al server fixture y listAllTools devuelve sus 2 tools', async () => {
  const configPath = writeTestConfig();
  try {
    await mcpClient.loadServers(configPath);
    const tools = mcpClient.listAllTools();
    assert.strictEqual(tools.length, 2, 'el fixture expone 2 tools');
    const names = tools.map((t) => t.name).sort();
    assert.deepStrictEqual(names, ['echo', 'fail']);
    assert.strictEqual(tools[0].server, 'fixture');
  } finally {
    await mcpClient.shutdownAll();
    fs.rmSync(configPath, { force: true });
  }
});

test('callTool invoca echo y devuelve el texto esperado', async () => {
  const configPath = writeTestConfig();
  try {
    await mcpClient.loadServers(configPath);
    const result = await mcpClient.callTool('fixture', 'echo', { text: 'hola mentis' });
    const text = JSON.stringify(result);
    assert.ok(text.includes('hola mentis'), `el resultado deberia incluir el texto: ${text}`);
  } finally {
    await mcpClient.shutdownAll();
    fs.rmSync(configPath, { force: true });
  }
});

test('callTool con la tool fail propaga un error', async () => {
  const configPath = writeTestConfig();
  try {
    await mcpClient.loadServers(configPath);
    await assert.rejects(() => mcpClient.callTool('fixture', 'fail', {}));
  } finally {
    await mcpClient.shutdownAll();
    fs.rmSync(configPath, { force: true });
  }
});

test('callTool con servidor desconocido tira error legible', async () => {
  const configPath = writeTestConfig();
  try {
    await mcpClient.loadServers(configPath);
    await assert.rejects(() => mcpClient.callTool('noexiste', 'echo', {}), /servidor MCP desconocido/);
  } finally {
    await mcpClient.shutdownAll();
    fs.rmSync(configPath, { force: true });
  }
});
