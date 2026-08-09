'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const store = require('../lib/schedule-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'schedule-store-test-'));
}

test('createTask valida y persiste, updateTask/deleteTask funcionan', () => {
  const dir = tmpDir();
  assert.throws(() => store.createTask(dir, { name: '', prompt: 'x', schedule: { type: 'daily', hour: 8, minute: 0 } }), /nombre/);
  assert.throws(() => store.createTask(dir, { name: 'x', prompt: 'x', schedule: { type: 'daily', hour: 25, minute: 0 } }), /hora inválida/);

  const task = store.createTask(dir, { name: 'Resumen matutino', prompt: 'Resumime las notas de ayer', schedule: { type: 'daily', hour: 8, minute: 0 } });
  assert.strictEqual(task.enabled, true);
  assert.strictEqual(store.loadTasks(dir).length, 1);

  const updated = store.updateTask(dir, task.id, { enabled: false });
  assert.strictEqual(updated.enabled, false);
  assert.strictEqual(store.loadTasks(dir)[0].enabled, false);

  store.deleteTask(dir, task.id);
  assert.strictEqual(store.loadTasks(dir).length, 0);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('isDue: schedule diaria dispara solo en el minuto exacto, y solo una vez por dia', () => {
  const task = { enabled: true, schedule: { type: 'daily', hour: 8, minute: 0 }, lastRunAt: null };
  assert.strictEqual(store.isDue(task, new Date(2026, 0, 1, 8, 0)), true, 'debe disparar a las 8:00 en punto');
  assert.strictEqual(store.isDue(task, new Date(2026, 0, 1, 8, 1)), false, 'no debe disparar a las 8:01');
  assert.strictEqual(store.isDue(task, new Date(2026, 0, 1, 7, 59)), false);

  const yaCorrioHoy = {...task, lastRunAt: new Date(2026, 0, 1, 8, 0).toISOString() };
  assert.strictEqual(store.isDue(yaCorrioHoy, new Date(2026, 0, 1, 8, 0)), false, 'no debe repetir el mismo dia');
  assert.strictEqual(store.isDue(yaCorrioHoy, new Date(2026, 0, 2, 8, 0)), true, 'al dia siguiente si debe disparar');
});

test('isDue: schedule semanal respeta el dia de la semana', () => {
  // 2026-01-05 es lunes (dayOfWeek=1)
  const lunes8am = { enabled: true, schedule: { type: 'weekly', dayOfWeek: 1, hour: 8, minute: 0 }, lastRunAt: null };
  assert.strictEqual(new Date(2026, 0, 5).getDay(), 1, 'sanity check: 2026-01-05 es lunes');
  assert.strictEqual(store.isDue(lunes8am, new Date(2026, 0, 5, 8, 0)), true);
  assert.strictEqual(store.isDue(lunes8am, new Date(2026, 0, 6, 8, 0)), false, 'martes no debe disparar');
});

test('isDue: schedule por intervalo dispara segun minutos transcurridos desde lastRunAt', () => {
  const cadaHora = { enabled: true, schedule: { type: 'interval', everyMinutes: 60 }, lastRunAt: null };
  assert.strictEqual(store.isDue(cadaHora, new Date()), true, 'sin lastRunAt, dispara siempre (primera vez)');

  const haceMedia = {...cadaHora, lastRunAt: new Date(Date.now() - 30 * 60000).toISOString() };
  assert.strictEqual(store.isDue(haceMedia, new Date()), false, 'a los 30min de 60 no debe disparar');

  const haceUnaHora = {...cadaHora, lastRunAt: new Date(Date.now() - 61 * 60000).toISOString() };
  assert.strictEqual(store.isDue(haceUnaHora, new Date()), true, 'pasados los 60min si debe disparar');
});

test('isDue: una tarea deshabilitada nunca dispara, sin importar el schedule', () => {
  const task = { enabled: false, schedule: { type: 'daily', hour: 8, minute: 0 }, lastRunAt: null };
  assert.strictEqual(store.isDue(task, new Date(2026, 0, 1, 8, 0)), false);
});

test('computeDueTasks filtra correctamente una lista mixta', () => {
  const now = new Date(2026, 0, 1, 8, 0);
  const tasks = [
    { id: 'a', enabled: true, schedule: { type: 'daily', hour: 8, minute: 0 }, lastRunAt: null },
    { id: 'b', enabled: true, schedule: { type: 'daily', hour: 9, minute: 0 }, lastRunAt: null },
    { id: 'c', enabled: false, schedule: { type: 'daily', hour: 8, minute: 0 }, lastRunAt: null }
  ];
  const due = store.computeDueTasks(tasks, now);
  assert.deepStrictEqual(due.map((t) => t.id), ['a']);
});

test('describeSchedule arma un texto legible para cada tipo', () => {
  assert.match(store.describeSchedule({ type: 'daily', hour: 8, minute: 5 }), /Todos los días a las 08:05/);
  assert.match(store.describeSchedule({ type: 'weekly', dayOfWeek: 1, hour: 8, minute: 0 }), /lunes a las 08:00/);
  assert.match(store.describeSchedule({ type: 'interval', everyMinutes: 90 }), /Cada 90 minutos/);
});
