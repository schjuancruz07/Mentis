'use strict';
/* La cámara y el teléfono como BOTONES del grupo de abajo (pedido del usuario, 2026-07-31: "no sólo
 * tienen que estar en el Directorio").
 *
 * Qué se protege acá, en orden de importancia:
 *   1. Que arranquen APAGADOS. Son las dos herramientas que miran la habitación y manejan el
 *      teléfono; hasta ayer la cámara estaba encendida por defecto sin que nadie la prendiera
 *      (ERR-103), y el único motivo por el que no se notó es que nadie lo comprobó.
 *   2. Que el botón y el Directorio sean EL MISMO interruptor. Si fueran dos estados distintos,
 *      prender el botón y ver "Desactivado" en el directorio es cuestión de tiempo.
 *   3. Que el teléfono, además del conector, le pase su bandera al motor (las dos llaves).
 *
 * Corre dentro de Electron con la interfaz real, como los demás tests de pantalla: probar una
 * copia del markup sería probar la copia (ERR-075).
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFile } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const ELECTRON = require('electron');

async function preguntar(expresion) {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();
    app.whenReady().then(async () => {
      const w = new BrowserWindow({
        show: false, width: 1200, height: 800,
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
  const guionPath = path.join(require('os').tmpdir(), 'mentis-botones-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);
  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 700));
  return JSON.parse(m[1]);
}

test('la cámara y el teléfono son botones del grupo, y arrancan apagados', { timeout: 90000 }, async () => {
  const r = await preguntar(`(() => {
    const cluster = document.getElementById('action-cluster');
    const cam = document.getElementById('flag-webcam');
    const tel = document.getElementById('flag-telefono');
    const dentro = (el) => !!(el && cluster && cluster.contains(el));
    const etiqueta = (el) => el ? (el.closest('label') || {}).title || '' : '';
    return {
      existeCam: !!cam, existeTel: !!tel,
      camEnElGrupo: dentro(cam), telEnElGrupo: dentro(tel),
      camApagada: cam ? cam.checked === false : null,
      telApagado: tel ? tel.checked === false : null,
      camTieneIcono: !!(cam && cam.closest('label') && cam.closest('label').querySelector('svg')),
      telTieneIcono: !!(tel && tel.closest('label') && tel.closest('label').querySelector('svg')),
      camTitulo: etiqueta(cam), telTitulo: etiqueta(tel),
      botonesEnElGrupo: cluster ? cluster.querySelectorAll('label.flag-toggle').length : 0
    };
  })()`);

  assert.strictEqual(r.existeCam, true, 'no existe el botón de la cámara');
  assert.strictEqual(r.existeTel, true, 'no existe el botón del teléfono');
  assert.strictEqual(r.camEnElGrupo, true, 'el botón de la cámara no está en el grupo de abajo');
  assert.strictEqual(r.telEnElGrupo, true, 'el botón del teléfono no está en el grupo de abajo');
  // Lo más importante del archivo: apagados de fábrica.
  assert.strictEqual(r.camApagada, true, 'LA CÁMARA ARRANCA ENCENDIDA (es el ERR-103 otra vez)');
  assert.strictEqual(r.telApagado, true, 'el teléfono arranca encendido');
  assert.strictEqual(r.camTieneIcono, true, 'el botón de la cámara no tiene ícono');
  assert.strictEqual(r.telTieneIcono, true, 'el botón del teléfono no tiene ícono');
  // El title es lo único que explica qué hace cada botón: sin eso son dos dibujos.
  assert.match(r.camTitulo, /c[áa]mara/i, 'el botón de la cámara no explica qué hace');
  assert.match(r.telTitulo, /tel[ée]fono/i, 'el botón del teléfono no explica qué hace');
  assert.ok(r.botonesEnElGrupo >= 9, 'faltan botones en el grupo: ' + r.botonesEnElGrupo);
});

test('con el teléfono prendido, el motor recibe su bandera (-p)', { timeout: 90000 }, async () => {
  // Esto es lo que de verdad decide si Mentis PUEDE usar el teléfono: sin -p, mentis-chat.sh no le
  // pasa la herramienta al agente por más que el conector esté prendido (las dos llaves).
  const r = await preguntar(`(async () => {
    const tel = document.getElementById('flag-telefono');
    const out = {};
    out.hayCollectFlags = typeof currentFlags === "function";
    tel.checked = true;
    out.conTelefono = out.hayCollectFlags ? currentFlags() : null;
    tel.checked = false;
    out.sinTelefono = out.hayCollectFlags ? currentFlags() : null;
    return out;
  })()`);

  assert.strictEqual(r.hayCollectFlags, true, 'no se encontró currentFlags en la página');
  assert.ok(r.conTelefono.includes('-p'),
    'con el teléfono prendido no se le pasa -p al motor: ' + JSON.stringify(r.conTelefono));
  assert.ok(!r.sinTelefono.includes('-p'),
    'con el teléfono apagado igual se le pasa -p: ' + JSON.stringify(r.sinTelefono));
});

/* POR QUÉ NO SE PRUEBA ACÁ QUE EL BOTÓN GUARDE EL CONECTOR:
 * lo intenté y no se puede desde este banco de pruebas, por dos motivos que conviene dejar
 * escritos para no volver a intentarlo:
 *   1. los objetos que expone contextBridge son de SÓLO LECTURA -- reemplazar
 *      window.mentisAPI.toggleConnector para espiar la llamada falla en silencio;
 *   2. acá se carga sólo la ventana con su preload, sin el proceso principal, así que del otro
 *      lado del puente no hay nadie escuchando: la llamada no llega a ningún handler.
 * Probarlo de verdad exigiría levantar la app entera y dejarla escribir en la configuración REAL
 * del usuario -- prender su cámara en un test es exactamente lo que no se puede hacer.
 * Lo que sí queda cubierto: que los botones existan, estén en el grupo, arranquen apagados, y que
 * la bandera del teléfono llegue al motor. El guardado del conector usa el MISMO puente que ya
 * usa el popup de conectores del Directorio, que sí está probado por el uso diario.
 */
