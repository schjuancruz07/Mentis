// captura-estudio.js -- el panel de los nueve formatos de Mentis Study (2026-08-13, fase C).
//
// POR QUE EXISTE: el panel tiene tres comportamientos que no se ven leyendo el codigo -- que
// aparezca SOLO en Study, que se corra solo cuando Mentis empieza a trabajar y vuelva al
// terminar, y que las preguntas terminen escribiendo la linea correcta en el cuadro de texto.
// Los tres son de estado, y el estado se mide en un navegador o no se mide.
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
  await pagina.goto(`http://127.0.0.1:${puerto}/index.html`, { waitUntil: 'networkidle' }).catch(() => {});
  await pagina.waitForTimeout(600);
  errores.length = 0;

  // El panel de estado tiene que estar abierto para ver lo que hay adentro.
  await pagina.evaluate(() => document.getElementById('status-panel').classList.remove('collapsed'));

  // --- 1. Solo aparece en Study ---
  await pagina.evaluate(() => window.panelEstudio.aplicar('designe'));
  await pagina.waitForTimeout(200);
  const enDesigne = await pagina.evaluate(() => ({
    panel: !document.getElementById('panel-estudio').classList.contains('hidden'),
    preview: !document.getElementById('preview-content').classList.contains('hidden'),
  }));
  // 2026-08-15: Designe TAMBIEN tiene catalogo (dos filas: imagenes y piezas). Antes esta prueba
  // verificaba lo contrario -- que el panel fuera exclusivo de Study -- y era correcta hasta hoy.
  // Lo que se sigue cuidando es que catalogo y previsualizador nunca esten los dos a la vez.
  (enDesigne.panel && !enDesigne.preview)
    ? _ok('en Designe se ve su catalogo de generacion (y no el previsualizador)')
    : _mal('en Designe el panel no corresponde: ' + JSON.stringify(enDesigne));
  const filasDesigne = await pagina.evaluate(() => ({
    secciones: [...document.querySelectorAll('.estudio-seccion')].map((e) => e.textContent),
    tarjetas: document.querySelectorAll('#panel-estudio-grilla.estudio-tarjeta').length,
  }));
  (filasDesigne.secciones.length === 2 && filasDesigne.tarjetas >= 10)
    ? _ok('el catalogo de Designe tiene sus dos filas (' + filasDesigne.secciones.join(' / ') + ') y ' + filasDesigne.tarjetas + ' tarjetas')
    : _mal('el catalogo de Designe no se pinto bien: ' + JSON.stringify(filasDesigne));

  await pagina.evaluate(() => window.panelEstudio.aplicar('study'));
  await pagina.waitForTimeout(300);
  const enStudy = await pagina.evaluate(() => ({
    panel: !document.getElementById('panel-estudio').classList.contains('hidden'),
    preview: !document.getElementById('preview-content').classList.contains('hidden'),
    tarjetas: document.querySelectorAll('.estudio-tarjeta').length,
    etiqueta: document.getElementById('status-panel-label').textContent,
  }));
  (enStudy.panel && !enStudy.preview && enStudy.tarjetas === 9)
    ? _ok(`en Study se ven los ${enStudy.tarjetas} formatos ("${enStudy.etiqueta}")`)
    : _mal('en Study el panel no corresponde: ' + JSON.stringify(enStudy));

  // --- 2. Mientras Mentis trabaja, el panel muestra la actividad y despues vuelve ---
  await pagina.evaluate(() => estadoPonerEstado('pensando'));
  await pagina.waitForTimeout(200);
  const trabajando = await pagina.evaluate(() => ({
    panel: !document.getElementById('panel-estudio').classList.contains('hidden'),
    preview: !document.getElementById('preview-content').classList.contains('hidden'),
  }));
  (!trabajando.panel && trabajando.preview)
    ? _ok('mientras trabaja, el panel pasa a mostrar la actividad')
    : _mal('el panel no cambio al trabajar: ' + JSON.stringify(trabajando));

  await pagina.evaluate(() => estadoPonerEstado('listo'));
  await pagina.waitForTimeout(200);
  const volvio = await pagina.evaluate(() => !document.getElementById('panel-estudio').classList.contains('hidden'));
  volvio ? _ok('al terminar vuelve solo a los formatos')
         : _mal('no volvio a los formatos al terminar el turno');

  // --- 3. El flujo de preguntas termina escribiendo la linea de /material ---
  await pagina.click('.estudio-tarjeta[data-formato="cuestionario"]');
  await pagina.waitForTimeout(300);
  const preguntas = await pagina.evaluate(() => ({
    bloques: document.querySelectorAll('.estudio-preg').length,
    titulo: (document.querySelector('.estudio-preg-titulo') || {}).textContent,
    grillaOculta: document.getElementById('panel-estudio-grilla').classList.contains('hidden'),
  }));
  (preguntas.bloques === 3 && preguntas.grillaOculta)
    ? _ok(`el cuestionario pregunta sus ${preguntas.bloques} cosas antes de generar`)
    : _mal('las preguntas no aparecieron bien: ' + JSON.stringify(preguntas));

  // Se elige una opcion de cada pregunta y se pide preparar.
  await pagina.evaluate(() => {
    document.querySelectorAll('.estudio-preg').forEach((b) => {
      const op = b.querySelector('.estudio-op');
      if (op) op.click();
    });
    const t = document.querySelector('.estudio-tema');
    if (t) t.value = 'fotosintesis';
  });
  await pagina.waitForTimeout(150);
  const marcadas = await pagina.evaluate(() => document.querySelectorAll('.estudio-op.elegida').length);
  marcadas === 3 ? _ok('las opciones elegidas quedan marcadas')
                 : _mal(`quedaron ${marcadas} marcadas, esperaba 3`);

  await pagina.click('.estudio-listo');
  await pagina.waitForTimeout(300);
  const linea = await pagina.evaluate(() => document.getElementById('message-input').value);
  const bien = linea.startsWith('/material cuestionario fotosintesis')
    && /cu[aá]ntas preguntas: 8/i.test(linea) && linea.includes(';');
  bien ? _ok(`arma el pedido completo: "${linea.slice(0, 78)}..."`)
       : _mal(`la linea quedo mal: "${linea}"`);

  const volvioGrilla = await pagina.evaluate(() =>
    !document.getElementById('panel-estudio-grilla').classList.contains('hidden'));
  volvioGrilla ? _ok('despues de preparar el pedido vuelve a los formatos')
               : _mal('quedo trabado en las preguntas');

  await pagina.screenshot({ path: path.join(__dirname, '_estudio-panel.png') });
  await pagina.evaluate(() => document.querySelector('.estudio-tarjeta[data-formato="audio"]').click());
  await pagina.waitForTimeout(300);
  await pagina.screenshot({ path: path.join(__dirname, '_estudio-preguntas.png') });

  errores.length === 0 ? _ok('sin errores de JS')
                       : _mal('errores: ' + errores.slice(0, 2).join(' | '));

  await navegador.close(); srv.close();
  console.log(`\n== ${ok} OK, ${mal} MAL ==`);
  process.exit(mal === 0 ? 0 : 1);
})();
