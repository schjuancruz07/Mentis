// captura-fase1.js -- mide en un navegador REAL las tres cosas de la fase 1 (2026-08-12).
//
// POR QUE EXISTE: las tres son cambios de CSS, y el CSS no se puede verificar leyendolo. Un
// max-width que no aplica porque el selector no coincide con el DOM real se lee perfecto en el
// archivo y no hace nada en pantalla. Aca se abre la interfaz, se le pregunta al navegador que
// ancho TIENE cada cosa, y se compara con lo que se quiso.
//
// QUE MIDE:
//   1. Michroma: que la fuente del logotipo en modo science sea Michroma de verdad (no la de
//      respaldo por un woff2 mal enlazado, que se ve casi igual de reojo).
//   2. Columna de lectura: que el cuadro de texto y los mensajes compartan ancho Y eje central.
//   3. El panel ya no tapa: con el panel abierto, que el borde derecho de la conversacion quede
//      a la izquierda del borde izquierdo del panel. Si se superponen aunque sea 1px, tapa.
//
// Uso: node app/test/captura-fase1.js [carpeta-de-salida]
'use strict';
const path = require('path');
const fs = require('fs');

const http = require('http');

const RAIZ = path.join(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));
const RENDERER = path.join(RAIZ, 'app', 'renderer');
const SALIDA = path.resolve(process.argv[2] || path.join(__dirname));

// SE SIRVE POR HTTP Y CON UN PUENTE DE MENTIRA, no con file:// pelado (corregido 2026-08-13).
// Sin window.mentisAPI, renderer.js explota en su primera llamada al puente y deja de ejecutar
// TODO lo que viene despues -- incluida la mudanza de los controles al pie del compositor. El
// test seguia dando 7/7 porque medía cosas ya pintadas, pero las fotos mostraban una app a medio
// arrancar: el "+" al lado del cuadro cuando en la app real ya estaba abajo.
// Un arnes que carga la interfaz distinto de como la carga la app no esta probando la app.
const MIMES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
                '.woff2': 'font/woff2', '.png': 'image/png', '.svg': 'image/svg+xml' };
function servir() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const u = decodeURIComponent(req.url.split('?')[0]);
      const abs = path.join(RENDERER, u === '/' ? 'index.html' : u);
      if (!abs.startsWith(RENDERER) || !fs.existsSync(abs) || !fs.statSync(abs).isFile()) {
        res.writeHead(404); res.end('no'); return;
      }
      res.writeHead(200, { 'Content-Type': MIMES[path.extname(abs).toLowerCase()] || 'application/octet-stream' });
      fs.createReadStream(abs).pipe(res);
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, puerto: srv.address().port }));
  });
}

let ok = 0, mal = 0;
const _ok = (m) => { ok++; console.log('  OK   ' + m); };
const _mal = (m) => { mal++; console.log('  MAL  ' + m); };

(async () => {
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: 1280, height: 860 } });
  const fallos = [];
  pagina.on('requestfailed', (r) => fallos.push(r.url().split('/').pop()));
  await pagina.addInitScript(() => {
    window.mentisAPI = new Proxy({ onboardingStatus: async () => ({ ok: true, done: true }) }, {
      get: (o, p) => (p in o ? o[p]
        : (typeof p === 'string' && /^(list|get)/.test(p) ? async () => [] : async () => ({ ok: true }))),
    });
  });
  const { srv, puerto } = await servir();
  await pagina.goto(`http://127.0.0.1:${puerto}/index.html`, { waitUntil: 'networkidle' }).catch(() => {});
  await pagina.waitForTimeout(500);
  await pagina.evaluate(() => document.fonts.ready).catch(() => {});

  // --- 1. Michroma en el modo science ---
  await pagina.evaluate(() => {
    document.documentElement.setAttribute('data-modo', 'science');
    const w = document.getElementById('header-wordmark');
    if (w) w.textContent = 'MENTIS SCIENCE';
  });
  await pagina.waitForTimeout(400);
  const marca = await pagina.evaluate(() => {
    const w = document.getElementById('header-wordmark');
    if (!w) return null;
    const cs = getComputedStyle(w);
    return { familia: cs.fontFamily, espaciado: cs.letterSpacing, tamano: cs.fontSize,
             cargada: document.fonts.check('12px Michroma') };
  });
  if (!marca) { _mal('no existe #header-wordmark'); }
  else {
    marca.familia.toLowerCase().includes('michroma')
      ? _ok(`el logotipo de science pide Michroma (${marca.tamano}, ${marca.espaciado})`)
      : _mal(`el logotipo pide ${marca.familia}, no Michroma`);
    marca.cargada
      ? _ok('el archivo de Michroma cargo de verdad (no cayo a la de respaldo)')
      : _mal('Michroma NO cargo: se esta viendo la fuente de respaldo');
  }
  await pagina.screenshot({ path: path.join(SALIDA, '_fase1-science.png') });

  // --- 2. Columna de lectura: mismo ancho y mismo eje ---
  // El centro de referencia es el de la ZONA DE TRABAJO, no el de la ventana. La barra lateral
  // ocupa la izquierda, asi que centrar en la ventana dejaria el cuadro corrido respecto de los
  // mensajes que tiene arriba -- justo lo contrario de lo que se pidio. La primera version de
  // este test comparaba contra window.innerWidth y reprobaba un layout correcto.
  const col = await pagina.evaluate(() => {
    const c = document.getElementById('composer-main');
    const m = document.getElementById('messages');
    const main = document.getElementById('main');
    if (!c || !m || !main) return null;
    const rc = c.getBoundingClientRect();
    const rmain = main.getBoundingClientRect();
    return { anchoComposer: Math.round(rc.width),
             centroComposer: Math.round(rc.left + rc.width / 2),
             centroZona: Math.round(rmain.left + rmain.width / 2),
             anchoZona: Math.round(rmain.width),
             margen: Math.round(rc.left - rmain.left) };
  });
  if (!col) { _mal('no existe #composer-main, #messages o #main'); }
  else {
    col.anchoComposer < col.anchoZona - 100
      ? _ok(`el cuadro deja margen: ${col.anchoComposer}px dentro de una zona de ${col.anchoZona}px (${col.margen}px de aire a cada lado)`)
      : _mal(`el cuadro sigue ocupando casi toda la zona (${col.anchoComposer}px de ${col.anchoZona}px)`);
    Math.abs(col.centroComposer - col.centroZona) <= 2
      ? _ok('el cuadro esta centrado en la zona de conversacion')
      : _mal(`el cuadro esta corrido: su centro cae en ${col.centroComposer} y el de la zona en ${col.centroZona}`);
  }

  // --- 2b. Los controles viven DEBAJO del cuadro de texto (2026-08-13) ---
  const abajo = await pagina.evaluate(() => {
    const ta = document.getElementById('message-input');
    const mas = document.getElementById('btn-mas');
    const mic = document.getElementById('btn-mic');
    const fila = document.getElementById('composer-acciones');
    if (!ta || !mas || !mic || !fila) return null;
    const rt = ta.getBoundingClientRect(), rm = mas.getBoundingClientRect();
    const ri = mic.getBoundingClientRect(), rf = fila.getBoundingClientRect();
    return { masDebajo: rm.top >= rt.bottom - 2, micDebajo: ri.top >= rt.bottom - 2,
             masIzq: Math.round(rm.left), micIzq: Math.round(ri.left),
             filaIzq: Math.round(rf.left), filaDer: Math.round(rf.right),
             padreMas: mas.parentElement.id, padreMic: mic.parentElement.id };
  });
  if (!abajo) { _mal('falta alguno de los controles del compositor'); }
  else {
    abajo.masDebajo && abajo.micDebajo
      ? _ok('el "+" y el microfono quedaron DEBAJO del cuadro de texto')
      : _mal(`siguen al costado: mas=${abajo.padreMas} mic=${abajo.padreMic}`);
    // El "+" pegado al borde izquierdo de la columna y el microfono al derecho: es el reparto
    // que se pidio, y si alguno se corre al medio la fila deja de leerse como dos extremos.
    (abajo.masIzq - abajo.filaIzq <= 12) && (abajo.filaDer - abajo.micIzq <= 46)
      ? _ok('el "+" quedo a la izquierda y el microfono al otro extremo')
      : _mal(`mal repartidos: + en ${abajo.masIzq}, mic en ${abajo.micIzq}, fila ${abajo.filaIzq}-${abajo.filaDer}`);
  }

  // --- 3. El panel abierto NO se superpone con la conversacion ---
  await pagina.evaluate(() => {
    document.getElementById('status-panel').classList.remove('collapsed');
  });
  await pagina.waitForTimeout(400);
  const solape = await pagina.evaluate(() => {
    const p = document.getElementById('status-panel');
    const z = document.getElementById('zona-central');
    const c = document.getElementById('composer-main');
    if (!p || !z) return null;
    const rp = p.getBoundingClientRect();
    const rz = z.getBoundingClientRect();
    const rc = c ? c.getBoundingClientRect() : null;
    const zonaUtil = rz.right - parseFloat(getComputedStyle(z).paddingRight || '0');
    return { panelIzq: Math.round(rp.left), zonaDer: Math.round(zonaUtil),
             composerDer: rc ? Math.round(rc.right) : null };
  });
  if (!solape) { _mal('no existe #status-panel o #zona-central'); }
  else {
    solape.zonaDer <= solape.panelIzq + 1
      ? _ok(`la conversacion termina en ${solape.zonaDer}px y el panel arranca en ${solape.panelIzq}px: no se pisan`)
      : _mal(`SE PISAN: la conversacion llega a ${solape.zonaDer}px y el panel arranca en ${solape.panelIzq}px`);
    solape.composerDer === null || solape.composerDer <= solape.panelIzq + 1
      ? _ok('el cuadro de texto tampoco queda debajo del panel')
      : _mal(`el cuadro de texto llega a ${solape.composerDer}px, debajo del panel (${solape.panelIzq}px)`);
  }
  await pagina.screenshot({ path: path.join(SALIDA, '_fase1-panel-abierto.png') });

  // --- 4. AGRANDAR crece a lo ALTO, no a lo ancho (2026-08-13) ---
  // Antes tomaba min(78%, 900px) y cubria la conversacion entera. Lo que se mide es justamente
  // eso: que al agrandarse gane ALTO y NO gane ancho, y que siga sin pisar el chat.
  const antes = await pagina.evaluate(() => {
    const r = document.getElementById('status-panel').getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height) };
  });
  await pagina.evaluate(() => {
    document.getElementById('status-panel').classList.add('columna'); // 2026-08-15: la columna alta es el tamano NORMAL; 'completa' es el nuevo estado del boton
  });
  await pagina.waitForTimeout(400);
  const grande = await pagina.evaluate(() => {
    const p = document.getElementById('status-panel').getBoundingClientRect();
    const z = document.getElementById('zona-central');
    const rz = z.getBoundingClientRect();
    const util = rz.right - parseFloat(getComputedStyle(z).paddingRight || '0');
    return { w: Math.round(p.width), h: Math.round(p.height),
             izq: Math.round(p.left), zonaDer: Math.round(util) };
  });
  grande.h > antes.h
    ? _ok(`agrandar gana alto (${antes.h} -> ${grande.h}px)`)
    : _mal(`agrandar no gano alto (${antes.h} -> ${grande.h}px)`);
  grande.w <= antes.w + 2
    ? _ok(`agrandar NO gana ancho (${antes.w} -> ${grande.w}px)`)
    : _mal(`agrandar se expandio a lo ancho: ${antes.w} -> ${grande.w}px`);
  grande.zonaDer <= grande.izq + 1
    ? _ok('agrandado sigue sin tapar la conversacion')
    : _mal(`agrandado tapa: conversacion hasta ${grande.zonaDer}, panel desde ${grande.izq}`);
  await pagina.screenshot({ path: path.join(SALIDA, '_fase1-panel-agrandado.png') });

  const woff = fallos.filter((f) => f.endsWith('.woff2'));
  woff.length === 0 ? _ok('no fallo ningun archivo de fuente')
                    : _mal('fuentes que no cargaron: ' + woff.join(', '));

  await navegador.close();
  srv.close();
  console.log(`\n== ${ok} OK, ${mal} MAL ==`);
  console.log(`Fotos: ${path.join(SALIDA, '_fase1-science.png')} y _fase1-panel-abierto.png`);
  process.exit(mal === 0 ? 0 : 1);
})();
