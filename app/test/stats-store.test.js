'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { computeStats } = require('../lib/stats-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'stats-store-test-'));
}

function writeConv(dir, id, lines) {
  fs.writeFileSync(path.join(dir, `${id}.jsonl`), lines.map((l) => JSON.stringify(l)).join('\n') + '\n', 'utf-8');
}

function isoAtHour(daysAgo, hour) {
  const d = new Date();
  d.setUTCHours(hour, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() - daysAgo);
  return d.toISOString();
}

test('directorio vacio da stats en cero, sin inventar nada', () => {
  const dir = tmpDir();
  const stats = computeStats(dir);
  assert.strictEqual(stats.sessions, 0);
  assert.strictEqual(stats.messages, 0);
  assert.strictEqual(stats.daysActive, 0);
  assert.strictEqual(stats.currentStreak, 0);
  assert.strictEqual(stats.favoriteModel, null);
  assert.strictEqual(stats.modelDataAvailable, false);
  assert.strictEqual(stats.tokensTracked, false, 'no debe fingir que trackea tokens');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('sessions = cantidad de archivos.jsonl, messages = solo entradas de usuario', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    { role: 'usuario', text: 'hola', ts: isoAtHour(0, 10) },
    { role: 'mentis', text: 'hola vos', ts: isoAtHour(0, 10) }
  ]);
  writeConv(dir, 'b', [
    { role: 'usuario', text: 'otra', ts: isoAtHour(0, 11) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.sessions, 2);
  assert.strictEqual(stats.messages, 2);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('racha actual: 3 dias consecutivos terminando HOY', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    { role: 'usuario', text: 'd0', ts: isoAtHour(0, 9) },
    { role: 'usuario', text: 'd1', ts: isoAtHour(1, 9) },
    { role: 'usuario', text: 'd2', ts: isoAtHour(2, 9) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.daysActive, 3);
  assert.strictEqual(stats.currentStreak, 3);
  assert.strictEqual(stats.longestStreak, 3);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('racha actual es 0 si el ultimo dia con actividad fue hace 3+ dias (se corto)', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    { role: 'usuario', text: 'viejo1', ts: isoAtHour(5, 9) },
    { role: 'usuario', text: 'viejo2', ts: isoAtHour(6, 9) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.currentStreak, 0, 'la racha ya se corto, no debe contar como activa');
  assert.strictEqual(stats.longestStreak, 2, 'pero la racha mas larga historica si tiene que quedar');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('racha mas larga historica puede ser mayor que la actual', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    // racha vieja de 4 dias, hace mas de una semana
    { role: 'usuario', text: '1', ts: isoAtHour(20, 9) },
    { role: 'usuario', text: '2', ts: isoAtHour(19, 9) },
    { role: 'usuario', text: '3', ts: isoAtHour(18, 9) },
    { role: 'usuario', text: '4', ts: isoAtHour(17, 9) },
    // racha actual de 2 dias, terminando hoy
    { role: 'usuario', text: '5', ts: isoAtHour(1, 9) },
    { role: 'usuario', text: '6', ts: isoAtHour(0, 9) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.currentStreak, 2);
  assert.strictEqual(stats.longestStreak, 4);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('hora pico: la hora con mas mensajes de usuario gana', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    { role: 'usuario', text: '1', ts: isoAtHour(0, 17) },
    { role: 'usuario', text: '2', ts: isoAtHour(1, 17) },
    { role: 'usuario', text: '3', ts: isoAtHour(2, 17) },
    { role: 'usuario', text: '4', ts: isoAtHour(3, 9) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.peakHour, 17);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('modelo favorito: cuenta solo entradas mentis con campo model, ignora las viejas sin ese campo', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [
    { role: 'mentis', text: 'r1', ts: isoAtHour(0, 9), model: 'code' },
    { role: 'mentis', text: 'r2', ts: isoAtHour(0, 10), model: 'code' },
    { role: 'mentis', text: 'r3', ts: isoAtHour(0, 11), model: 'reason' },
    { role: 'mentis', text: 'sin-model-campo-viejo', ts: isoAtHour(0, 12) }
  ]);
  const stats = computeStats(dir);
  assert.strictEqual(stats.favoriteModel, 'Código');
  assert.strictEqual(stats.favoriteModelSampleSize, 2);
  assert.strictEqual(stats.modelDataAvailable, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('heatmap tiene el largo pedido y la ultima celda es hoy', () => {
  const dir = tmpDir();
  writeConv(dir, 'a', [{ role: 'usuario', text: 'hoy', ts: isoAtHour(0, 9) }]);
  const stats = computeStats(dir, { heatmapDays: 14 });
  assert.strictEqual(stats.heatmap.length, 14);
  const todayKey = new Date().toISOString().slice(0, 10);
  assert.strictEqual(stats.heatmap[stats.heatmap.length - 1].date, todayKey);
  assert.strictEqual(stats.heatmap[stats.heatmap.length - 1].count, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('lineas jsonl corruptas no rompen el calculo, solo se ignoran', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'a.jsonl'), '{"role":"usuario","text":"ok","ts":"' + isoAtHour(0, 9) + '"}\nno es json\n', 'utf-8');
  const stats = computeStats(dir);
  assert.strictEqual(stats.messages, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});
