'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { exportBackup } = require('../lib/backup-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'backup-store-test-'));
}

test('exportBackup arma un zip real con las fuentes existentes, e ignora las que no existen', async () => {
  const base = tmpDir();
  const convDir = path.join(base, 'conversaciones');
  fs.mkdirSync(convDir, { recursive: true });
  fs.writeFileSync(path.join(convDir, 'una.jsonl'), JSON.stringify({ role: 'usuario', text: 'hola' }) + '\n');
  const settingsFile = path.join(base, 'mentis-settings.json');
  fs.writeFileSync(settingsFile, JSON.stringify({ theme: 'bitacora-de-campo' }));
  const noExiste = path.join(base, 'esto-no-existe');

  const destZip = path.join(base, 'salida.zip');
  const result = await exportBackup([
    { src: convDir, destName: 'conversaciones' },
    { src: settingsFile, destName: 'mentis-settings.json' },
    { src: noExiste, destName: 'no-deberia-aparecer' }
  ], destZip);

  assert.strictEqual(result.ok, true);
  assert.strictEqual(result.path, destZip);
  assert.ok(fs.existsSync(destZip), 'el zip tiene que existir en disco');
  assert.ok(fs.statSync(destZip).size > 0, 'el zip no puede estar vacio');

  const extractDir = path.join(base, 'extraido');
  await new Promise((resolve, reject) => {
    require('child_process').execFile('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      `Expand-Archive -Path '${destZip}' -DestinationPath '${extractDir}' -Force`
    ], (err) => (err ? reject(err) : resolve()));
  });
  assert.ok(fs.existsSync(path.join(extractDir, 'conversaciones', 'una.jsonl')), 'la conversacion real debe estar en el zip');
  assert.ok(fs.existsSync(path.join(extractDir, 'mentis-settings.json')), 'el settings debe estar en el zip');
  assert.ok(!fs.existsSync(path.join(extractDir, 'no-deberia-aparecer')), 'una fuente inexistente no debe generar nada');

  fs.rmSync(base, { recursive: true, force: true });
});

test('exportBackup tira error legible si ninguna fuente existe', async () => {
  const base = tmpDir();
  const destZip = path.join(base, 'salida.zip');
  await assert.rejects(
    () => exportBackup([{ src: path.join(base, 'no-existe'), destName: 'x' }], destZip),
    /No hay datos todavía para exportar/
  );
  fs.rmSync(base, { recursive: true, force: true });
});
