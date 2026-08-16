// captura-galeria-tablero.js -- las dos cosas de la tanda del 2026-08-15 que quedaron SIN probar
// en vivo: la galería del modo Code y el tablero de tareas de Cowork.
//
// POR QUE EXISTE: las dos se escribieron, se empaquetaron y se publicaron sin que nadie las viera
// funcionar. "El código está bien" no es lo mismo que "lo vi andar", y este proyecto ya tiene una
// lista de features que estaban cerradas y fallaban en vivo.
//
// QUE PRUEBA Y QUE NO. Corre el renderer REAL (renderer.js y visor.js de producción) contra un
// window.mentisAPI simulado, igual que captura-tanda-2026-08-15.js. Entonces prueba de verdad:
// qué endpoint pide la galería según el modo, qué título muestra, qué pinta, y que el tablero se
// tache. NO prueba el handler de Electron del otro lado del IPC -- eso vive en main.js y necesita
// la app abierta. Por eso ademas se comprueba el CONTRATO de las lineas del tablero contra el
// bash real, que es la costura donde los dos programas pueden estar verdes por separado y no
// entenderse entre si (misma idea que aprobacion-contrato.test.js).
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

// ---- 1) EL CONTRATO DEL TABLERO, sin navegador -------------------------------------------------
// El motor escribe una linea por stderr y el renderer la parsea con una expresion regular. Los dos
// se leen de los archivos de PRODUCCION: si alguien cambia una punta, esto se pone rojo.
function contratoTablero() {
  const rjs = fs.readFileSync(path.join(RENDERER, 'renderer.js'), 'utf-8');
  const agente = fs.readFileSync(path.join(RAIZ, 'engine', 'nv-agent.sh'), 'utf-8');

  // Se reconstruyen con new RegExp y NO con eval: lo que hace falta es la expresion tal cual
  // esta escrita en produccion, no ejecutar el archivo. eval() aca abriria la puerta a correr
  // cualquier cosa que alguien deje escrita en renderer.js, para el mismo resultado.
  const leerRegex = (fuente, nombre) => {
    const m = fuente.match(new RegExp('const ' + nombre + ' = /(.*)/([gimsuy]*);'));
    return m ? new RegExp(m[1], m[2]) : null;
  };
  const RE_PLAN = leerRegex(rjs, 'PLAN_LOG_RE');
  const RE_HECHO = leerRegex(rjs, 'PLAN_HECHO_LOG_RE');
  if (!RE_PLAN || !RE_HECHO) { _mal('encontrar los regex del tablero en renderer.js'); return; }

  // Las lineas tal como las escribe el bash, sacadas del propio nv-agent.sh.
  const emitePlan = /echo "\[nv-agent\] PLAN: \$_n\|\$_txt\|\$\{_arch:-\}"/.test(agente);
  const emiteHecho = /echo "\[nv-agent\] PLAN-HECHO: \$n"/.test(agente);
  if (emitePlan && emiteHecho) _ok('el motor sigue emitiendo PLAN y PLAN-HECHO');
  else _mal('el motor emite las lineas del tablero (cambio el formato en nv-agent.sh)');

  const casos = [
    ['[nv-agent] PLAN: 1|Escribir el script|salida.sh', true],
    ['[nv-agent] PLAN: 2|Probarlo|', true],            // sin archivo: el caso comun
    ['[nv-agent] PLAN: 3|Con | pipe en el texto|x.md', true],
  ];
  let bien = 0;
  for (const [linea, esperado] of casos) {
    if (Boolean(RE_PLAN.test(linea)) === esperado) bien++;
  }
  if (bien === casos.length) _ok('el renderer parsea las 3 formas de la linea PLAN');
  else _mal(`el renderer parsea PLAN (${bien}/${casos.length})`);

  if (RE_HECHO.test('[nv-agent] PLAN-HECHO: 2')) _ok('el renderer parsea PLAN-HECHO');
  else _mal('el renderer parsea PLAN-HECHO');
}

(async () => {
  console.log('== contrato motor <-> tablero ==');
  contratoTablero();

  console.log('== la interfaz de verdad ==');
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: 1280, height: 860 } });
  const errores = [];
  // Con el stack y no solo el mensaje: "no puedo leer 'find' de undefined" sin la linea obliga a
  // adivinar cual de las quince llamadas fue.
  pagina.on('pageerror', (e) => {
    const linea = (String(e.stack || '').split('\n')[1] || '').trim();
    errores.push(String(e.message) + (linea ? '  <- ' + linea : ''));
  });

  await pagina.addInitScript(() => {
    window.__llamadas = [];
    const base = {
      onboardingStatus: async () => ({ ok: true, done: true }),
      // Lo que devolveria el handler de Code: archivos DEL PROYECTO, con su ruta relativa.
      listarArtefactosProyecto: async () => {
        window.__llamadas.push('listarArtefactosProyecto');
        return { ok: true, fuente: 'proyecto', modo: 'code', total: 3, archivos: [
          { nombre: 'index.html', ruta: 'C:/proy/index.html', ext: '.html', tipo: 'html', bytes: 1200, cuando: Date.now(), modo: 'code' },
          { nombre: 'src/app.js', ruta: 'C:/proy/src/app.js', ext: '.js', tipo: 'externo', bytes: 800, cuando: Date.now() - 1000, modo: 'code' },
          { nombre: 'LEEME.md', ruta: 'C:/proy/LEEME.md', ext: '.md', tipo: 'texto', bytes: 300, cuando: Date.now() - 2000, modo: 'code' },
        ] };
      },
      // Y lo que devolveria en cualquier otro modo: las CREACIONES.
      listarCreaciones: async (modo) => {
        window.__llamadas.push('listarCreaciones:' + modo);
        return { ok: true, total: 1, archivos: [
          { nombre: 'logo.png', ruta: 'C:/Users/x/Documents/Mentis/logo.png', ext: '.png', tipo: 'imagen', bytes: 4000, cuando: Date.now(), modo: 'designe' },
        ] };
      },
      verArtefacto: async () => ({ ok: true, tipo: 'imagen', dataUrl: 'data:image/gif;base64,R0lGODlhAQABAAAAACw=' }),
      // Se guarda el callback con el que el renderer escucha al motor. Es la puerta por la que
      // entran las lineas de verdad (renderer.js:1698), y por eso el tablero se prueba mandandole
      // lineas por aca en vez de llamar a window.tablero a mano: por esta puerta pasa TAMBIEN el
      // abrir del panel, que es lo que hace que el tablero se VEA.
      onLog: (cb) => { window.__onLog = cb; },
      // Estas devuelven una FORMA, no una lista: el comodin de abajo daria [] y el renderer
      // explota al desestructurarlas. Se copian del contrato real (app/lib/folder-store.js
      // devuelve {folders, assignments}) -- si el simulador miente, el arnes deja de poder ver
      // los errores de JavaScript de verdad, que es la mitad de para lo que sirve.
      listFolders: async () => ({ folders: [], assignments: {} }),
      // Ojo: listProjects devuelve un ARRAY pelado (project-store.js:127 hace.map), no {projects}.
      // El {projects: []} que se ve en ese archivo es de loadIndex, que es otra funcion.
      listProjects: async () => [],
      // Se llama modosLista (preload.js:60) y devuelve {modos, actual} -- sin 'ok'. Con el nombre
      // mal, el comodin devolvia {ok:true} y pintarFichas se caia con "undefined.find".
      modosLista: async () => ({ modos: [
        { id: 'mentis', titulo: 'Mentis', descripcion: 'Conversar', letra: 'google-sans', acento: 'medio' },
        { id: 'code', titulo: 'Mentis Code', descripcion: 'Programar', letra: 'silkscreen', acento: 'oscuro' },
        { id: 'cowork', titulo: 'Mentis Cowork', descripcion: 'Coordinar', letra: 'plus-jakarta', acento: 'medio' },
      ], actual: 'mentis' }),
    };
    window.mentisAPI = new Proxy(base, {
      get: (o, p) => (p in o ? o[p]
        : (typeof p === 'string' && /^(list|get)/.test(p) ? async () => [] : async () => ({ ok: true }))),
    });
  });

  const { srv, puerto } = await servir();
  await pagina.goto('http://127.0.0.1:' + puerto + '/index.html', { waitUntil: 'networkidle' });
  await pagina.waitForTimeout(500);

  // --- GALERIA EN CODE: tiene que listar el PROYECTO, no las creaciones ---------------------
  await pagina.evaluate(() => { window.MENTIS_MODO_ACTUAL = 'code'; window.__llamadas = []; });
  await pagina.evaluate(() => window.MentisVisor.galeria());
  await pagina.waitForTimeout(400);
  const enCode = await pagina.evaluate(() => ({
    llamadas: window.__llamadas.slice(),
    titulo: document.getElementById('visor-nombre').textContent,
    tarjetas: document.querySelectorAll('.visor-tarjeta').length,
    textos: [...document.querySelectorAll('.visor-tarjeta')].map((t) => t.textContent.trim()).join(' | '),
    visible: !document.getElementById('visor').classList.contains('hidden'),
  }));
  if (enCode.llamadas.includes('listarArtefactosProyecto') && !enCode.llamadas.some((l) => l.startsWith('listarCreaciones'))) {
    _ok('en Code la galeria pide los archivos DEL PROYECTO');
  } else {
    _mal('en Code pide el proyecto -- llamo a: ' + enCode.llamadas.join(', '));
  }
  if (/proyecto/i.test(enCode.titulo)) _ok(`el titulo lo dice: "${enCode.titulo}"`);
  else _mal(`titulo de la galeria en Code: "${enCode.titulo}"`);
  if (enCode.tarjetas === 3) _ok('pinta las 3 tarjetas del proyecto');
  else _mal(`pinta las tarjetas del proyecto (vi ${enCode.tarjetas} de 3)`);
  if (/src\/app\.js/.test(enCode.textos)) _ok('muestra la ruta relativa y no solo el nombre suelto');
  else _mal('muestra la ruta relativa -- vi: ' + enCode.textos.slice(0, 120));
  await pagina.screenshot({ path: path.join(__dirname, '_2026-08-15-galeria-code.png') });

  // --- GALERIA EN OTRO MODO: las creaciones ------------------------------------------------
  await pagina.evaluate(() => { document.getElementById('visor').classList.add('hidden'); window.MENTIS_MODO_ACTUAL = 'designe'; window.__llamadas = []; });
  await pagina.evaluate(() => window.MentisVisor.galeria());
  await pagina.waitForTimeout(400);
  const enDesigne = await pagina.evaluate(() => ({
    llamadas: window.__llamadas.slice(),
    titulo: document.getElementById('visor-nombre').textContent,
    tarjetas: document.querySelectorAll('.visor-tarjeta').length,
  }));
  if (enDesigne.llamadas.includes('listarCreaciones:designe')) _ok('en Designe la galeria pide las CREACIONES de ese modo');
  else _mal('en Designe pide creaciones -- llamo a: ' + enDesigne.llamadas.join(', '));
  if (/creaste/i.test(enDesigne.titulo)) _ok(`el titulo cambia con el modo: "${enDesigne.titulo}"`);
  else _mal(`titulo en Designe: "${enDesigne.titulo}"`);
  await pagina.screenshot({ path: path.join(__dirname, '_2026-08-15-galeria-designe.png') });

  // --- EL TABLERO DE COWORK ----------------------------------------------------------------
  await pagina.evaluate(() => { document.getElementById('visor').classList.add('hidden'); });
  // POR LA PUERTA DE PRODUCCION, no llamando al tablero a mano. La primera version de este arnes
  // hacia window.tablero.agregar(...) directo: los quince asserts daban verde y la FOTO mostraba
  // la app sin ningun tablero. Faltaba lo que hace handleAgentLogLine ademas de agregar la fila:
  // abrir el panel. Un tablero que esta en el DOM y no se ve es un tablero que no existe.
  await pagina.evaluate(() => {
    window.tablero.limpiar();
    window.__onLog('[nv-agent] PLAN: 1|Leer el archivo de entrada|entrada.csv');
    window.__onLog('[nv-agent] PLAN: 2|Escribir el resumen|resumen.md');
    window.__onLog('[nv-agent] PLAN: 3|Probar que corre|');
  });
  await pagina.waitForTimeout(300);
  const antes = await pagina.evaluate(() => ({
    items: document.querySelectorAll('.tablero-item').length,
    tachadas: document.querySelectorAll('.tablero-item.hecha').length,
    titulo: (document.querySelector('.tablero-titulo') || {}).textContent || '',
    visible: !document.getElementById('tablero-tareas').classList.contains('hidden'),
    // El title dice que se espera: es lo unico que explica una tarea sin tachar.
    pistas: [...document.querySelectorAll('.tablero-item')].map((li) => li.title),
  }));
  if (antes.items === 3 && antes.visible) _ok('el tablero aparece con los 3 puntos del plan');
  else _mal(`el tablero aparece (items=${antes.items}, visible=${antes.visible})`);

  // VISIBLE DE VERDAD, no "sin la clase hidden". Esto es lo que atrapo que la primera version del
  // arnes diera 15 verdes con el tablero invisible: el elemento existia, no tenia hidden, y estaba
  // adentro de un panel cerrado. Se mide el rectangulo real en pantalla.
  const caja = await pagina.locator('#tablero-tareas').boundingBox();
  if (caja && caja.width > 40 && caja.height > 20) {
    _ok(`el tablero se VE en pantalla (${Math.round(caja.width)}x${Math.round(caja.height)} px)`);
  } else {
    _mal('el tablero se ve en pantalla', 'esta en el DOM pero no ocupa lugar: ' + JSON.stringify(caja));
  }
  if (antes.tachadas === 0) _ok('ningun punto arranca tachado');
  else _mal(`arrancaron ${antes.tachadas} puntos tachados`);
  if (/plan/i.test(antes.titulo)) _ok(`el tablero se titula "${antes.titulo}"`);
  else _mal('el tablero no tiene titulo');
  if (antes.pistas[2] && /no se marca sola/i.test(antes.pistas[2])) _ok('un punto sin archivo avisa que no se marca solo');
  else _mal('el punto sin archivo no explica por que no se va a tachar');

  await pagina.evaluate(() => { window.__onLog('[nv-agent] PLAN-HECHO: 2'); });
  await pagina.waitForTimeout(200);
  const despues = await pagina.evaluate(() => ({
    tachadas: [...document.querySelectorAll('.tablero-item.hecha')].map((li) => li.textContent.trim()),
  }));
  if (despues.tachadas.length === 1 && /resumen/i.test(despues.tachadas[0])) {
    _ok('se tacha EL punto que se completo, y solo ese');
  } else {
    _mal('el tachado marca el punto correcto -- tachadas: ' + JSON.stringify(despues.tachadas));
  }
  await pagina.screenshot({ path: path.join(__dirname, '_2026-08-15-tablero-cowork.png') });

  if (errores.length === 0) _ok('el renderer no tiro ningun error de JavaScript');
  else _mal('errores en la pagina: ' + errores.slice(0, 2).join(' | '));

  await navegador.close();
  srv.close();
  console.log(`\n== ${ok} ok, ${mal} mal ==`);
  process.exit(mal ? 1 : 0);
})();
