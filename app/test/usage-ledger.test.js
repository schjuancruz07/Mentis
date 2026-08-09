'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { computeUsageCosts } = require('../lib/usage-ledger');

function tmpFile() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'usage-ledger-test-')), 'usage-ledger.jsonl');
}

test('computeUsageCosts devuelve vacio si el ledger no existe todavia', () => {
  const result = computeUsageCosts(path.join(os.tmpdir(), 'no-existe-nunca.jsonl'));
  assert.deepStrictEqual(result.providers, []);
  assert.strictEqual(result.totalUsd, 0);
});

test('computeUsageCosts suma costos reales por proveedor', () => {
  const file = tmpFile();
  fs.writeFileSync(file, [
    JSON.stringify({ ts: '2026-07-14T10:00:00Z', provider: 'ideogram', unit: 'image', quantity: 1, costUsd: 0.06 }),
    JSON.stringify({ ts: '2026-07-14T10:05:00Z', provider: 'ideogram', unit: 'image', quantity: 1, costUsd: 0.06 }),
    JSON.stringify({ ts: '2026-07-14T10:10:00Z', provider: 'runway', unit: 'video-seconds', quantity: 5, costUsd: 0.25 })
  ].join('\n') + '\n', 'utf-8');

  const result = computeUsageCosts(file);
  assert.strictEqual(result.totalUsd, 0.37);
  const ideogram = result.providers.find((p) => p.provider === 'ideogram');
  assert.strictEqual(ideogram.calls, 2);
  assert.strictEqual(ideogram.costUsd, 0.12);
  const runway = result.providers.find((p) => p.provider === 'runway');
  assert.strictEqual(runway.calls, 1);
  assert.strictEqual(runway.quantity, 5);
  assert.strictEqual(runway.costUsd, 0.25);
  fs.rmSync(path.dirname(file), { recursive: true, force: true });
});

test('computeUsageCosts ignora lineas corruptas sin romper el total', () => {
  const file = tmpFile();
  fs.writeFileSync(file, [
    JSON.stringify({ provider: 'ideogram', costUsd: 0.06, quantity: 1 }),
    '{esto no es json valido',
    JSON.stringify({ provider: 'runway', costUsd: 0.25, quantity: 5 })
  ].join('\n') + '\n', 'utf-8');

  const result = computeUsageCosts(file);
  assert.strictEqual(result.totalUsd, 0.31);
  assert.strictEqual(result.providers.length, 2);
  fs.rmSync(path.dirname(file), { recursive: true, force: true });
});
