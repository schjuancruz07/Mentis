'use strict';
/* Mensajes largos por voz: que Mentis NO te corte en la mitad de una idea.
 *
 * BUG REAL que reporto el usuario (2026-07-30): "el transcriptor no aguanta mensajes largos y se corta
 * y envia". Eran dos cortes distintos, y por eso parecia caprichoso:
 *   1. un tope duro de 45 s, que mataba el dictado aunque estuvieras hablando;
 *   2. el VAD, que cerraba la frase a los 1100 ms de silencio -- una pausa para pensar, en medio
 *      de una idea, mandaba el mensaje por la mitad.
 *
 * Igual que vad-electron.test.js, esto corre DENTRO de Electron y le pregunta a la pagina real
 * por window.__mentisVAD. No se copian las funciones al test: probar una copia es probar la
 * copia (ERR-075).
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFile } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const ELECTRON = require('electron');

async function preguntarALaPagina(expresion) {
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
      const res = await w.webContents.executeJavaScript(${JSON.stringify(expresion)});
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-dictado-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (err, stdout, stderr) => {
      resolve(String(stdout || '') + String(stderr || ''));
    });
  });
  require('fs').unlinkSync(guionPath);
  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvio resultado. Salida: ' + salida.slice(0, 600));
  return JSON.parse(m[1]);
}

test('una pausa para pensar no manda el mensaje por la mitad', { timeout: 90000 }, async () => {
  const r = await preguntarALaPagina(`(() => {
    const V = window.__mentisVAD;
    if (!V) return { existe: false };
    const base = 1100;
    return {
      existe: true,
      lim: V.limites(),
      // Cuanta pausa se tolera segun cuanto venis hablando
      pausaCorta: V.pausaPermitidaMs(3000, base),      // frase de 3 s
      pausaMedia: V.pausaPermitidaMs(25000, base),     // 25 s hablando
      pausaLarga: V.pausaPermitidaMs(60000, base),     // dictado de un minuto
      // El caso del bug: 40 s hablando y una pausa de 1,5 s para pensar
      cortaPensando: V.debeCortarFrase({ habloAlgunaVez: true, hablandoMs: 40000, silencioMs: 1500, base }),
      // Una frase corta terminada de verdad tiene que seguir cerrandose rapido
      cortaFraseCorta: V.debeCortarFrase({ habloAlgunaVez: true, hablandoMs: 2500, silencioMs: 1200, base }),
      // Y un dictado largo tambien termina cuando de verdad terminas
      cortaDictadoAlFinal: V.debeCortarFrase({ habloAlgunaVez: true, hablandoMs: 60000, silencioMs: 3500, base }),
      // Nunca cortar si todavia no hablaste, ni por un carraspeo de 100 ms
      cortaSinHablar: V.debeCortarFrase({ habloAlgunaVez: false, hablandoMs: 0, silencioMs: 9000, base }),
      cortaCarraspeo: V.debeCortarFrase({ habloAlgunaVez: true, hablandoMs: 100, silencioMs: 9000, base })
    };
  })()`);

  assert.strictEqual(r.existe, true, 'window.__mentisVAD no esta publicado en la interfaz real');

  // LO QUE IMPORTA: hablando largo, una pausa de 1,5 s ya NO termina el mensaje.
  assert.strictEqual(r.cortaPensando, false,
    'con 40 s hablando, una pausa de 1,5 s corto el mensaje: el bug sigue vivo');
  // Pero la conversacion corta no se vuelve lenta: sigue cerrando con la pausa de siempre.
  assert.strictEqual(r.cortaFraseCorta, true,
    'una frase corta terminada deberia cerrarse con la pausa base');
  // Y el dictado largo tiene que poder terminar.
  assert.strictEqual(r.cortaDictadoAlFinal, true,
    'un dictado largo con 3,5 s de silencio deberia darse por terminado');
  assert.strictEqual(r.cortaSinHablar, false, 'corto sin que nadie hubiera hablado');
  assert.strictEqual(r.cortaCarraspeo, false, 'corto con un ruido de 100 ms como si fuera una frase');

  // La tolerancia CRECE con lo que venis hablando (que es la idea entera).
  assert.strictEqual(r.pausaCorta, 1100, 'una frase corta deberia usar la pausa base sin cambios');
  assert.ok(r.pausaMedia > r.pausaCorta, `la pausa no crece: corta ${r.pausaCorta}, media ${r.pausaMedia}`);
  assert.ok(r.pausaLarga > r.pausaMedia, `la pausa no sigue creciendo: media ${r.pausaMedia}, larga ${r.pausaLarga}`);
  assert.ok(r.pausaLarga <= r.lim.pausaTecho + 1,
    `la pausa se paso del techo: ${r.pausaLarga} > ${r.lim.pausaTecho}`);
});

test('el tope duro de 45 s ya no existe y los dictados largos se parten en tramos', { timeout: 90000 }, async () => {
  const r = await preguntarALaPagina(`(() => {
    const V = window.__mentisVAD;
    if (!V) return { existe: false };
    const lim = V.limites();
    return {
      existe: true, lim,
      // Un mensaje corto NO se parte: se transcribe entero, igual que siempre.
      parteCorto: V.debeSegmentar({ tramoMs: 5000, silencioMs: 900, cortando: false }),
      // Un tramo largo SI se parte, pero solo aprovechando un silencio real...
      parteLargoEnPausa: V.debeSegmentar({ tramoMs: 25000, silencioMs: 900, cortando: false }),
      //...nunca en medio de una palabra
      parteLargoHablando: V.debeSegmentar({ tramoMs: 25000, silencioMs: 100, cortando: false }),
      //...ni cuando ya se esta cerrando la frase (seria partir por partir)
      parteCortando: V.debeSegmentar({ tramoMs: 25000, silencioMs: 900, cortando: true })
    };
  })()`);

  assert.strictEqual(r.existe, true, 'window.__mentisVAD no esta publicado');

  // El tope de 45 s era el limite de mensaje. Ahora la red de seguridad tiene que ser MUY grande:
  // sigue existiendo para el microfono mudo, pero no puede cortar a nadie hablando.
  assert.ok(r.lim.maxGrabacionMs >= 10 * 60 * 1000,
    `el tope de grabacion sigue siendo chico (${r.lim.maxGrabacionMs} ms): un dictado largo se cortaria`);

  assert.strictEqual(r.parteCorto, false, 'partio un mensaje corto en tramos sin necesidad');
  assert.strictEqual(r.parteLargoEnPausa, true, 'no partio un dictado largo en una pausa');
  assert.strictEqual(r.parteLargoHablando, false, 'partio el audio en medio de una palabra');
  assert.strictEqual(r.parteCortando, false, 'partio un tramo justo cuando la frase ya se cerraba');
});
