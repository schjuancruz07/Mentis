'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const convStore = require('../lib/conversation-store');
const branchStore = require('../lib/branch-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'branch-store-test-'));
}

function writeConv(dir, id, entries) {
  fs.writeFileSync(convStore.conversationPath(dir, id), entries.map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf-8');
}

test('createBranch trunca justo ANTES del mensaje editado, sin tocar el original', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [
    { role: 'usuario', text: 'hola' },
    { role: 'mentis', text: 'hola, como estas' },
    { role: 'usuario', text: 'contame un chiste' },
    { role: 'mentis', text: 'chiste malo' }
  ]);

  const branchId = branchStore.createBranch(dir, 'original', 2);
  const branchEntries = convStore.readJsonlEntries(convStore.conversationPath(dir, branchId));
  assert.strictEqual(branchEntries.length, 2, 'debe truncar justo antes del indice editado');
  assert.strictEqual(branchEntries[1].text, 'hola, como estas');

  const originalEntries = convStore.readJsonlEntries(convStore.conversationPath(dir, 'original'));
  assert.strictEqual(originalEntries.length, 4, 'el original no debe tocarse');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('createBranch rechaza editar un mensaje de Mentis (solo mensajes de usuario)', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [
    { role: 'usuario', text: 'hola' },
    { role: 'mentis', text: 'hola, como estas' }
  ]);
  assert.throws(() => branchStore.createBranch(dir, 'original', 1), /solo se pueden editar tus propios mensajes/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('createBranch rechaza un indice fuera de rango', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [{ role: 'usuario', text: 'hola' }]);
  assert.throws(() => branchStore.createBranch(dir, 'original', 5), /fuera de rango/);
  assert.throws(() => branchStore.createBranch(dir, 'original', -1), /fuera de rango/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('getSiblingGroups: desde el original ve su propia rama como alternativa navegable', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [
    { role: 'usuario', text: 'hola' },
    { role: 'mentis', text: 'hola, como estas' },
    { role: 'usuario', text: 'contame un chiste' },
    { role: 'mentis', text: 'chiste malo' }
  ]);
  const branchId = branchStore.createBranch(dir, 'original', 2);

  const fromOriginal = branchStore.getSiblingGroups(dir, 'original');
  assert.deepStrictEqual(fromOriginal, { 2: ['original', branchId] });
});

test('getSiblingGroups: desde la rama ve al original como alternativa (orden: original primero)', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [
    { role: 'usuario', text: 'hola' },
    { role: 'mentis', text: 'hola, como estas' },
    { role: 'usuario', text: 'contame un chiste' },
    { role: 'mentis', text: 'chiste malo' }
  ]);
  const branchId = branchStore.createBranch(dir, 'original', 2);

  const fromBranch = branchStore.getSiblingGroups(dir, branchId);
  assert.deepStrictEqual(fromBranch, { 2: ['original', branchId] });
});

test('getSiblingGroups: dos ediciones del MISMO mensaje aparecen como 3 versiones (original + 2 ramas)', () => {
  const dir = tmpDir();
  writeConv(dir, 'original', [
    { role: 'usuario', text: 'hola' },
    { role: 'mentis', text: 'hola, como estas' },
    { role: 'usuario', text: 'contame un chiste' },
    { role: 'mentis', text: 'chiste malo' }
  ]);
  const branchA = branchStore.createBranch(dir, 'original', 2);
  const branchB = branchStore.createBranch(dir, 'original', 2);

  const fromOriginal = branchStore.getSiblingGroups(dir, 'original');
  assert.deepStrictEqual(fromOriginal, { 2: ['original', branchA, branchB] });
  const fromBranchA = branchStore.getSiblingGroups(dir, branchA);
  assert.deepStrictEqual(fromBranchA, { 2: ['original', branchA, branchB] });
});

test('getSiblingGroups: sin ninguna rama, devuelve vacio', () => {
  const dir = tmpDir();
  writeConv(dir, 'solita', [{ role: 'usuario', text: 'hola' }]);
  assert.deepStrictEqual(branchStore.getSiblingGroups(dir, 'solita'), {});
  fs.rmSync(dir, { recursive: true, force: true });
});
