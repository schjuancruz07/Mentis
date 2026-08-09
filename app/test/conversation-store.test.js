'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const store = require('../lib/conversation-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'conv-store-test-'));
}

test('newConversationId genera IDs distintos en llamadas sucesivas', () => {
  const a = store.newConversationId();
  const b = store.newConversationId();
  assert.notStrictEqual(a, b);
});

test('listConversations devuelve vacio si el directorio no existe (y lo crea)', () => {
  const base = tmpDir();
  const dir = path.join(base, 'no-existe-todavia');
  const list = store.listConversations(dir);
  assert.deepStrictEqual(list, []);
  assert.ok(fs.existsSync(dir), 'deberia crear el directorio');
  fs.rmSync(base, { recursive: true, force: true });
});

test('listConversations lee titulo del primer mensaje de usuario y cuenta entradas', () => {
  const dir = tmpDir();
  const id = 'conv-1';
  const filePath = store.conversationPath(dir, id);
  fs.writeFileSync(filePath, [
    JSON.stringify({ role: 'usuario', text: 'hola mentis, como estas', ts: '2026-01-01T00:00:00' }),
    JSON.stringify({ role: 'mentis', text: 'todo bien', ts: '2026-01-01T00:00:01' })
  ].join('\n') + '\n', 'utf-8');
  const list = store.listConversations(dir);
  assert.strictEqual(list.length, 1);
  assert.strictEqual(list[0].id, id);
  assert.strictEqual(list[0].title, 'hola mentis, como estas');
  assert.strictEqual(list[0].entryCount, 2);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('listConversations ordena por mas reciente primero', () => {
  const dir = tmpDir();
  const viejaPath = store.conversationPath(dir, 'vieja');
  fs.writeFileSync(viejaPath, JSON.stringify({ role: 'usuario', text: 'vieja', ts: '' }) + '\n');
  const antes = new Date(Date.now() - 10000);
  fs.utimesSync(viejaPath, antes, antes);
  const nuevaPath = store.conversationPath(dir, 'nueva');
  fs.writeFileSync(nuevaPath, JSON.stringify({ role: 'usuario', text: 'nueva', ts: '' }) + '\n');
  const list = store.listConversations(dir);
  assert.strictEqual(list[0].id, 'nueva');
  assert.strictEqual(list[1].id, 'vieja');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('readJsonlEntries devuelve array vacio si el archivo no existe', () => {
  const entries = store.readJsonlEntries('/ruta/que/no/existe.jsonl');
  assert.deepStrictEqual(entries, []);
});

test('readJsonlEntries ignora una linea final truncada (kill forzado a mitad de escritura) en vez de tirar', () => {
  const dir = tmpDir();
  const filePath = path.join(dir, 'truncada.jsonl');
  const buena = JSON.stringify({ role: 'usuario', text: 'hola', ts: '2026-01-01T00:00:00' });
  fs.writeFileSync(filePath, buena + '\n' + '{"role":"mentis","text":"respuesta a medi', 'utf-8');
  const entries = store.readJsonlEntries(filePath);
  assert.strictEqual(entries.length, 1, 'debe quedarse solo con la linea buena, sin tirar excepcion');
  assert.strictEqual(entries[0].text, 'hola');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('listConversations no rompe el listado completo si UNA conversacion tiene una linea corrupta', () => {
  const dir = tmpDir();
  fs.writeFileSync(store.conversationPath(dir, 'sana'), JSON.stringify({ role: 'usuario', text: 'ok', ts: '' }) + '\n');
  fs.writeFileSync(store.conversationPath(dir, 'rota'), '{"role":"usuario","text":"corta');
  const list = store.listConversations(dir);
  assert.strictEqual(list.length, 2, 'ambas conversaciones deben listarse, ninguna debe faltar');
  fs.rmSync(dir, { recursive: true, force: true });
});

// popLastJuanEntry (botón Detener, 2026-07-16): mentis-chat.sh persiste el mensaje de usuario
// ANTES de llamar al modelo -- si el turno se cancela (forceKill) a mitad de camino, ese
// mensaje queda persistido sin respuesta. popLastJuanEntry lo saca del archivo real.
test('popLastJuanEntry saca el ultimo mensaje de usuario y lo devuelve, dejando el resto intacto', () => {
  const dir = tmpDir();
  const filePath = store.conversationPath(dir, 'conv-stop');
  fs.writeFileSync(filePath, [
    JSON.stringify({ role: 'usuario', text: 'primer mensaje', ts: '2026-01-01T00:00:00' }),
    JSON.stringify({ role: 'mentis', text: 'primera respuesta', ts: '2026-01-01T00:00:01' }),
    JSON.stringify({ role: 'usuario', text: 'segundo mensaje sin respuesta (turno cancelado)', ts: '2026-01-01T00:00:02' })
  ].join('\n') + '\n', 'utf-8');
  const reverted = store.popLastJuanEntry(filePath);
  assert.strictEqual(reverted, 'segundo mensaje sin respuesta (turno cancelado)');
  const entries = store.readJsonlEntries(filePath);
  assert.strictEqual(entries.length, 2, 'solo debe quedar el primer intercambio completo');
  assert.strictEqual(entries[1].text, 'primera respuesta');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('popLastJuanEntry no toca el archivo si el ultimo mensaje ya es de mentis (nada que revertir)', () => {
  const dir = tmpDir();
  const filePath = store.conversationPath(dir, 'conv-completa');
  const contenidoOriginal = [
    JSON.stringify({ role: 'usuario', text: 'hola', ts: '2026-01-01T00:00:00' }),
    JSON.stringify({ role: 'mentis', text: 'hola usuario', ts: '2026-01-01T00:00:01' })
  ].join('\n') + '\n';
  fs.writeFileSync(filePath, contenidoOriginal, 'utf-8');
  const reverted = store.popLastJuanEntry(filePath);
  assert.strictEqual(reverted, null);
  assert.strictEqual(fs.readFileSync(filePath, 'utf-8'), contenidoOriginal, 'el archivo no debe modificarse');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('popLastJuanEntry devuelve null si el archivo no existe o esta vacio', () => {
  assert.strictEqual(store.popLastJuanEntry('/ruta/que/no/existe.jsonl'), null);
  const dir = tmpDir();
  const filePath = store.conversationPath(dir, 'vacia');
  fs.writeFileSync(filePath, '', 'utf-8');
  assert.strictEqual(store.popLastJuanEntry(filePath), null);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('popLastJuanEntry deja el archivo correctamente vacio si el unico mensaje era el de usuario', () => {
  const dir = tmpDir();
  const filePath = store.conversationPath(dir, 'conv-un-solo-mensaje');
  fs.writeFileSync(filePath, JSON.stringify({ role: 'usuario', text: 'primer mensaje de la conversacion', ts: '2026-01-01T00:00:00' }) + '\n', 'utf-8');
  const reverted = store.popLastJuanEntry(filePath);
  assert.strictEqual(reverted, 'primer mensaje de la conversacion');
  assert.deepStrictEqual(store.readJsonlEntries(filePath), []);
  fs.rmSync(dir, { recursive: true, force: true });
});
