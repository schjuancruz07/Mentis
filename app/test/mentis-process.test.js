'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { MentisProcess } = require('../lib/mentis-process');

const FIXTURE = path.join(__dirname, 'fixtures', 'fake-mentis-chat.sh');

test('MentisProcess emite "ready" (no "turn-complete") en el primer prompt de bootstrap', async () => {
  // Bug real (2026-07-15): el primer "Vos: " que imprime mentis-chat.sh es de bootstrap,
  // antes de leer ningun mensaje -- tratarlo como turno completado borraba el primer
  // mensaje que el usuario mandaba a una conversacion nueva (ver mentis-process.js).
  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: FIXTURE, args: [] });
  let gotTurnComplete = false;
  proc.on('turn-complete', () => { gotTurnComplete = true; });
  const ready = new Promise((resolve) => proc.once('ready', resolve));
  proc.start();
  await ready;
  assert.strictEqual(gotTurnComplete, false, 'el primer prompt de bootstrap no debe emitir turn-complete');
  await proc.stop();
});

test('MentisProcess.send manda el mensaje y se ve la respuesta en los logs', async () => {
  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: FIXTURE, args: [] });
  const logs = [];
  proc.on('log', (l) => logs.push(l));
  proc.start();
  await new Promise((resolve) => proc.once('ready', resolve));
  const turnComplete = new Promise((resolve) => proc.once('turn-complete', resolve));
  proc.send('hola fixture');
  await turnComplete;
  assert.ok(
    logs.some((l) => l === 'Mentis: eco: hola fixture'),
    `deberia haber recibido el eco, logs: ${JSON.stringify(logs)}`
  );
  await proc.stop();
});

test('MentisProcess.stop manda salir y el proceso termina limpio', async () => {
  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: FIXTURE, args: [] });
  proc.start();
  await new Promise((resolve) => proc.once('ready', resolve));
  const exited = new Promise((resolve) => proc.once('exit', resolve));
  await proc.stop();
  await exited;
  assert.strictEqual(proc.exited, true);
});

// Bug real reportado por el usuario (computer-use, 2026-07-18): despues de "Frenar ya" la UI se
// destrababa pero seguian vivos los procesos de fondo (nv-verify.sh lanzado con '&' y su curl a
// la API), gastando creditos sin que nada en la interfaz pudiera matarlos. `taskkill /T` no
// alcanza a esos nietos cuando cuelgan de la emulacion de fork() de MSYS bash (ERR-034).
test('forceKill() mata tambien a los NIETOS que taskkill /T deja vivos', { skip: process.platform !== 'win32' ? 'solo aplica en Windows' : false }, async () => {
  const os = require('os');
  const fs = require('fs');
  const ORPHAN_FIXTURE = path.join(__dirname, 'fixtures', 'fake-mentis-chat-orphans.sh');
  const pidFile = path.join(os.tmpdir(), `mentis-orphan-${Date.now()}.pid`);

  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: ORPHAN_FIXTURE, args: [pidFile] });
  proc.start();
  await new Promise((resolve) => proc.once('ready', resolve));
  // esperar a que el nieto exista y haya anotado su pid
  let grandchildPid = null;
  for (let i = 0; i < 40 && !grandchildPid; i++) {
    await new Promise((r) => setTimeout(r, 100));
    if (fs.existsSync(pidFile)) {
      const raw = fs.readFileSync(pidFile, 'utf-8').trim();
      if (raw) grandchildPid = parseInt(raw, 10);
    }
  }
  assert.ok(grandchildPid > 0, 'el fixture deberia haber anotado el pid del nieto');

  const result = await proc.forceKill();
  assert.strictEqual(result.ok, true);

  // Antes esto era una espera fija de 800 ms y despues UN chequeo. Con la maquina cargada (la
  // suite corre en paralelo, y los tests del cuerpo digital abren ventanas de Electron) taskkill
  // tarda mas y el test acusaba de sobreviviente a un nieto que moria un rato despues. Ahora se
  // pregunta cada 200 ms hasta 6 s: lo que se exige sigue siendo "el nieto muere", no "el nieto
  // muere antes de 800 ms".
  const { execFileSync } = require('child_process');
  const sigueVivoAhora = () => {
    try {
      execFileSync('bash', ['-c', `kill -0 ${grandchildPid} 2>/dev/null`], { stdio: 'ignore' });
      return true;
    } catch {
      return false;
    }
  };
  let sigueVivo = true;
  for (let i = 0; i < 30 && sigueVivo; i++) {
    await new Promise((r) => setTimeout(r, 200));
    sigueVivo = sigueVivoAhora();
  }
  fs.unlinkSync(pidFile);
  assert.strictEqual(sigueVivo, false, `el nieto (pid ${grandchildPid}) sobrevivio al frenado -- sigue gastando API`);
});

test('MentisProcess.stop mata el proceso via forceKill() si "salir" no responde a tiempo (no cuelga)', async () => {
  const STUCK_FIXTURE = path.join(__dirname, 'fixtures', 'fake-mentis-chat-stuck.sh');
  const proc = new MentisProcess({ bashPath: 'bash', scriptPath: STUCK_FIXTURE, args: [] });
  proc.start();
  await new Promise((resolve) => proc.once('ready', resolve));
  const exited = new Promise((resolve) => proc.once('exit', resolve));
  await proc.stop(200);
  await exited;
  assert.strictEqual(proc.exited, true, 'debe terminar via el camino de timeout -> forceKill, no colgarse');
});
