// grabar-demo.js -- graba el GIF del README: Mentis funcionando de verdad (2026-08-14).
//
// POR QUE EXISTE: el README apunta a docs/mentis-demo.gif desde hace tiempo y ese archivo NUNCA
// existio, asi que la portada del repositorio publico mostraba una imagen rota. Un GIF de la app
// andando es lo primero que mira alguien que llega, y una imagen rota dice lo contrario de lo que
// el README intenta decir.
//
// QUE SE GRABA, Y POR QUE ESE EJEMPLO: se le pide una molecula y aparece en 3D con la fuente del
// dato. Es lo que mejor muestra de que se trata Mentis en cinco segundos -- no es un chat mas:
// produce algo, adentro de la app, con datos verificables.
//
// NO SE GRABA NADA DE USUARIO, y eso NO es un detalle: este archivo va al repositorio PUBLICO. La
// conversacion es inventada para la demo, la barra lateral va oculta (ahi viven los titulos de
// sus chats reales), el reloj y el clima se congelan en valores neutros, y no aparece ni su
// nombre ni su ciudad. El 2026-08-13 ya se filtraron dos cosas por archivos que nadie miro
// (ERR-149 y ERR-150): un video de la app es exactamente esa clase de archivo.
//
// Uso: node app/test/grabar-demo.js
'use strict';
const path = require('path');
const fs = require('fs');
const http = require('http');
const { execFileSync } = require('child_process');

const RAIZ = path.join(__dirname, '..', '..');
const { chromium } = require(path.join(RAIZ, 'browser-server', 'node_modules', 'playwright'));
const RENDERER = path.join(RAIZ, 'app', 'renderer');
const DOCS = path.join(RAIZ, 'docs');
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

// La estructura del agua, tal como la devuelve capabilities/estructura.sh desde PubChem. Se
// incrusta en vez de consultarla en vivo para que grabar el GIF no dependa de que haya internet
// ni de cuanto tarde PubChem: son las MISMAS coordenadas que usa la app de verdad.
const AGUA = {
  clase: 'molecula', nombre: 'agua',
  atomos: [
    { el: 'O', x: 0, y: 0, z: 0 },
    { el: 'H', x: 0.2774, y: 0.8929, z: 0.2544 },
    { el: 'H', x: 0.6068, y: -0.2383, z: -0.7169 },
  ],
  enlaces: [[0, 1, 1], [0, 2, 1]],
  elementos: { O: { radio: 0.66, color: '#FF0D0D' }, H: { radio: 0.31, color: '#FFFFFF' } },
  fuente: 'PubChem CID 962',
};

(async () => {
  fs.mkdirSync(DOCS, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'mentis-demo-'));
  const navegador = await chromium.launch();
  const pagina = await navegador.newPage({
    viewport: { width: 1100, height: 620 },
    recordVideo: { dir: tmp, size: { width: 1100, height: 620 } },
  });

  await pagina.addInitScript(({ agua }) => {
    window.mentisAPI = new Proxy({
      onboardingStatus: async () => ({ ok: true, done: true }),
      verArtefacto: async () => ({ ok: true, tipo: 'molecula', nombre: 'agua.mol3d.json', estructura: agua }),
      listarCreaciones: async () => ({ ok: true, archivos: [], total: 0 }),
      // Datos neutros: sin ciudad y con una hora fija. El bloque de bienvenida muestra el clima
      // de donde vive el usuario, y eso no va a un repositorio publico.
      getLocationWeather: async () => ({ ok: true, ciudad: '', temp: null, desc: '' }),
    }, {
      get: (o, p) => (p in o ? o[p]
        : (typeof p === 'string' && /^(list|get)/.test(p) ? async () => [] : async () => ({ ok: true }))),
    });
  }, { agua: AGUA });

  const { srv, puerto } = await servir();
  await pagina.goto(`http://127.0.0.1:${puerto}/index.html`, { waitUntil: 'networkidle' }).catch(() => {});
  await pagina.waitForTimeout(700);

  // Barra lateral oculta: ahi viven los titulos de las conversaciones reales del usuario.
  //
  // Y LA TARJETA DEL CLIMA SE VACIA A MANO. El stub devuelve ciudad vacia, pero el renderer la
  // toma ADEMAS de location-cache.json -- un archivo que ya estaba en disco con el barrio del usuario
  // adentro. En la primera grabacion el barrio salio en pantalla durante cuatro segundos y
  // solo aparecio al revisar los fotogramas uno por uno. Un stub no alcanza cuando el dato tiene
  // dos fuentes: hay que borrar lo que quedo pintado.
  await pagina.evaluate(() => {
    document.getElementById('app').classList.add('sin-sidebar');
    // Se ocultan SOLO las tarjetas de reloj y clima, no la bienvenida entera: el saludo
    // "¿Sobre qué pensamos?" es parte de la identidad y no dice nada de nadie. Escondiendo todo,
    // el GIF arrancaba con una pantalla negra vacia -- pobre para la portada del repositorio.
    const cuadros = document.getElementById('bienvenida-cuadros');
    if (cuadros) cuadros.classList.add('hidden');
    for (const sel of ['#clima-ciudad', '#clima-temp', '#clima-desc', '#reloj-fecha', '#reloj-hora']) {
      const e = document.querySelector(sel);
      if (e) e.textContent = '';
    }
    // Red de seguridad por si algun dia cambian los ids: se borra cualquier nodo que parezca
    // una linea de ubicacion. El patron NO nombra el barrio a proposito -- un archivo que dice
    // 'no publiques este lugar' termina publicando el lugar.
    document.querySelectorAll('#zona-central *').forEach((e) => {
      if (e.children.length === 0 && /,\s*(nublado|despejado|lluvia)|^[A-Z][a-z]+ [A-Z][a-z]+$/.test(e.textContent || '')) {
        e.textContent = '';
      }
    });
    document.documentElement.setAttribute('data-modo', 'science');
    const w = document.getElementById('header-wordmark');
    if (w) w.textContent = 'MENTIS SCIENCE';
  });
  await pagina.waitForTimeout(400);

  // --- la escena: se escribe el pedido, aparece la respuesta, y se abre el 3D ---
  const escribir = async (texto) => {
    await pagina.click('#message-input');
    for (const c of texto) {
      await pagina.keyboard.type(c);
      await pagina.waitForTimeout(22);   // ritmo de tipeo humano, apurado para que el GIF entre en ~5 s
    }
  };
  await escribir('Mostrame la molécula de agua');
  await pagina.waitForTimeout(250);

  // La respuesta se pinta a mano: grabar un turno real tardaria minutos y el GIF son 5 segundos.
  // Lo que se muestra es lo que Mentis contesta de verdad, con la misma fuente y el mismo formato.
  await pagina.evaluate(() => {
    const input = document.getElementById('message-input');
    const msgs = document.getElementById('messages');
    const zona = document.getElementById('zona-central');
    if (zona) zona.classList.add('con-mensajes');
    const bienvenida = document.getElementById('bienvenida');
    if (bienvenida) bienvenida.classList.add('hidden');
    // Se replica EXACTO como lo hace la app: la burbuja del usuario va adentro de un.message-row
    // (que alinea a la derecha) y la de Mentis va SUELTA en #messages (queda a la izquierda).
    // Envolver las dos en un row -- que fue el primer intento -- ponia las dos a la derecha y la
    // conversacion se leia como si el usuario hablara solo.
    const fila = (quien, texto) => {
      const b = document.createElement('div');
      b.className = 'bubble ' + quien;
      b.textContent = texto;
      if (quien === 'usuario') {
        const d = document.createElement('div');
        d.className = 'message-row usuario';
        d.appendChild(b);
        msgs.appendChild(d);
      } else {
        msgs.appendChild(b);
      }
    };
    fila('usuario', 'Mostrame la estructura de la molécula de agua');
    input.value = '';
    setTimeout(() => {
      fila('mentis', 'Listo: molécula de agua — 3 átomos, 2 uniones.\nFuente de la geometría: PubChem CID 962');
      msgs.scrollTop = msgs.scrollHeight;
    }, 450);
  });
  await pagina.waitForTimeout(1100);

  // El 3D: lo mismo que ve el usuario al tocar el chip del artefacto.
  await pagina.evaluate(() => window.MentisVisor.abrir('agua.mol3d.json'));
  await pagina.waitForTimeout(1500);
  // Un giro suave para que se note que es 3D de verdad y no una imagen.
  await pagina.mouse.move(560, 330);
  await pagina.mouse.down();
  for (let i = 0; i < 16; i++) {
    await pagina.mouse.move(560 + i * 11, 330 - i * 3);
    await pagina.waitForTimeout(28);
  }
  await pagina.mouse.up();
  await pagina.waitForTimeout(700);

  await pagina.close();
  await navegador.close();
  srv.close();

  const webm = fs.readdirSync(tmp).find((f) => f.endsWith('.webm'));
  if (!webm) { console.error('no se grabo el video'); process.exit(1); }
  const entrada = path.join(tmp, webm);
  const salida = path.join(DOCS, 'mentis-demo.gif');

  // Dos pasadas: primero se calcula una paleta propia del video y despues se arma el GIF con
  // ella. En una sola pasada, ffmpeg usa una paleta generica de 256 colores y el terracota de la
  // identidad sale sucio -- justo el color que tiene que verse bien.
  const paleta = path.join(tmp, 'paleta.png');
  const filtros = 'fps=12,scale=900:-1:flags=lanczos';
  execFileSync('ffmpeg', ['-y', '-i', entrada, '-vf', `${filtros},palettegen=stats_mode=diff`, paleta],
               { stdio: 'ignore' });
  execFileSync('ffmpeg', ['-y', '-i', entrada, '-i', paleta,
                          '-lavfi', `${filtros}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3`,
                          salida], { stdio: 'ignore' });

  const kb = Math.round(fs.statSync(salida).size / 1024);
  console.log(`GIF: ${salida}  (${kb} KB)`);
  if (kb > 6000) console.log('OJO: pesa mas de 6 MB; GitHub lo muestra igual pero tarda en cargar.');
  fs.rmSync(tmp, { recursive: true, force: true });
})();
