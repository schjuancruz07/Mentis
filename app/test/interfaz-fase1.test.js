'use strict';
/* Fase 1 de la ronda del 2026-07-28: barra de título propia y subtítulos que no molestan.
 *
 * Todo esto es visual, y lo visual es donde más fácil se miente: "el elemento está en el DOM" no
 * quiere decir "se ve", y "se ve" no quiere decir "no tapa nada" (ERR-075: un test que probaba el
 * montaje y daba por bueno el pintado). Así que acá se piden estilos COMPUTADOS y posiciones
 * reales en pantalla, con la interfaz cargada en Electron de verdad.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFile } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const ELECTRON = require('electron');

async function preguntarleALaInterfaz(expresion) {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();
    app.whenReady().then(async () => {
      const w = new BrowserWindow({
        show: false, width: 1000, height: 720, frame: false,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} }
      });
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 3500));
      const res = await w.webContents.executeJavaScript(${JSON.stringify(expresion)});
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-fase1-' + Date.now() + '-' + Math.random().toString(36).slice(2) + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (err, stdout, stderr) => {
      resolve(String(stdout || '') + String(stderr || ''));
    });
  });
  require('fs').unlinkSync(guionPath);
  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  return JSON.parse(m[1]);
}

test('la barra de título propia existe, es negra y tiene sus tres botones VISIBLES', { timeout: 90000 }, async () => {
  const r = await preguntarleALaInterfaz(`(() => {
    const barra = document.getElementById('barra-titulo');
    if (!barra) return { hay: false };
    const cs = getComputedStyle(barra);
    const botones = ['btn-win-min','btn-win-max','btn-win-close'].map((id) => {
      const b = document.getElementById(id);
      if (!b) return { id, existe: false };
      const r = b.getBoundingClientRect();
      const bcs = getComputedStyle(b);
      return { id, existe: true, ancho: r.width, alto: r.height,
               visible: bcs.display !== 'none' && bcs.visibility !== 'hidden' && r.width > 0,
               color: bcs.color, region: bcs.webkitAppRegion || bcs.getPropertyValue('-webkit-app-region') };
    });
    return { hay: true, fondo: cs.backgroundColor, alto: barra.getBoundingClientRect().height,
             region: cs.webkitAppRegion || cs.getPropertyValue('-webkit-app-region'), botones };
  })()`);

  assert.strictEqual(r.hay, true, 'no existe la barra de título propia');
  assert.strictEqual(r.fondo, 'rgb(0, 0, 0)', 'la barra no es negra, es ' + r.fondo);
  assert.ok(r.alto >= 30 && r.alto <= 40, 'alto raro de la barra: ' + r.alto);
  assert.strictEqual(r.region, 'drag', 'la barra no es arrastrable (la ventana no se podría mover)');
  for (const b of r.botones) {
    assert.ok(b.existe, `falta el botón ${b.id}`);
    assert.ok(b.visible, `el botón ${b.id} está en el DOM pero NO se ve (ancho ${b.ancho})`);
    assert.strictEqual(b.region, 'no-drag', `el botón ${b.id} es zona de arrastre: no se podría clickear`);
  }
});

test('los subtítulos viven dentro de la zona central y no tapan los botones', { timeout: 90000 }, async () => {
  const r = await preguntarleALaInterfaz(`(() => {
    const sub = document.getElementById('subtitulos-voz');
    if (!sub) return { hay: false };
    const cs = getComputedStyle(sub);
    // La columna del cuerpo digital desapareció el 2026-08-11; los subtítulos pasaron a colgar
    // de la zona central. Lo que este test cuida NO cambió: que no sean una capa flotante
    // anclada a la ventana y que no se superpongan con el compositor.
    const columna = document.getElementById('zona-central');
    const composer = document.getElementById('composer');
    // Se lo hace visible con texto para medirlo como se ve de verdad, no vacío.
    sub.classList.remove('hidden');
    const jm = document.getElementById('subtitulo-mentis');
    jm.textContent = 'Una respuesta larga de prueba para ver cuánto ocupa en pantalla y si se superpone con algo importante de la interfaz.';
    jm.classList.add('visible');
    const rs = sub.getBoundingClientRect();
    const rc = composer ? composer.getBoundingClientRect() : null;
    const seSuperponeConBotones = rc ? !(rs.bottom <= rc.top || rs.top >= rc.bottom) : null;
    return { hay: true, posicion: cs.position,
             dentroDeZonaCentral: !!(columna && columna.contains(sub)),
             seSuperponeConBotones, alturaSub: rs.height, topSub: rs.top, topComposer: rc ? rc.top : null };
  })()`);

  assert.strictEqual(r.hay, true, 'no existen los subtítulos');
  assert.strictEqual(r.dentroDeZonaCentral, true,
    'los subtítulos no están dentro de la zona central: son una capa suelta y se van a ver en toda la app');
  assert.notStrictEqual(r.posicion, 'fixed',
    'siguen con position:fixed, o sea anclados a la VENTANA y no a su sección');
  assert.strictEqual(r.seSuperponeConBotones, false,
    `los subtítulos se superponen con el cuadro de botones (sub top=${r.topSub}, composer top=${r.topComposer})`);
});

test('la interfaz entra en la ventana: el composer no queda cortado abajo', { timeout: 90000 }, async () => {
  // Con frame:false la ventana entrega los 100vh completos. Si #app se hubiera quedado con
  // height:100vh, la barra de 34px empujaría el composer fuera de la pantalla y no habría forma
  // de llegar a los botones. Es el efecto colateral clásico de sacar el marco.
  const r = await preguntarleALaInterfaz(`(() => {
    const composer = document.getElementById('composer');
    const rc = composer.getBoundingClientRect();
    return { fondoComposer: rc.bottom, alturaVentana: window.innerHeight };
  })()`);
  assert.ok(r.fondoComposer <= r.alturaVentana + 1,
    `el composer termina en ${r.fondoComposer} y la ventana mide ${r.alturaVentana}: quedó cortado abajo`);
});
