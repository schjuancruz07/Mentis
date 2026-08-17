// revision-modos.js -- recorre LOS SIETE MODOS y todos sus paneles, buscando que algo se rompa.
//
// QUE BUSCA, Y POR QUE ESO: no busca que "se vea lindo". Busca las tres formas en que esta app se
// rompio de verdad antes:
//   1. Un error de JavaScript que deja media pantalla sin dibujar y no avisa a nadie.
//   2. Un BOTON QUE PROMETE ALGO QUE EL MOTOR RECHAZA -- el caso de modos.json escrito con todas
//      las letras: "apagar 'browse' sin apagar '-b' le deja al usuario el boton de navegar prendido
//      justo en el modo que no navega". La app diciendo una cosa y el motor otra.
//   3. Un panel que se declara en el modo y no existe en la interfaz (o al reves).
//
// Corre el renderer REAL contra un window.mentisAPI simulado, igual que los otros arneses. Lo que
// NO prueba: el handler de Electron del otro lado del IPC. Eso necesita la app abierta.
'use strict';
const path = require('path');
const fs = require('fs');
const http = require('http');
const { execFileSync } = require('child_process');

const RAIZ = path.join(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));
const RENDERER = path.join(RAIZ, 'app', 'renderer');
const MIMES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
                '.woff2': 'font/woff2', '.png': 'image/png', '.svg': 'image/svg+xml' };

let ok = 0, mal = 0;
const _ok = (m) => { ok++; console.log('  ok    ' + m); };
const _mal = (m, d) => { mal++; console.log('  FALLA ' + m + (d ? ' -- ' + d : '')); };

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

// La verdad sobre cada modo la dice el MOTOR, no una copia en este archivo: se le pregunta a
// nv-modos-lib.sh, que es el mismo que usa Mentis en cada turno.
function modosDelMotor() {
  const salida = execFileSync('bash', [path.join(RAIZ, 'engine', 'nv-modos-lib.sh'), 'lista'],
                              { encoding: 'utf-8' });
  return salida.split('\n').filter((l) => l.trim()).map((l) => {
    const [id, titulo, descripcion, letra, acento] = l.split('\t');
    return { id, titulo, descripcion, letra, acento };
  });
}
function panelesDe(id) {
  return execFileSync('bash', [path.join(RAIZ, 'engine', 'nv-modos-lib.sh'), 'paneles', id],
                      { encoding: 'utf-8' }).trim().split(/\s+/).filter(Boolean);
}
function banderasDe(id) {
  return execFileSync('bash', [path.join(RAIZ, 'engine', 'nv-modos-lib.sh'), 'banderas', id],
                      { encoding: 'utf-8' }).trim().split(/\s+/).filter(Boolean);
}

const PANEL_BOTON = { projects: 'btn-open-projects', schedule: 'btn-open-schedule',
                      directory: 'btn-open-directory', galeria: 'btn-open-galeria' };

(async () => {
  const modos = modosDelMotor();
  console.log(`== revision de la app: ${modos.length} modos ==\n`);

  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: 1280, height: 860 } });
  const errores = [];
  pagina.on('pageerror', (e) => {
    const linea = (String(e.stack || '').split('\n')[1] || '').trim();
    errores.push(String(e.message) + (linea ? '  <- ' + linea : ''));
  });
  pagina.on('console', (m) => { if (m.type() === 'error') errores.push('console: ' + m.text().slice(0, 160)); });

  await pagina.addInitScript(() => {
    const base = {
      onboardingStatus: async () => ({ ok: true, done: true }),
      listarArtefactosProyecto: async () => ({ ok: true, archivos: [], total: 0, modo: 'code' }),
      listarCreaciones: async (modo) => ({ ok: true, archivos: [], total: 0, modo }),
      verArtefacto: async () => ({ ok: true, tipo: 'texto', nombre: 'x.md', ext: '.md', texto: 'hola' }),
      listFolders: async () => ({ folders: [], assignments: {} }),
      listProjects: async () => [],
      listConversations: async () => [],
      onLog: (cb) => { window.__onLog = cb; },
      modosLista: async () => ({ modos: window.__MODOS || [], actual: window.__MODO_ACTUAL || 'mentis' }),
      elegirModo: async (id) => { window.__MODO_ACTUAL = id; return { ok: true, modo: id }; },
      listarTareas: async () => ({ ok: true, tareas: [] }),
      getSettings: async () => ({ ok: true, settings: {} }),
      listarConectores: async () => ({ ok: true, conectores: [] }),
    };
    window.mentisAPI = new Proxy(base, {
      get: (o, p) => (p in o ? o[p]
        : (typeof p === 'string' && /^(list|get)/.test(p) ? async () => [] : async () => ({ ok: true }))),
    });
  });

  // EL CASO DE BORDE QUE ENCONTRO ESTA REVISION: la lista de modos vacia. Si modos.json se
  // corrompe o el motor no lo puede leer, la app no puede explotar con un error de JavaScript.
  // Se prueba ANTES de cargar los modos de verdad, que es justo el momento en que pasaba.
  const { srv, puerto } = await servir();
  await pagina.goto('http://127.0.0.1:' + puerto + '/index.html', { waitUntil: 'networkidle' });
  await pagina.evaluate((ms) => { window.__MODOS = ms; }, modos);
  await pagina.waitForTimeout(400);

  for (const modo of modos) {
    console.log(`-- ${modo.titulo} (${modo.id})`);
    const antes = errores.length;
    await pagina.evaluate((id) => {
      window.MENTIS_MODO_ACTUAL = id;
      window.__MODO_ACTUAL = id;
      if (window.panelEstudio && window.panelEstudio.aplicar) window.panelEstudio.aplicar(id);
    }, modo.id);
    await pagina.waitForTimeout(250);

    // 1) Los paneles que el modo declara tienen que existir y abrirse.
    const declarados = panelesDe(modo.id);
    for (const panel of declarados) {
      const boton = PANEL_BOTON[panel];
      if (!boton) { _mal(`${modo.id}: panel '${panel}' no tiene boton conocido`); continue; }
      const existe = await pagina.evaluate((b) => !!document.getElementById(b), boton);
      if (!existe) { _mal(`${modo.id}: falta el boton del panel '${panel}' (#${boton})`); continue; }
      const abrio = await pagina.evaluate(async (b) => {
        const el = document.getElementById(b);
        el.click();
        await new Promise((r) => setTimeout(r, 250));
        // Algo tiene que haberse abierto: el visor, un panel lateral o un dialogo.
        const visibles = [...document.querySelectorAll('#visor,.panel, dialog,.modal, aside')]
.filter((n) => !n.classList.contains('hidden') && n.getBoundingClientRect().width > 60);
        return visibles.length > 0;
      }, boton);
      if (abrio) _ok(`${modo.id}: el panel '${panel}' abre`);
      else _mal(`${modo.id}: el panel '${panel}' no abrio nada visible`);
      await pagina.evaluate(() => {
        const v = document.getElementById('visor'); if (v) v.classList.add('hidden');
        document.querySelectorAll('dialog[open]').forEach((d) => d.close());
      });
    }

    // 2) LA COHERENCIA QUE IMPORTA: ningun boton de capacidad puede estar visible si el motor no
    // le dio la bandera. Es el caso que modos.json documenta como el peligro concreto -- la app
    // ofreciendo algo que el motor va a rechazar.
    const banderas = banderasDe(modo.id);
    const prometidos = await pagina.evaluate(() => {
      const out = [];
      document.querySelectorAll('[data-bandera]').forEach((b) => {
        const r = b.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) out.push(b.getAttribute('data-bandera'));
      });
      return out;
    });
    const demas = prometidos.filter((f) => !banderas.includes(f));
    if (demas.length === 0) _ok(`${modo.id}: ningun boton promete algo que el motor no da`);
    else _mal(`${modo.id}: botones sin bandera en el motor: ${demas.join(', ')}`);

    // 3) Sin errores de JavaScript en este modo.
    const nuevos = errores.slice(antes);
    if (nuevos.length === 0) _ok(`${modo.id}: sin errores de JavaScript`);
    else _mal(`${modo.id}: ${nuevos.length} error(es)`, nuevos.slice(0, 2).join(' | '));

    await pagina.screenshot({ path: path.join(__dirname, `_revision-${modo.id}.png`) });
  }

  // Lista vacia, a proposito, para comprobar que degrada en vez de romperse.
  const antesVacio = errores.length;
  await pagina.evaluate(async () => {
    window.__MODOS = [];
    if (window.pintarFichas) await window.pintarFichas();
    else { const b = document.getElementById('btn-modos'); if (b) b.click(); }
  });
  await pagina.waitForTimeout(300);
  if (errores.length === antesVacio) _ok('con la lista de modos VACIA la app degrada y no se rompe');
  else _mal('lista de modos vacia', errores.slice(antesVacio)[0]);

  console.log('');
  if (errores.length === 0) _ok('la app no tiro NINGUN error de JavaScript en toda la recorrida');
  else _mal(`${errores.length} errores en total`, errores.slice(0, 3).join(' | '));

  await navegador.close();
  srv.close();
  console.log(`\n== ${ok} ok, ${mal} mal ==`);
  process.exit(mal ? 1 : 0);
})();
