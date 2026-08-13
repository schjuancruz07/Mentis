// captura-identidad.js -- saca una foto de la interfaz real para poder MIRARLA, y le pregunta a
// la pagina que fuente y que colores esta usando de verdad.
//
// POR QUE EXISTE (2026-08-10): los tests miden contraste y presencia de archivos, pero ninguno
// contesta "¿se ve bien?". Esa pregunta ya costo caro: se dieron por cerradas cosas que en vivo
// fallaban. Esto abre la interfaz en un Chromium de verdad y guarda un PNG.
//
// POR QUE PLAYWRIGHT Y NO ELECTRON, que seria el motor exacto de la app: Electron en Windows es
// una aplicacion de subsistema grafico. Lanzarla apuntando a un script suelto desde una terminal
// no funciona de forma confiable -- se queda colgada sin escribir una linea, porque su stdout no
// esta enganchado a la consola y porque encuentra el package.json de app/ y arranca Mentis entero
// en vez del script. Playwright ya esta instalado en browser-server/ (lo usa la herramienta
// 'browse') y da un Chromium controlable con salida normal.
//
// LA DIFERENCIA IMPORTA POCO Y HAY QUE DECIRLA IGUAL: Electron 43 y el Chromium de Playwright no
// son el mismo binario. Para CSS, fuentes y colores dan lo mismo; para algo que dependa de una
// API propia de Electron, esta foto no sirve como prueba.
//
// NO ES UN TEST AUTOMATICO: no sabe si algo se ve feo, solo saca la foto y reporta datos duros.
// Sirve para no hacerle mirar al usuario algo que ya esta obviamente roto.
//
// Uso, con un servidor estatico sirviendo renderer/:
//     node app/test/captura-identidad.js http://127.0.0.1:8791/index.html salida.png

'use strict';
const path = require('path');
const fs = require('fs');

// Playwright vive en browser-server/, no en app/: se lo pide por ruta explicita en vez de
// duplicar la dependencia (son ~300 MB con el navegador incluido).
const RAIZ = path.resolve(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));

const url = process.argv[2];
const salida = path.resolve(process.argv[3] || 'captura.png');
const ancho = parseInt(process.argv[4] || '1280', 10);
const alto = parseInt(process.argv[5] || '860', 10);

if (!url) { console.error('falta la URL'); process.exit(1); }

(async () => {
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({ viewport: { width: ancho, height: alto } });

  const errores = [];
  pagina.on('pageerror', (e) => errores.push(String(e.message)));
  // Las fuentes que no cargan aparecen como pedidos fallidos, no como errores de JS: sin esto un
  // woff2 con la ruta mal escrita pasaria desapercibido y la foto saldria con la letra de respaldo.
  pagina.on('requestfailed', (r) => errores.push(`no cargo: ${r.url().split('/').pop()}`));

  await pagina.goto(url, { waitUntil: 'networkidle' }).catch((e) => errores.push('goto: ' + e.message));

  // document.fonts.ready espera a que TERMINEN de cargar las fuentes. Sin esto la foto sale con
  // la sans del sistema y despues cambia sola: se estaria fotografiando el estado intermedio.
  await pagina.evaluate(() => document.fonts.ready).catch(() => {});
  await pagina.waitForTimeout(1500);

  await pagina.screenshot({ path: salida });

  const info = await pagina.evaluate(() => {
    const cs = getComputedStyle(document.body);
    const raiz = getComputedStyle(document.documentElement);
    const marca = document.getElementById('header-wordmark');

    // NO SE USA document.fonts.check(): miente. Cada familia esta declarada dos veces (subconjunto
    // 'latin' y 'latin-ext') y check() devuelve false si CUALQUIERA de las dos sigue sin cargar --
    // cosa que pasa siempre, porque latin-ext solo se baja si aparece un caracter que lo necesite.
    // O sea: da false para una fuente que se esta viendo perfecta en pantalla. Ya me hizo dar por
    // rota una fuente que andaba.
    //
    // Lo que si prueba que una fuente se APLICO: medir. Se escribe el mismo texto con la familia
    // pedida y con la del sistema; si los dos anchos son identicos, el navegador cayo al respaldo.
    const medir = (familia, peso) => {
      const s = document.createElement('span');
      s.style.cssText = `font-family:${familia};font-weight:${peso};font-size:40px;` +
                        'position:absolute;visibility:hidden;white-space:nowrap';
      s.textContent = 'MENTIS CODE 123';
      document.body.appendChild(s);
      const w = s.offsetWidth;
      s.remove();
      return w;
    };
    // El ancho solo NO alcanza: dos familias distintas pueden medir casi lo mismo (Playfair salio
    // a 2 px de la del sistema), y ahi el resultado seria un aprobado de casualidad. La prueba
    // decisiva es el estado real de la cara en document.fonts: 'loaded' significa que el navegador
    // bajo y activo ESE archivo. Se piden las dos señales y solo pasa si coinciden.
    const respaldo = medir('sans-serif', 400);
    const familias = {
      'Google Sans Flex': 400, 'Playfair Display': 800, 'Syne': 700,
      'Silkscreen': 400, 'Plus Jakarta Sans': 600,
    };
    const fuentes = {};
    for (const [f, peso] of Object.entries(familias)) {
      const ancho = medir(`"${f}"`, peso);
      const bajada = [...document.fonts].some((c) => c.family === f && c.status === 'loaded');
      if (!bajada) fuentes[f] = 'NO SE BAJO NINGUNA CARA de esta familia';
      else if (ancho === respaldo) fuentes[f] = `bajada pero NO SE APLICO (mide igual que sans-serif: ${ancho}px)`;
      else fuentes[f] = `ok -- archivo bajado y aplicado (${ancho}px vs ${respaldo}px del sistema)`;
    }

    return {
      fuenteCuerpo: cs.fontFamily,
      fuenteMarca: marca ? getComputedStyle(marca).fontFamily : '(no hay wordmark en esta pagina)',
      colorMarca: marca ? getComputedStyle(marca).color : '-',
      fondo: cs.backgroundColor,
      acento: raiz.getPropertyValue('--acento').trim(),
      acentoRgb: raiz.getPropertyValue('--acento-rgb').trim(),
      temaAplicado: document.documentElement.dataset.tema || '(el JS del tema no corrio)',
      fuentes,
    };
  });

  console.log(`captura: ${salida}`);
  console.log(JSON.stringify(info, null, 2));
  if (errores.length) console.log('\nproblemas:\n  ' + errores.slice(0, 12).join('\n  '));
  else console.log('\nproblemas: ninguno');

  await navegador.close();
})().catch((e) => { console.error('FALLO:', e.message); process.exit(1); });
