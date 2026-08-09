'use strict';
/* Prueba las cuentas del fin-de-frase automático (VAD) DENTRO de Electron, con la interfaz real.
 *
 * Por qué acá y no en un test suelto de Node: las funciones viven en renderer.js, que corre en la
 * ventana y no se puede `require`. Copiarlas a un test sería probar la copia -- exactamente el
 * error de ERR-075 (un test que verificaba el montaje y no el pintado). Acá se le pregunta a la
 * página real por window.__mentisVAD, así que lo que se prueba es el código que va a correr.
 *
 * Qué se prueba: que el umbral se CALIBRE SOLO contra el ruido de la sala. El valor fijo anterior
 * (0,035) estaba puesto a ojo, antes de que nadie le hablara a un micrófono.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFile } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const ELECTRON = require('electron');

test('el umbral del VAD se calibra solo contra el ruido de la sala', { timeout: 90000 }, async () => {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();
    app.whenReady().then(async () => {
      const w = new BrowserWindow({
        show: false, width: 1000, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} }
      });
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 3000));
      const res = await w.webContents.executeJavaScript(\`(() => {
        const V = window.__mentisVAD;
        if (!V) return { existe: false };
        const lim = V.limites();
        // Sala silenciosa (ruido 0,004) contra sala ruidosa (ventilador, 0,015).
        const umbralSilencio = V.calcularUmbralVAD(0.004, 3.5);
        const umbralRuidosa  = V.calcularUmbralVAD(0.015, 3.5);
        // El piso baja de golpe al aparecer un silencio y sube casi nada con un pico de voz.
        const bajaRapido = V.actualizarPisoRuido(0.05, 0.004);
        const subeLento  = V.actualizarPisoRuido(0.004, 0.20);
        const primerCuadro = V.actualizarPisoRuido(0, 0.033);
        return { existe: true, lim, umbralSilencio, umbralRuidosa, bajaRapido, subeLento, primerCuadro,
                 umbralRuidoAbsurdo: V.calcularUmbralVAD(0.5, 3.5),
                 umbralMudo: V.calcularUmbralVAD(0, 3.5) };
      })()\`);
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-vad-electron-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (err, stdout, stderr) => {
      resolve(String(stdout || '') + String(stderr || ''));
    });
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const r = JSON.parse(m[1]);
  assert.strictEqual(r.existe, true, 'window.__mentisVAD no está publicado en la interfaz real');

  // El umbral ACOMPAÑA al ruido: en una sala ruidosa hay que exigir más volumen para creer que es voz.
  assert.ok(r.umbralRuidosa > r.umbralSilencio,
    `el umbral no se adapta al ruido (silencio ${r.umbralSilencio} vs ruidosa ${r.umbralRuidosa})`);
  // Y en una sala callada baja bastante por debajo del 0,035 fijo de antes: hablar bajito alcanza.
  assert.ok(r.umbralSilencio < 0.035,
    `en silencio el umbral deberia bajar del viejo fijo 0,035, dio ${r.umbralSilencio}`);

  // Los topes existen para que ningún extremo deje a Mentis sordo o disparando con el aire.
  assert.ok(r.umbralRuidoAbsurdo <= r.lim.max, 'el umbral se pasó del techo con ruido absurdo');
  assert.ok(r.umbralMudo >= r.lim.min, 'con micrófono mudo el umbral quedó por debajo del piso');

  // El piso de ruido tiene que bajar de golpe (aprende el silencio real apenas aparece) y subir
  // casi nada con la voz: si subiera rápido, una frase larga terminaría tapándose a sí misma.
  assert.strictEqual(r.bajaRapido, 0.004, 'el piso no bajó de inmediato al aparecer un silencio');
  assert.ok(r.subeLento < 0.005, `el piso subió demasiado con un pico de voz: ${r.subeLento}`);
  assert.strictEqual(r.primerCuadro, 0.033, 'el primer cuadro debería fijar el piso donde esté el micrófono');
});
