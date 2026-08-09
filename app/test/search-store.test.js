'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { searchConversations } = require('../lib/search-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'search-store-test-'));
}

test('searchConversations devuelve vacio con query vacia (no escanea todo por gusto)', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'a.jsonl'), JSON.stringify({ role: 'usuario', text: 'hablemos de gatos', ts: '2026-01-01T00:00:00Z' }) + '\n');
  assert.deepStrictEqual(searchConversations(dir, ''), []);
  assert.deepStrictEqual(searchConversations(dir, '   '), []);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('searchConversations encuentra coincidencias reales, case-insensitive, con snippet', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'conv-1.jsonl'), [
    JSON.stringify({ role: 'usuario', text: 'che, hablemos de RUNWAY para generar videos', ts: '2026-01-01T00:00:00Z' }),
    JSON.stringify({ role: 'mentis', text: 'dale, Runway anima una imagen fija', ts: '2026-01-01T00:00:01Z' })
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'conv-2.jsonl'), [
    JSON.stringify({ role: 'usuario', text: 'esto no tiene nada que ver', ts: '2026-01-02T00:00:00Z' })
  ].join('\n') + '\n');

  const results = searchConversations(dir, 'runway');
  assert.strictEqual(results.length, 2, 'debe encontrar las 2 menciones, case-insensitive');
  assert.ok(results.every((r) => r.conversationId === 'conv-1'));
  assert.ok(results.some((r) => r.snippet.toLowerCase().includes('runway')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('searchConversations ordena por mas reciente primero y respeta el limite', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'vieja.jsonl'), JSON.stringify({ role: 'usuario', text: 'palabra clave', ts: '2026-01-01T00:00:00Z' }) + '\n');
  fs.writeFileSync(path.join(dir, 'nueva.jsonl'), JSON.stringify({ role: 'usuario', text: 'palabra clave', ts: '2026-02-01T00:00:00Z' }) + '\n');

  const results = searchConversations(dir, 'palabra clave');
  assert.strictEqual(results[0].conversationId, 'nueva');
  assert.strictEqual(results[1].conversationId, 'vieja');

  const limited = searchConversations(dir, 'palabra clave', { limit: 1 });
  assert.strictEqual(limited.length, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('searchConversations ignora lineas corruptas y entradas sin texto, sin romper', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'mixta.jsonl'), [
    JSON.stringify({ role: 'usuario', text: 'buscar esto' }),
    '{esto no es json valido',
    JSON.stringify({ role: 'mentis', artifacts: ['x.jpg'] })
  ].join('\n') + '\n');
  const results = searchConversations(dir, 'buscar esto');
  assert.strictEqual(results.length, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});
