'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { MentisProcess } = require('../lib/mentis-process');
const scheduleStore = require('../lib/schedule-store');
const store = require('../lib/conversation-store');
const folderStore = require('../lib/folder-store');

const FIXTURE = path.join(__dirname, 'fixtures', 'fake-mentis-chat-with-history.sh');

// Integracion real (no mockeada) del flujo completo de una tarea programada: crear la tarea,
// confirmar que scheduleStore la detecta como vencida, ejecutarla con un MentisProcess REAL
// (mismo mecanismo que usa main.js, contra el fixture bash en vez del mentis-chat.sh real para
// no depender de red/API), y confirmar que la conversacion dedicada + folder + lastRunAt/
// lastResult quedan bien persistidos -- exactamente lo que hace runScheduledTask() en main.js,
// reproducido acá para poder testearlo sin levantar Electron.
test('flujo completo de una tarea programada: vencida -> corre -> conversacion + folder + resultado persistidos', async () => {
  const mentisEnvDir = fs.mkdtempSync(path.join(os.tmpdir(), 'scheduler-integration-'));
  const convDir = path.join(mentisEnvDir, 'conversations');

  const task = scheduleStore.createTask(mentisEnvDir, {
    name: 'Tarea de prueba',
    prompt: 'hola fixture',
    schedule: { type: 'interval', everyMinutes: 5 }
  });

  const due = scheduleStore.computeDueTasks(scheduleStore.loadTasks(mentisEnvDir), new Date());
  assert.strictEqual(due.length, 1, 'una tarea recien creada sin lastRunAt debe estar vencida');
  assert.strictEqual(due[0].id, task.id);

  // --- reproduce runScheduledTask() de main.js ---
  store.ensureDir(convDir);
  const conversationId = store.newConversationId();
  const folderId = folderStore.createFolder(convDir, 'Tareas programadas').id;
  folderStore.assignConversation(convDir, conversationId, folderId);
  const histPath = store.conversationPath(convDir, conversationId);

  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: FIXTURE, args: ['-H', histPath] });
  const done = new Promise((resolve) => proc.once('turn-complete', resolve));
  proc.start();
  proc.send(task.prompt);
  await done;
  await proc.stop();

  const entries = store.readJsonlEntries(histPath);
  const last = entries[entries.length - 1];
  const resultText = last && last.role === 'mentis' ? last.text : '(sin respuesta)';
  scheduleStore.updateTask(mentisEnvDir, task.id, { conversationId, lastRunAt: new Date().toISOString(), lastResult: resultText });
  // --- fin de la reproduccion ---

  assert.ok(fs.existsSync(histPath), 'la conversacion dedicada de la tarea debe existir en disco');
  assert.ok(entries.some((e) => e.role === 'usuario' && e.text === 'hola fixture'), 'el prompt de la tarea debe quedar en el historial');

  const { assignments } = folderStore.loadFolders(convDir);
  assert.strictEqual(assignments[conversationId], folderId, 'la conversacion debe quedar asignada a la carpeta de tareas programadas');

  const updatedTask = scheduleStore.loadTasks(mentisEnvDir).find((t) => t.id === task.id);
  assert.strictEqual(updatedTask.conversationId, conversationId);
  assert.ok(updatedTask.lastRunAt, 'lastRunAt debe quedar seteado tras correr');
  assert.ok(updatedTask.lastResult, 'lastResult debe quedar seteado tras correr');

  const stillDue = scheduleStore.computeDueTasks(scheduleStore.loadTasks(mentisEnvDir), new Date());
  assert.strictEqual(stillDue.length, 0, 'inmediatamente despues de correr, no debe volver a estar vencida (intervalo de 5min)');

  fs.rmSync(mentisEnvDir, { recursive: true, force: true });
});
