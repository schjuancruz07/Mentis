'use strict';

const fs = require('fs');
const path = require('path');

function logPath() {
  return process.env.MCP_CALL_LOG_FILE || path.join(__dirname, 'calls.log');
}

function logCall(server, toolName, args) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    server,
    tool: toolName,
    args: args || {}
  });
  fs.appendFileSync(logPath(), line + '\n', 'utf-8');
}

module.exports = { logCall };
