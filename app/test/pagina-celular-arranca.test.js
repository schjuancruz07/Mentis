'use strict';
/* La página del celular tiene que encenderse SOLA con Mentis (pedido del usuario, 2026-07-30:
 * "el servidor arranca solo").
 *
 * Se prueba arrancando Electron de verdad con main.js y mirando si el servidor quedó vivo. No se
 * verifica "que la función exista" ni "que el archivo mencione mentis-web.sh": eso es exactamente
 * el tipo de test que pasa mientras la cosa está rota (ERR-075, ERR-095). Acá se le pregunta al
 * servidor por su propio /salud, que sólo puede contestar si de verdad se levantó.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFile, execFileSync } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const MENTIS = path.join(RAIZ, '..');
const ELECTRON = require('electron');
const WEB_SCRIPT = path.join(MENTIS, 'mentis-web.sh');

function bash() {
  for (const c of ['C:\\Program Files\\Git\\bin\\bash.exe', 'C:\\Program Files (x86)\\Git\\bin\\bash.exe', 'bash']) {
    if (c === 'bash' || fs.existsSync(c)) return c;
  }
  return 'bash';
}

async function salud() {
  // Se le pregunta al servidor, no al sistema de archivos: un JSON de estado viejo puede quedar
  // de una corrida anterior, pero /salud sólo contesta si hay algo escuchando ahora.
  try {
    const r = await fetch('http://127.0.0.1:8765/salud', { signal: AbortSignal.timeout(3000) });
    const d = await r.json();
    return !!(d && d.ok);
  } catch (e) {
    return false;
  }
}

// El timeout del test tiene que ser mayor que la vida del Electron de prueba (75 s) más el
// apagado previo y el margen de arranque, o el test se corta a sí mismo antes de poder concluir.
test('al abrir Mentis, la página del celular queda encendida', { timeout: 180000 }, async () => {
  if (!fs.existsSync(WEB_SCRIPT)) {
    assert.fail('no existe mentis-web.sh: la página del celular no está instalada');
  }
  // Punto de partida limpio: apagada.
  try { execFileSync(bash(), [WEB_SCRIPT, 'apagar'], { timeout: 30000, stdio: 'ignore' }); } catch (e) { /* ya estaba */ }
  assert.strictEqual(await salud(), false, 'el servidor seguía prendido antes de arrancar la app');

  // Electron real, con el main.js de verdad. La ventana no se muestra y se cierra sola.
  const guion = `
    const { app } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();
    require(${JSON.stringify(path.join(RAIZ, 'main.js'))});
    setTimeout(() => { process.stdout.write('___LISTO___'); app.exit(0); }, 75000);
  `;
  const guionPath = path.join(os.tmpdir(), 'mentis-arranque-web-' + Date.now() + '.js');
  fs.writeFileSync(guionPath, guion, 'utf-8');

  const corrida = new Promise((resolve) => {
    // 100 s: tiene que sobrevivir a los 75 s que el guion se da a sí mismo. Con 60 s, execFile
    // mataba Electron ANTES de que se apagara solo y la prueba perdía sus últimos 15 s de espera.
    execFile(ELECTRON, [guionPath], { timeout: 100000, cwd: RAIZ }, (err, stdout, stderr) => {
      resolve(String(stdout || '') + String(stderr || ''));
    });
  });

  // Mientras Electron vive, el servidor tiene que aparecer. Se mira varias veces: levantar python
  // y cargar el módulo lleva unos segundos.
  //
  // La ventana era de 20 x 1,5 s = 30 s y era DEMASIADO CORTA (encontrado 2026-08-02, revisión
  // total). Corriendo el archivo solo pasaba; dentro de `npm test`, con los otros 20 archivos en
  // paralelo -- uno de ellos también levantando Electron -- y esta máquina con ~1,1 GB de RAM
  // libres, arrancar python y cargar el módulo tarda más de 30 s y el test fallaba con la app
  // funcionando perfecto. Un test que sólo pasa con la máquina desocupada no dice nada.
  //
  // Ahora son 50 x 1,5 s = 75 s, que es lo que vive el Electron de prueba: se espera TODO lo que
  // la app está viva, ni un segundo menos. Si el servidor no apareció en ese lapso, el problema
  // es real y no es la carga de la máquina.
  let encendio = false;
  for (let i = 0; i < 50 && !encendio; i++) {
    await new Promise((r) => setTimeout(r, 1500));
    encendio = await salud();
  }
  const salida = await corrida;
  fs.unlinkSync(guionPath);

  assert.ok(encendio,
    'la app arrancó pero la página del celular no quedó escuchando. Salida de Electron:\n' + salida.slice(0, 800));
});
