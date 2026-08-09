'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');

test('logCall escribe una linea con server, tool y timestamp', () => {
  const logPath = path.join(os.tmpdir(), `mcp-calls-test-${Date.now()}.log`);
  delete require.cache[require.resolve('./call-logger')];
  process.env.MCP_CALL_LOG_FILE = logPath;
  const { logCall } = require('./call-logger');
  try {
    logCall('google-workspace', 'gmail_send', { to: 'x@y.com' });
    const content = fs.readFileSync(logPath, 'utf-8');
    assert.ok(content.includes('google-workspace'));
    assert.ok(content.includes('gmail_send'));
    assert.ok(/\d{4}-\d{2}-\d{2}T/.test(content), 'incluye timestamp ISO');
  } finally {
    fs.rmSync(logPath, { force: true });
    delete process.env.MCP_CALL_LOG_FILE;
  }
});
