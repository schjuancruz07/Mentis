'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const store = require('../lib/folder-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'folder-store-test-'));
}

test('loadFolders devuelve vacio si folders.json no existe', () => {
  const dir = tmpDir();
  const data = store.loadFolders(dir);
  assert.deepStrictEqual(data, { folders: [], assignments: {} });
  fs.rmSync(dir, { recursive: true, force: true });
});

test('createFolder crea una carpeta y persiste en folders.json', () => {
  const dir = tmpDir();
  const f = store.createFolder(dir, 'Proyecto X');
  assert.strictEqual(f.name, 'Proyecto X');
  assert.ok(f.id);
  const reloaded = store.loadFolders(dir);
  assert.strictEqual(reloaded.folders.length, 1);
  assert.strictEqual(reloaded.folders[0].name, 'Proyecto X');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('renameFolder cambia el nombre y devuelve false si el id no existe', () => {
  const dir = tmpDir();
  const f = store.createFolder(dir, 'Vieja');
  assert.strictEqual(store.renameFolder(dir, f.id, 'Nueva'), true);
  assert.strictEqual(store.loadFolders(dir).folders[0].name, 'Nueva');
  assert.strictEqual(store.renameFolder(dir, 'no-existe', 'x'), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('assignConversation asigna y null desasigna', () => {
  const dir = tmpDir();
  const f = store.createFolder(dir, 'Proyecto X');
  store.assignConversation(dir, 'conv-1', f.id);
  assert.strictEqual(store.loadFolders(dir).assignments['conv-1'], f.id);
  store.assignConversation(dir, 'conv-1', null);
  assert.strictEqual(store.loadFolders(dir).assignments['conv-1'], undefined);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('deleteFolder borra la carpeta y desasigna sus conversaciones', () => {
  const dir = tmpDir();
  const f = store.createFolder(dir, 'Proyecto X');
  store.assignConversation(dir, 'conv-1', f.id);
  assert.strictEqual(store.deleteFolder(dir, f.id), true);
  const data = store.loadFolders(dir);
  assert.strictEqual(data.folders.length, 0);
  assert.strictEqual(data.assignments['conv-1'], undefined);
  fs.rmSync(dir, { recursive: true, force: true });
});
