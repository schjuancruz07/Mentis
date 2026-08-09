'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const actions = require('./browser-actions');

const STATE_FILE = process.env.FABLE_BROWSER_STATE_FILE || path.join(__dirname, '..', 'browser-daemon-state.json');

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

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') {
      return sendJson(res, 200, { ok: true });
    }
    const body = await readBody(req);
    if (req.method === 'POST' && req.url === '/open') {
      return sendJson(res, 200, await actions.openUrl(body.url));
    }
    if (req.method === 'POST' && req.url === '/click') {
      return sendJson(res, 200, await actions.clickElement(body.target));
    }
    if (req.method === 'POST' && req.url === '/fill') {
      return sendJson(res, 200, await actions.fillElement(body.target, body.value));
    }
    if (req.method === 'POST' && req.url === '/scroll') {
      return sendJson(res, 200, await actions.scrollPage(body.direction));
    }
    if (req.method === 'POST' && req.url === '/read') {
      return sendJson(res, 200, await actions.readCurrent());
    }
    if (req.method === 'POST' && req.url === '/shutdown') {
      await actions.shutdownBrowser();
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
  server.listen(0, '127.0.0.1', () => {
    const { port } = server.address();
    fs.writeFileSync(STATE_FILE, JSON.stringify({ pid: process.pid, port }), 'utf-8');
  });
}

module.exports = { server, STATE_FILE };
