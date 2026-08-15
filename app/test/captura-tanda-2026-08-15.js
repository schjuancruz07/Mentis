// captura-tanda-2026-08-15.js -- las cuatro cosas nuevas de la interfaz, en fotos.
//
// POR QUE EXISTE: los asserts dicen que los elementos ESTAN; no dicen si se VEN bien. El catálogo
// de Designe con dos filas, el tablero de tareas tachándose y los dos tamaños del previsualizador
// son cambios visuales, y eso se mira. Mismo arnés que captura-estudio.js: servidor local con
// window.mentisAPI simulado -- con file:// pelado el renderer muere al arrancar y las fotos
// muestran una app a medio cargar que igual da tests en verde (lección de la tanda anterior).
'use strict';
const path = require('path');
const fs = require('fs');
const http = require('http');

const RAIZ = path.join(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));
const RENDERER = path.join(RAIZ, 'app', 'renderer');
const MIMES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
                '.woff2': 'font/woff2', '.png': 'image/png', '.svg': 'image/svg+xml' };

let ok = 0, mal = 0;
const _ok = (m) => { ok++; console.log('  OK   ' + m); };
const _mal = (m) => { mal++; console.log('  MAL  ' + m); };

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

(async () => {
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: 1280, height: 860 } });
  const errores = [];
  pagina.on('pageerror', (e) => errores.push(String(e.message)));
  await pagina.addInitScript(() => {
    window.mentisAPI = new Proxy({ onboardingStatus: async () => ({ ok: true, done: true }) }, {
      get: (o, p) => (p in o ? o[p]
        : (typeof p === 'string' && /^(list|get)/.test(p) ? async () => [] : async () => ({ ok: true }))),
    });
  });
  const { srv, puerto } = await servir();
  await pagina.goto('http://127.0.0.1:' + puerto + '/index.html', { waitUntil: 'networkidle' });
  await pagina.waitForTimeout(500);

  // --- 1) el catálogo de Designe -----------------------------------------------------------
  await pagina.evaluate(() => { if (window.panelEstudio) window.panelEstudio.aplicar('designe'); });
  await pagina.waitForTimeout(250);
  const cat = await pagina.evaluate(() => ({
    secciones: [...document.querySelectorAll('.estudio-seccion')].map((e) => e.textContent),
    tarjetas: document.querySelectorAll('#panel-estudio-grilla.estudio-tarjeta').length,
    // Que ninguna tarjeta se salga de su columna: el panel es angosto y los títulos son largos.
    desborde: [...document.querySelectorAll('.estudio-tarjeta')].some((b) => b.scrollWidth > b.clientWidth + 2),
  }));
  (cat.secciones.length === 2 && cat.tarjetas === 12 && !cat.desborde)
    ? _ok('catálogo de Designe: 2 filas, 12 tarjetas, sin desbordes')
    : _mal('catálogo de Designe: ' + JSON.stringify(cat));
  await pagina.locator('#status-panel').screenshot({ path: path.join(__dirname, '_2026-08-15-designe-catalogo.png') });

  // --- 2) el tablero de tareas, con una tachada ---------------------------------------------
  await pagina.evaluate(() => {
    if (window.panelEstudio) window.panelEstudio.aplicar('cowork');
    const lineas = [
      '[nv-agent] PLAN: 1|Armar la lista de precios|precios.csv',
      '[nv-agent] PLAN: 2|Definir las compras del mes|compras.csv',
      '[nv-agent] PLAN: 3|Planificar dos semanas de contenido|contenidos.csv',
      '[nv-agent] PLAN-HECHO: 1',
    ];
    // Se llama al MISMO módulo que usa el turno real (window.tablero), con las mismas líneas que
    // emite el motor. No se reimplementa el parseo acá: eso probaría el arnés, no la app.
    for (const l of lineas) {
      const p = l.match(/^\[nv-agent\] PLAN: (\d+)\|([^|]*)\|(.*)$/);
      if (p) { window.tablero.agregar(parseInt(p[1], 10), p[2], p[3]); continue; }
      const h = l.match(/^\[nv-agent\] PLAN-HECHO: (\d+)$/);
      if (h) window.tablero.tachar(parseInt(h[1], 10));
    }
  });
  await pagina.waitForTimeout(400);
  const tab = await pagina.evaluate(() => {
    const c = document.getElementById('tablero-tareas');
    return { existe: !!c, visible: c && !c.classList.contains('hidden'),
             items: document.querySelectorAll('.tablero-item').length,
             hechas: document.querySelectorAll('.tablero-item.hecha').length };
  });
  (tab.visible && tab.items === 3 && tab.hechas === 1)
    ? _ok('el tablero muestra las 3 tareas y tiene 1 tachada')
    : _mal('el tablero no quedó como se esperaba: ' + JSON.stringify(tab));
  await pagina.locator('#status-panel').screenshot({ path: path.join(__dirname, '_2026-08-15-tablero.png') });

  // --- 3) los dos tamaños del previsualizador ------------------------------------------------
  await pagina.evaluate(() => {
    if (window.panelEstudio) window.panelEstudio.aplicar('mentis');
    const p = document.getElementById('status-panel');
    p.classList.remove('collapsed', 'completa');
    p.classList.add('columna');
  });
  await pagina.waitForTimeout(250);
  await pagina.screenshot({ path: path.join(__dirname, '_2026-08-15-preview-columna.png') });
  const col = await pagina.evaluate(() => {
    const p = document.getElementById('status-panel').getBoundingClientRect();
    return { alto: Math.round(p.height), ancho: Math.round(p.width), ventana: window.innerHeight };
  });
  (col.alto > col.ventana * 0.7)
    ? _ok('el tamaño normal ya es la columna alta (' + col.alto + 'px de ' + col.ventana + ')')
    : _mal('la columna no quedó alta: ' + JSON.stringify(col));

  await pagina.evaluate(() => document.getElementById('status-panel').classList.add('completa'));
  await pagina.waitForTimeout(250);
  await pagina.screenshot({ path: path.join(__dirname, '_2026-08-15-preview-completa.png') });
  const full = await pagina.evaluate(() => {
    const p = document.getElementById('status-panel').getBoundingClientRect();
    const btn = document.getElementById('btn-status-full');
    const r = btn && btn.getBoundingClientRect();
    return { ancho: Math.round(p.width), ventana: window.innerWidth,
             // La salida tiene que seguir A LA VISTA: es la condición que hizo que en 2026-08-11
             // se retirara el primer intento de pantalla completa.
             salidaVisible: !!(r && r.width > 0 && r.top >= 0 && r.bottom <= window.innerHeight) };
  });
  (full.ancho > full.ventana * 0.6 && full.salidaVisible)
    ? _ok('pantalla completa cubre de verdad y el botón de salir queda visible')
    : _mal('pantalla completa: ' + JSON.stringify(full));

  // Dos errores son del ARNÉS y no de la app: el stub de mentisAPI devuelve {} para todo, y el
  // renderer espera {folders: [...]} al listar carpetas. Se ignoran por su texto exacto -- no se
  // silencia la categoría entera, así que cualquier otro error sigue haciendo fallar la corrida.
  const DEL_ARNES = [/foldersData\.folders is not iterable/, /Cannot read properties of undefined \(reading 'find'\)/];
  const reales = errores.filter((e) => !DEL_ARNES.some((r) => r.test(e)));
  reales.length ? _mal('errores de JS: ' + reales.join(' | ')) : _ok('sin errores de JS propios');

  await navegador.close();
  srv.close();
  console.log('\n== ' + ok + ' OK, ' + mal + ' MAL ==');
  process.exit(mal ? 1 : 0);
})();
