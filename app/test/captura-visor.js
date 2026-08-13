// captura-visor.js -- el visor mostrando de verdad cada tipo de archivo (2026-08-12, fase 2).
//
// POR QUE EXISTE: "se ve adentro de la app" no se puede verificar leyendo el codigo. Un data URL
// mal armado, un import de three.js con la ruta cambiada o un canvas de 0px de alto se leen
// perfecto en el archivo y dejan la pantalla en blanco.
//
// COMO: se abre la interfaz en Chromium, se le enchufa un window.mentisAPI de mentira que
// devuelve archivos REALES (un PNG y un GLB armados aca), y se le pide al navegador que diga que
// dibujo. El stub reemplaza SOLO el puente de Electron -- el visor, el CSS y three.js son los de
// verdad, que es lo que se quiere probar.
'use strict';
const path = require('path');
const fs = require('fs');

const http = require('http');

const RAIZ = path.join(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));
const RENDERER = path.join(RAIZ, 'app', 'renderer');

// SE SIRVE POR HTTP Y NO POR file:// A PROPOSITO. visor.js es un modulo ES (lo necesita para el
// import dinamico de three.js) y Chromium bloquea los modulos cargados desde file:// por CORS:
// el archivo aparece como "no cargo" y window.MentisVisor nunca existe. Electron los carga bien
// porque su protocolo file:// tiene otro tratamiento, asi que el fallo era del arnes y no de la
// app -- pero un test que no puede distinguir esos dos casos no sirve.
const MIMES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
                '.woff2': 'font/woff2', '.png': 'image/png', '.svg': 'image/svg+xml',
                '.json': 'application/json' };
function servir() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const limpio = decodeURIComponent(req.url.split('?')[0]);
      const abs = path.join(RENDERER, limpio === '/' ? 'index.html' : limpio);
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

// Un PNG rojo de 2x2, valido, escrito a mano en base64: no depende de que haya una imagen suelta
// en el disco ni de que Mentis haya generado algo antes.
const PNG_2X2 = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR42mP8z8BQz0AEYBxVSF+FAP5FDvcfRYWgAAAAAElFTkSuQmCC';

// Un GLB minimo y valido: un triangulo. Se arma con el codigo de abajo en vez de guardar un
// binario en el repo, asi el test no depende de un archivo que alguien puede borrar.
function glbDeUnTriangulo() {
  const gltf = {
    asset: { version: '2.0' },
    scenes: [{ nodes: [0] }], scene: 0,
    nodes: [{ mesh: 0 }],
    meshes: [{ primitives: [{ attributes: { POSITION: 0 } }] }],
    accessors: [{ bufferView: 0, componentType: 5126, count: 3, type: 'VEC3',
                  min: [0, 0, 0], max: [1, 1, 0] }],
    bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: 36 }],
    buffers: [{ byteLength: 36 }],
  };
  const vertices = new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]);
  const bin = Buffer.from(vertices.buffer);
  const json = Buffer.from(JSON.stringify(gltf), 'utf8');
  const pad = (b, c) => b.length % 4 === 0 ? b
    : Buffer.concat([b, Buffer.alloc(4 - (b.length % 4), c)]);
  const jsonPad = pad(json, 0x20), binPad = pad(bin, 0);
  const total = 12 + 8 + jsonPad.length + 8 + binPad.length;
  const cab = Buffer.alloc(12);
  cab.writeUInt32LE(0x46546c67, 0); cab.writeUInt32LE(2, 4); cab.writeUInt32LE(total, 8);
  const cJson = Buffer.alloc(8);
  cJson.writeUInt32LE(jsonPad.length, 0); cJson.writeUInt32LE(0x4e4f534a, 4);
  const cBin = Buffer.alloc(8);
  cBin.writeUInt32LE(binPad.length, 0); cBin.writeUInt32LE(0x004e4942, 4);
  return Buffer.concat([cab, cJson, jsonPad, cBin, binPad]);
}

(async () => {
  const GLB_B64 = glbDeUnTriangulo().toString('base64');
  // Estructuras REALES, las que dejo capabilities/estructura.sh: agua desde PubChem y la celda
  // FCC del calcio. Si no estan, el test lo dice en vez de saltearse la parte de Science.
  const CREACIONES = path.join(require('os').homedir(), 'Documents', 'Mentis');
  const leerEst = (n) => { try { return JSON.parse(fs.readFileSync(path.join(CREACIONES, n), 'utf8')); }
                           catch { return null; } };
  const AGUA = leerEst('agua.mol3d.json');
  const CALCIO = leerEst('calcio.mol3d.json');
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: 1280, height: 860 } });
  const errores = [];
  pagina.on('pageerror', (e) => errores.push(String(e.message)));
  pagina.on('requestfailed', (r) => errores.push('no cargo: ' + r.url().split('/').pop()));

  // El stub va detras de un Proxy: renderer.js llama a decenas de funciones del puente al
  // arrancar (onLog, listConversations,...) y si falta una sola, tira y se lleva puesto el
  // resto del arranque -- incluido el visor, que no tiene nada que ver. Lo que no esta definido
  // devuelve una funcion inofensiva en vez de undefined.
  await pagina.addInitScript(({ png, glb, agua, calcio }) => {
    const real = {
      verArtefacto: async (ruta) => {
        if (ruta.endsWith('.png')) return { ok: true, tipo: 'imagen', nombre: 'render.png', ext: '.png',
                                            dataUrl: 'data:image/png;base64,' + png };
        if (ruta.endsWith('.glb')) return { ok: true, tipo: 'modelo3d', nombre: 'pieza.glb', ext: '.glb',
                                            dataUrl: 'data:model/gltf-binary;base64,' + glb };
        if (ruta.endsWith('agua.mol3d.json')) return { ok: true, tipo: 'molecula', nombre: 'agua.mol3d.json', ext: '.json', estructura: agua };
        if (ruta.endsWith('calcio.mol3d.json')) return { ok: true, tipo: 'molecula', nombre: 'calcio.mol3d.json', ext: '.json', estructura: calcio };
        if (ruta.endsWith('.docx')) return { ok: true, tipo: 'externo', nombre: 'informe.docx', ext: '.docx' };
        if (ruta.endsWith('.md')) return { ok: true, tipo: 'texto', nombre: 'notas.md', ext: '.md',
                                           texto: 'hola desde el visor' };
        return { ok: false, error: 'tipo no simulado' };
      },
      listarCreaciones: async () => ({ ok: true, archivos: [
        { nombre: 'render.png', ruta: 'C:/x/render.png', ext: '.png', tipo: 'imagen', bytes: 10, cuando: 2 },
        { nombre: 'informe.docx', ruta: 'C:/x/informe.docx', ext: '.docx', tipo: 'externo', bytes: 10, cuando: 1 },
      ] }),
      openArtifact: async () => ({ ok: true }),
      // el usuario ya pasó el onboarding hace meses. Sin esto el stub lo declara pendiente y la
      // pantalla de bienvenida se dibuja ENCIMA del visor: el test seguía midiendo bien el DOM,
      // pero la foto mostraba "Bienvenido a Mentis" y no servía como evidencia de nada.
      onboardingStatus: async () => ({ ok: true, done: true, pendiente: false, mostrar: false }),
    };
    // Las funciones que empiezan con "list" devuelven un ARRAY, no un objeto: renderer.js las
    // recorre con for..of y un {ok:true} le explota con "projects is not iterable". El stub tiene
    // que parecerse al puente de verdad o los errores que genera tapan los que importan.
    window.mentisAPI = new Proxy(real, {
      get: (obj, prop) => {
        if (prop in obj) return obj[prop];
        if (typeof prop === 'string' && /^(list|get)/.test(prop)) return async () => [];
        return async () => ({ ok: true });
      },
    });
  }, { png: PNG_2X2, glb: GLB_B64, agua: AGUA, calcio: CALCIO });

  const { srv, puerto } = await servir();
  await pagina.goto(`http://127.0.0.1:${puerto}/index.html`, { waitUntil: 'networkidle' }).catch(() => {});
  await pagina.waitForTimeout(600);

  // A partir de aca se miden los errores DEL VISOR. Los de mas arriba son de renderer.js
  // arrancando contra un puente de mentira -- cada funcion del puente real devuelve una forma
  // distinta ({folders:[]}, [], {ok:true}...) y copiarlas todas seria un arnes mas grande que lo
  // que prueba, sin medir nada del visor. Lo que no puede pasar es que el visor rompa algo, y eso
  // se ve en lo que ocurre de aca en adelante.
  errores.length = 0;

  const hayVisor = await pagina.evaluate(() => !!(window.MentisVisor && window.MentisVisor.abrir));
  hayVisor ? _ok('visor.js cargo y publico window.MentisVisor')
           : _mal('window.MentisVisor no existe: el modulo no cargo');

  if (hayVisor) {
    // --- imagen ---
    await pagina.evaluate(() => window.MentisVisor.abrir('C:/x/render.png'));
    await pagina.waitForTimeout(500);
    const img = await pagina.evaluate(() => {
      const i = document.querySelector('#visor-cuerpo.visor-imagen');
      return i ? { visible: !document.getElementById('visor').classList.contains('hidden'),
                   ancho: i.naturalWidth, nombre: document.getElementById('visor-nombre').textContent } : null;
    });
    img && img.visible && img.ancho > 0
      ? _ok(`imagen dibujada adentro de la app (${img.ancho}px de ancho real, "${img.nombre}")`)
      : _mal('la imagen no se dibujo: ' + JSON.stringify(img));
    await pagina.screenshot({ path: path.join(__dirname, '_visor-imagen.png') });

    // --- 3D: lo que importa es que three.js arranque y pinte un canvas con tamaño ---
    await pagina.evaluate(() => window.MentisVisor.abrir('C:/x/pieza.glb'));
    await pagina.waitForTimeout(2500);
    const tres = await pagina.evaluate(() => {
      const c = document.querySelector('#visor-cuerpo.visor-3d canvas');
      if (!c) return null;
      const r = c.getBoundingClientRect();
      return { ancho: Math.round(r.width), alto: Math.round(r.height),
               contexto: !!(c.getContext('webgl2') || c.getContext('webgl')) };
    });
    tres && tres.ancho > 100 && tres.alto > 100
      ? _ok(`three.js dibujo el modelo 3D (canvas de ${tres.ancho}x${tres.alto})`)
      : _mal('el 3D no se dibujo: ' + JSON.stringify(tres));
    await pagina.screenshot({ path: path.join(__dirname, '_visor-3d.png') });

    // --- formato que NO se puede dibujar: tiene que decirlo, no fallar ---
    await pagina.evaluate(() => window.MentisVisor.abrir('C:/x/informe.docx'));
    await pagina.waitForTimeout(400);
    const ext = await pagina.evaluate(() => {
      const m = document.querySelector('#visor-cuerpo.visor-mensaje p');
      return m ? m.textContent : null;
    });
    ext && /se abren con una aplicaci/i.test(ext)
      ? _ok('un.docx avisa que se abre afuera en vez de fallar')
      : _mal('el.docx no explico su limite: ' + ext);

    // --- galeria ---
    await pagina.evaluate(() => window.MentisVisor.galeria());
    await pagina.waitForTimeout(700);
    const gal = await pagina.evaluate(() => document.querySelectorAll('#visor-cuerpo.visor-tarjeta').length);
    gal === 2 ? _ok(`la galeria lista las ${gal} creaciones`)
              : _mal(`la galeria mostro ${gal} tarjetas, esperaba 2`);
    await pagina.screenshot({ path: path.join(__dirname, '_visor-galeria.png') });

    // --- Science: molecula real (agua) y cristal real (calcio) ---
    if (!AGUA || !CALCIO) {
      _mal('faltan las estructuras de prueba: corré  bash capabilities/estructura.sh agua  y  calcio');
    } else {
      await pagina.evaluate(() => window.MentisVisor.abrir('C:/x/agua.mol3d.json'));
      await pagina.waitForTimeout(2200);
      const mol = await pagina.evaluate(() => {
        const c = document.querySelector('#visor-cuerpo.visor-3d canvas');
        const ficha = document.querySelector('#visor-cuerpo.visor-ficha');
        return { canvas: !!c, ancho: c ? Math.round(c.getBoundingClientRect().width) : 0,
                 fuente: ficha ? ficha.querySelector('span').textContent : null };
      });
      mol.canvas && mol.ancho > 100 && /PubChem/i.test(mol.fuente || '')
        ? _ok(`la molécula de agua se dibujó y muestra su fuente ("${mol.fuente}")`)
        : _mal('la molécula no se dibujó o no cita la fuente: ' + JSON.stringify(mol));
      await pagina.screenshot({ path: path.join(__dirname, '_visor-molecula.png') });

      await pagina.evaluate(() => window.MentisVisor.abrir('C:/x/calcio.mol3d.json'));
      await pagina.waitForTimeout(2200);
      const cri = await pagina.evaluate(() => {
        const ficha = document.querySelector('#visor-cuerpo.visor-ficha');
        return { fuente: ficha ? ficha.querySelector('span').textContent : null,
                 nota: ficha && ficha.querySelector('em') ? ficha.querySelector('em').textContent : null };
      });
      /FCC/.test(cri.fuente || '') && /no hay enlaces localizados/i.test(cri.nota || '')
        ? _ok('el cristal de calcio dice su red (FCC) y aclara que no son enlaces')
        : _mal('el cristal no explica lo que muestra: ' + JSON.stringify(cri));
      await pagina.screenshot({ path: path.join(__dirname, '_visor-cristal.png') });
    }

    // --- cerrar con Esc ---
    await pagina.keyboard.press('Escape');
    await pagina.waitForTimeout(300);
    const cerrado = await pagina.evaluate(() => document.getElementById('visor').classList.contains('hidden'));
    cerrado ? _ok('Esc cierra el visor') : _mal('Esc no cerro el visor');
  }

  const graves = errores.filter((e) => !/favicon/i.test(e));
  graves.length === 0 ? _ok('usar el visor no genero ni un error de JS')
                      : _mal('errores: ' + graves.slice(0, 3).join(' | '));

  await navegador.close();
  srv.close();
  console.log(`\n== ${ok} OK, ${mal} MAL ==`);
  process.exit(mal === 0 ? 0 : 1);
})();
