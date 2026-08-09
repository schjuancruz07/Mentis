'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const http = require('http');
const path = require('path');
const fs = require('fs');

function req(port, method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const r = http.request(
      { host: '127.0.0.1', port, path: urlPath, method, headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } },
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

test('server responde /health, navega con /open y lee con /read', async () => {
  const testStateFile = path.join(__dirname, 'test-state.json');
  process.env.FABLE_BROWSER_STATE_FILE = testStateFile;
  delete require.cache[require.resolve('./server')];
  delete require.cache[require.resolve('./browser-actions')];
  const { server } = require('./server');
  const actions = require('./browser-actions');

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  try {
    const health = await req(port, 'GET', '/health');
    assert.strictEqual(health.status, 200);
    assert.strictEqual(health.body.ok, true);

    const url = 'data:text/html,' + encodeURIComponent('<html><body><p>Hola servidor</p><a href="#">un link</a></body></html>');
    const opened = await req(port, 'POST', '/open', { url });
    assert.strictEqual(opened.status, 200);
    assert.ok(opened.body.text.includes('Hola servidor'));
    assert.strictEqual(opened.body.elements.length, 1);

    const read = await req(port, 'POST', '/read', {});
    assert.strictEqual(read.status, 200);
    assert.ok(read.body.text.includes('Hola servidor'));

    const clicked = await req(port, 'POST', '/click', { target: '99' });
    assert.strictEqual(clicked.status, 500);
    assert.ok(clicked.body.error);
  } finally {
    await actions.shutdownBrowser();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(testStateFile, { force: true });
  }
});

test('server escribe pid+port al archivo de estado al arrancar escuchando', async () => {
  const testStateFile = path.join(__dirname, 'test-state-2.json');
  process.env.FABLE_BROWSER_STATE_FILE = testStateFile;
  delete require.cache[require.resolve('./server')];
  const { server, STATE_FILE } = require('./server');
  assert.strictEqual(STATE_FILE, testStateFile);

  await new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    const { port } = server.address();
    fs.writeFileSync(STATE_FILE, JSON.stringify({ pid: process.pid, port }), 'utf-8');
    resolve();
  }));

  const written = JSON.parse(fs.readFileSync(testStateFile, 'utf-8'));
  assert.strictEqual(written.pid, process.pid);
  assert.strictEqual(typeof written.port, 'number');

  await new Promise((resolve) => server.close(resolve));
  fs.rmSync(testStateFile, { force: true });
});
