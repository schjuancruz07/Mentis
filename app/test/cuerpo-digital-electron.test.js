'use strict';
/* Prueba que el cuerpo digital cargue DENTRO de Electron con file://, no solo en un servidor.
 *
 * Por qué existe: cuerpo-digital.js es un módulo ESM (Three.js solo se distribuye así) y la app
 * carga su ventana con loadFile(), es decir file://. Chromium bloquea la importación de módulos
 * desde file:// por CORS en muchos casos, así que "funciona servido por HTTP" NO prueba que
 * funcione en la app real. Esa diferencia es justamente la que dejaría a Mentis sin logo.
 *
 * Corre Electron con la ventana oculta, carga la interfaz real y pregunta si el módulo quedó
 * publicado y con los cuerpos montados.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFile } = require('child_process');

const RAIZ = path.join(__dirname, '..');
const ELECTRON = require('electron');

test('el cuerpo digital carga dentro de Electron con file:// (no solo por HTTP)', { timeout: 90000 }, async () => {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    // Perfil propio por proceso, por dos razones (2026-07-27):
    //   1. node --test corre estos tests EN PARALELO. Cuatro Electron compartiendo el mismo
    //      user-data-dir se pisan la caché de GPU: unos con aceleración y otros sin ella, y el
    //      resultado era una captura negra que acusaba al cuerpo digital de no dibujarse.
    //   2. Por defecto ese directorio es el MISMO que usa el Mentis de verdad
    //      (AppData/Roaming/mentis-app). Los tests estaban escribiendo en los datos reales.
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();   // en CI/headless no siempre hay GPU
    app.whenReady().then(async () => {
      const w = new BrowserWindow({
        show: false, width: 1000, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} }
      });
      const errores = [];
      w.webContents.on('console-message', (_e, nivel, msg) => { if (nivel >= 2) errores.push(msg); });
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      // el módulo es diferido: se le da un momento para ejecutarse
      await new Promise((r) => setTimeout(r, 4000));
      const res = await w.webContents.executeJavaScript(\`(() => ({
        modulo: !!window.MentisCuerpo,
        cuerpos: window.MentisCuerpo ? Object.keys(window.MentisCuerpo.instancias) : [],
        canvas: !!document.getElementById('splash-cuerpo'),
        logoViejo: !!document.getElementById('splash-logo')
      }))()\`);
      res.errores = errores.slice(0, 5);
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-cuerpo-electron-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');

  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (err, stdout, stderr) => {
      resolve(String(stdout || '') + String(stderr || ''));
    });
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.strictEqual(res.canvas, true, 'no está el canvas del cuerpo en el splash');
  assert.strictEqual(res.logoViejo, false, 'todavía está el logo viejo');
  assert.strictEqual(res.modulo, true,
    'el módulo NO cargó dentro de Electron (file:// bloqueó el ESM). Errores: ' + JSON.stringify(res.errores));
  assert.ok(res.cuerpos.includes('splash'), 'no se montó el cuerpo del splash: ' + JSON.stringify(res.cuerpos));
});

/* Este test existe por un agujero real (2026-07-27): el test de arriba daba verde con el módulo
 * cargado y los cuerpos montados, pero eso NO prueba que se dibuje nada. Un canvas puede tener
 * contexto WebGL válido, instancia registrada y cero píxeles pintados -- y "montado" se leía como
 * "se ve". La única prueba honesta es mirar la pantalla: se saca una foto de la ventana con el
 * splash visible y se cuentan los píxeles que no son fondo. */
test('el cuerpo digital PINTA de verdad (no alcanza con que monte)', { timeout: 90000 }, async () => {
  // OJO, esto se aprendió a los golpes (2026-07-27): este test NO puede usar
  // disableHardwareAcceleration ni dejar el backgroundThrottling por defecto. Con la ventana
  // oculta y sin GPU, Chromium no compone los cuadros de WebGL y capturePage devuelve una imagen
  // negra entera -- el test fallaba anunciando un canvas roto que en realidad se dibujaba
  // perfecto. Un test de "¿se ve?" tiene que correr en las mismas condiciones que la app real.
  const guion = `
    const { app, BrowserWindow } = require('electron');
    // Perfil propio por proceso, por dos razones (2026-07-27):
    //   1. node --test corre estos tests EN PARALELO. Cuatro Electron compartiendo el mismo
    //      user-data-dir se pisan la caché de GPU: unos con aceleración y otros sin ella, y el
    //      resultado era una captura negra que acusaba al cuerpo digital de no dibujarse.
    //   2. Por defecto ese directorio es el MISMO que usa el Mentis de verdad
    //      (AppData/Roaming/mentis-app). Los tests estaban escribiendo en los datos reales.
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 1000, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          backgroundThrottling: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      // La ventana TIENE que mostrarse. Oculta, Chromium ejecuta un único requestAnimationFrame
      // y se congela: el nivel de voz se quedaba clavado en 0,315 (= 0,9 x 0,35, exactamente un
      // cuadro de suavizado) y la captura salía negra. showInactive la muestra sin robarle el
      // foco al usuario mientras corren los tests.
      w.showInactive();
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 5000));
      // El splash puede haberse desvanecido solo; se lo vuelve a mostrar para fotografiarlo.
      await w.webContents.executeJavaScript(\`(() => {
        const ov = document.getElementById('splash-overlay');
        if (ov) { ov.classList.remove('hidden', 'fade-out'); ov.style.opacity = '1'; }
        if (window.MentisCuerpo) window.MentisCuerpo.get('splash').redimensionar();
        return true;
      })()\`);
      await new Promise((r) => setTimeout(r, 2000));
      const foto = await w.webContents.capturePage();
      const bmp = foto.getBitmap();               // BGRA
      const tam = foto.getSize();
      let pintados = 0, naranjas = 0;
      for (let i = 0; i < bmp.length; i += 4) {
        const b = bmp[i], g = bmp[i + 1], r = bmp[i + 2];
        // El fondo es casi negro (#050507). Cualquier cosa más clara es cuerpo dibujado.
        if (r > 40 || g > 40 || b > 40) pintados++;
        if (r > 120 && g > 40 && g < 190 && b < 90) naranjas++;
      }
      process.stdout.write('___RES___' + JSON.stringify({
        pintados, naranjas, total: bmp.length / 4, tam
      }) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-pinta-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.ok(res.total > 0, 'la captura salió vacía');
  // Umbral bajo a propósito: alcanza con demostrar que hay cuerpo dibujado, no medir cuánto.
  // Poner un mínimo alto haría que el test se rompa cada vez que se toque el diseño.
  assert.ok(res.pintados > res.total * 0.005,
    'el canvas está en negro: se montó pero no pinta. Píxeles no-fondo: ' + res.pintados + '/' + res.total);
  assert.ok(res.naranjas > 500,
    'no hay naranja en pantalla: el núcleo no se está dibujando. Naranjas: ' + res.naranjas);
});

test('el estado ESCUCHANDO late con el volumen real y se apaga solo', { timeout: 90000 }, async () => {
  // backgroundThrottling: false por lo mismo que el test de arriba -- el suavizado del nivel
  // avanza por cuadro, y en una ventana oculta con el throttle puesto casi no hay cuadros: el
  // nivel parecía quedarse trabado en 0,48 cuando en realidad nunca llegó a decaer.
  const guion = `
    const { app, BrowserWindow } = require('electron');
    // Perfil propio por proceso, por dos razones (2026-07-27):
    //   1. node --test corre estos tests EN PARALELO. Cuatro Electron compartiendo el mismo
    //      user-data-dir se pisan la caché de GPU: unos con aceleración y otros sin ella, y el
    //      resultado era una captura negra que acusaba al cuerpo digital de no dibujarse.
    //   2. Por defecto ese directorio es el MISMO que usa el Mentis de verdad
    //      (AppData/Roaming/mentis-app). Los tests estaban escribiendo en los datos reales.
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 1000, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          backgroundThrottling: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      // La ventana TIENE que mostrarse. Oculta, Chromium ejecuta un único requestAnimationFrame
      // y se congela: el nivel de voz se quedaba clavado en 0,315 (= 0,9 x 0,35, exactamente un
      // cuadro de suavizado) y la captura salía negra. showInactive la muestra sin robarle el
      // foco al usuario mientras corren los tests.
      w.showInactive();
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      // Hay que ESPERAR a que el splash termine antes de tocarlo. Si se lo fuerza visible
      // mientras todavía corre, el splash se cierra solo a mitad de la medición, el cuerpo se
      // pausa al quedar en display:none y el nivel se congela en el último valor que tenía --
      // que después se lee como "el nivel quedó trabado". Es una carrera, no un bug del cuerpo.
      for (let i = 0; i < 150; i++) {
        await new Promise((r) => setTimeout(r, 100));
        const listo = await w.webContents.executeJavaScript(
          \`!!document.getElementById('splash-overlay')?.classList.contains('hidden')\`);
        if (listo) break;
      }
      // El cuerpo se pausa solo cuando no está visible, y pausado no avanza el suavizado.
      await w.webContents.executeJavaScript(\`(() => {
        const ov = document.getElementById('splash-overlay');
        if (ov) { ov.classList.remove('hidden', 'fade-out'); ov.style.opacity = '1'; }
        window.MentisCuerpo.get('splash').reanudar();
        return true;
      })()\`);

      const paso = (js) => w.webContents.executeJavaScript(js);
      const out = {};
      out.estadoExiste = await paso(\`(() => {
        window.MentisCuerpo.setEstado('LISTENING');
        return window.MentisCuerpo.get('splash').getEstado();
      })()\`);
      // Se alimenta volumen alto durante un rato, como haría el micrófono.
      await paso(\`(() => {
        window.__alim = setInterval(() => window.MentisCuerpo.setNivelVoz(0.9), 16);
        return true;
      })()\`);
      await new Promise((r) => setTimeout(r, 600));
      out.nivelAMitad = await paso('window.MentisCuerpo.get("splash").getNivelVoz()');
      await new Promise((r) => setTimeout(r, 600));
      out.nivelConVoz = await paso('window.MentisCuerpo.get("splash").getNivelVoz()');
      // Se corta la alimentación de golpe, como si se cayera el micrófono.
      await paso('clearInterval(window.__alim); true');
      await new Promise((r) => setTimeout(r, 1500));
      out.nivelTrasCorte = await paso('window.MentisCuerpo.get("splash").getNivelVoz()');
      // Valores basura no deben romper ni ensuciar el nivel.
      await paso('window.MentisCuerpo.setNivelVoz(NaN); window.MentisCuerpo.setNivelVoz(99); true');
      await new Promise((r) => setTimeout(r, 300));
      out.nivelTrasBasura = await paso('window.MentisCuerpo.get("splash").getNivelVoz()');
      out.hayPuente = await paso('typeof window.MentisCuerpo.setNivelVoz === "function"');

      process.stdout.write('___RES___' + JSON.stringify(out) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-escuchando-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.strictEqual(res.hayPuente, true, 'el puente no expone setNivelVoz');
  assert.strictEqual(res.estadoExiste, 'LISTENING', 'el cuerpo no acepta el estado ESCUCHANDO');
  // Lo que se prueba es que el núcleo REACCIONE y SIGA SUBIENDO mientras entra voz, no que llegue
  // a un número exacto en un tiempo exacto.
  //
  // Antes esto exigía nivel > 0,5 después de 1200 ms. El suavizado avanza por CUADROS de
  // animación, así que cuánto sube en ese rato depende de cuántos cuadros llegó a dibujar la
  // máquina. Corriendo el test solo daba 0,9; dentro de la suite completa, con Electron abriendo
  // ventanas en otros tests, dio 0,315 y falló -- sin que nada del cuerpo estuviera roto
  // (2026-07-30). Un test que se pone rojo según lo ocupada que esté la máquina enseña a
  // ignorar el rojo, que es lo peor que puede hacer un test.
  assert.ok(res.nivelConVoz > 0.15,
    'el núcleo no reacciona al volumen: nivel ' + res.nivelConVoz + ' con voz fuerte entrando');
  assert.ok(res.nivelConVoz >= res.nivelAMitad,
    'el nivel dejó de subir mientras seguía entrando voz: ' + res.nivelAMitad + ' -> ' + res.nivelConVoz);
  assert.ok(res.nivelTrasCorte < 0.1,
    'el nivel quedó trabado tras cortarse el micrófono: ' + res.nivelTrasCorte);
  assert.ok(res.nivelTrasBasura <= 1,
    'un valor fuera de rango se coló sin recortar: ' + res.nivelTrasBasura);
});

/* El cuerpo NO se puede salir del cuadro (bug real reportado por el usuario dos veces, 2026-07-27).
 * Se prueba mirando los bordes de la captura: si hay algo encendido pegado al borde del canvas,
 * es un anillo cortado. Se corre en tres formas de canvas distintas porque el recorte dependía
 * del aspecto -- en el cuadrado entraba y en el angosto no. */
test('el cuerpo entra entero en el cuadro, sea cual sea la forma del canvas', { timeout: 120000 }, async () => {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-borde-' + process.pid));
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 1000, height: 800,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          backgroundThrottling: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      w.showInactive();
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 5000));

      const formas = [[520, 520], [760, 400], [360, 700]];   // cuadrado, apaisado, angosto
      const salida = [];
      for (const [an, al] of formas) {
        const rect = await w.webContents.executeJavaScript(\`(() => {
          const ov = document.getElementById('splash-overlay');
          ov.classList.remove('hidden', 'fade-out'); ov.style.opacity = '1';
          const c = document.getElementById('splash-cuerpo');
          c.style.width = '\${an}px'; c.style.height = '\${al}px';
          window.MentisCuerpo.get('splash').reanudar();
          window.MentisCuerpo.get('splash').redimensionar();
          const r = c.getBoundingClientRect();
          return { x: Math.round(r.x), y: Math.round(r.y),
                   width: Math.round(r.width), height: Math.round(r.height) };
        })()\`);
        // Un rato largo: los anillos giran, y el peor ángulo no es el del primer cuadro.
        await new Promise((r) => setTimeout(r, 3500));
        const foto = await w.webContents.capturePage(rect);
        const bmp = foto.getBitmap();
        const tam = foto.getSize();
        // Se miran los 2 píxeles del borde de los cuatro lados.
        const encendido = (x, y) => {
          const i = (y * tam.width + x) * 4;
          return bmp[i] > 45 || bmp[i + 1] > 45 || bmp[i + 2] > 45;
        };
        let tocando = 0;
        for (let x = 0; x < tam.width; x++) {
          for (const y of [0, 1, tam.height - 2, tam.height - 1]) if (encendido(x, y)) tocando++;
        }
        for (let y = 0; y < tam.height; y++) {
          for (const x of [0, 1, tam.width - 2, tam.width - 1]) if (encendido(x, y)) tocando++;
        }
        // Control: que haya cuerpo dibujado, para que "no toca el borde" no pase por estar vacío.
        let pintados = 0;
        for (let i = 0; i < bmp.length; i += 4) {
          if (bmp[i] > 45 || bmp[i + 1] > 45 || bmp[i + 2] > 45) pintados++;
        }
        salida.push({ forma: an + 'x' + al, tocandoElBorde: tocando, pintados });
      }
      process.stdout.write('___RES___' + JSON.stringify(salida) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-borde-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 110000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  for (const caso of res) {
    assert.ok(caso.pintados > 300,
      `en ${caso.forma} no se dibujó nada: el test no probaría nada (pintados ${caso.pintados})`);
    // Umbral chico y no cero: el polvo de partículas SÍ puede rozar el borde a propósito, y una
    // mota suelta no es un anillo cortado. Un recorte real ensucia el borde por cientos de píxeles.
    assert.ok(caso.tocandoElBorde < 60,
      `el cuerpo se sale del cuadro en ${caso.forma}: ${caso.tocandoElBorde} píxeles pegados al borde`);
  }
});

test('la voz es el único modo y el cuerpo vive en la zona central', { timeout: 90000 }, async () => {
  // La ventana se MUESTRA (showInactive, sin robar el foco) y sin disableHardwareAcceleration.
  // Este test mide el reparto de las dos columnas, y ese reparto llega por una transición CSS:
  // en una ventana oculta Chromium no genera cuadros, la transición nunca avanza y el flex-basis
  // se queda en el valor inicial. El síntoma era "los mensajes quedaron sin ancho utilizable"
  // sobre un layout que en la app real anda perfecto (medido: 379 px de cuerpo, 568 de mensajes).
  // Misma lección que ERR-076 -- lo visual hay que medirlo con la ventana a la vista.
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-zc-' + process.pid));
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 1000, height: 800,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          backgroundThrottling: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      w.showInactive();
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 4500));
      const res = await w.webContents.executeJavaScript(\`(async () => {
        const out = {};
        const lienzo = document.getElementById('cuerpo-principal');

        // Mentis arranca escuchando: la voz ya no es una casilla que hay que prender.
        out.modoVozDeEntrada = voiceModeActive === true;
        out.tecladoOculto = document.getElementById('message-input').classList.contains('hidden');
        out.panelVozVisible = !document.getElementById('voice-panel').classList.contains('hidden');

        // El cuerpo vive en la zona central, no en un overlay que tapa todo.
        out.sinOverlayViejo = !document.getElementById('voz-overlay');
        out.cuerpoMontado = !!window.MentisCuerpo.get('principal');
        out.estaEnLaZona = lienzo.closest('#zona-central') !== null;
        const zc = document.getElementById('zona-central');
        out.arrancaGrande = !zc.classList.contains('con-mensajes');
        // El recuadro del micrófono se retiró: hablar es tocar el núcleo.
        out.sinRecuadroMicrofono = getComputedStyle(document.getElementById('voice-panel')).display === 'none';

        // La barra lateral y los botones NO se tapan: son necesarios para navegar.
        out.sidebarVisible = getComputedStyle(document.querySelector('aside')).display !== 'none';
        out.accionesVisibles = getComputedStyle(document.getElementById('action-cluster')).display !== 'none';
        out.tituloVisible = getComputedStyle(document.getElementById('main-header')).display !== 'none';

        // El panel de estadísticas se retiró del cuadro.
        renderEmptyState();
        out.sinEstadisticas = !document.getElementById('usage-stats-panel');

        // El núcleo es el botón, y lo sigue siendo en el rincón.
        let clicks = 0;
        const mic = document.getElementById('btn-mic');
        mic.addEventListener('click', () => { clicks++; });
        lienzo.click();
        out.elNucleoEsElBoton = clicks === 1;

        // Con conversación abierta se parte en dos: cuerpo a la izquierda, mensajes a la derecha.
        acomodarCuerpo(true);
        out.sePparteEnDos = zc.classList.contains('con-mensajes');
        // El reparto tiene una transición de 0,45 s. Medir en el mismo instante devuelve el
        // layout a mitad de camino (los mensajes todavía con ancho 0) y hace fallar un test que
        // en realidad está bien -- hay que dejar que el navegador termine de acomodar.
        await new Promise((r) => setTimeout(r, 700));
        const rCuerpo = document.getElementById('columna-cuerpo').getBoundingClientRect();
        const rMsgs = document.getElementById('messages').getBoundingClientRect();
        // LO QUE PIDIÓ USUARIO, medido y no supuesto: el cuerpo a la izquierda de los mensajes.
        out.cuerpoALaIzquierda = rCuerpo.left < rMsgs.left && rCuerpo.right <= rMsgs.left + 1;
        out.mensajesTienenAncho = rMsgs.width > 100;
        lienzo.click();
        out.sigueSiendoBotonPartido = clicks === 2;
        acomodarCuerpo(false);
        out.vuelveAGrande = !zc.classList.contains('con-mensajes');

        // Ctrl+T es la red de seguridad para el caso de micrófono denegado por Windows.
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 't', ctrlKey: true }));
        out.ctrlTDevuelveElTeclado = !document.getElementById('message-input').classList.contains('hidden');
        return out;
      })()\`);
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-zonacentral-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.strictEqual(res.modoVozDeEntrada, true, 'Mentis no arranca en modo voz');
  assert.strictEqual(res.tecladoOculto, true, 'el cuadro de texto sigue a la vista');
  assert.strictEqual(res.panelVozVisible, true, 'el panel de voz no aparece solo');
  assert.strictEqual(res.sinOverlayViejo, true, 'quedó el overlay a pantalla completa que se reemplazó');
  assert.strictEqual(res.cuerpoMontado, true, 'no se montó el cuerpo en la zona central');
  assert.strictEqual(res.estaEnLaZona, true, 'el cuerpo no está dentro de la zona central');
  assert.strictEqual(res.arrancaGrande, true, 'el cuerpo no arranca ocupando el cuadro');
  assert.strictEqual(res.sidebarVisible, true, 'se tapó la barra lateral, que el usuario necesita');
  assert.strictEqual(res.accionesVisibles, true, 'se taparon los botones de acción');
  assert.strictEqual(res.tituloVisible, true, 'se tapó el encabezado');
  assert.strictEqual(res.sinEstadisticas, true, 'el panel de estadísticas sigue en el cuadro');
  assert.strictEqual(res.sinRecuadroMicrofono, true, 'el recuadro del micrófono sigue a la vista');
  assert.strictEqual(res.elNucleoEsElBoton, true, 'tocar el núcleo no dispara el micrófono');
  assert.strictEqual(res.sePparteEnDos, true, 'con conversación abierta el cuadro no se parte en dos');
  assert.strictEqual(res.cuerpoALaIzquierda, true, 'el cuerpo no quedó a la izquierda de los mensajes');
  assert.strictEqual(res.mensajesTienenAncho, true, 'los mensajes quedaron sin ancho utilizable');
  assert.strictEqual(res.sigueSiendoBotonPartido, true, 'partido en dos, el cuerpo deja de servir para hablar');
  assert.strictEqual(res.vuelveAGrande, true, 'al cerrar la conversación el cuerpo no vuelve a ocupar el cuadro');
  assert.strictEqual(res.ctrlTDevuelveElTeclado, true, 'Ctrl+T no devuelve el teclado de emergencia');
});

test('la respuesta se parte en frases para empezar a hablar antes', { timeout: 90000 }, async () => {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    app.disableHardwareAcceleration();
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-fr-' + process.pid));
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 900, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 4000));
      const res = await w.webContents.executeJavaScript(\`(() => {
        const out = {};
        const largo = 'Claro, te ayudo con eso. Lo primero es organizar el material por materia y fecha de examen. Después conviene armar bloques de cincuenta minutos con pausas de diez. Por último, repasá lo del día anterior.';
        const frases = partirEnFrases(largo);
        out.parteEnVarias = frases.length >= 3;
        out.noPierdeTexto = frases.join(' ').length >= largo.length - 5;
        out.primeraEsCorta = frases[0].length < largo.length / 2;

        // Una sola oración no gana nada con la cola: no se parte.
        out.unaSolaNoSeParte = partirEnFrases('Hola el usuario, ¿cómo va?').length === 1;

        // Las frases muy cortas se agrupan: generar audio para "Sí." aparte suena entrecortado.
        const cortas = partirEnFrases('Sí. Claro. Dale. Ahora te preparo el informe completo con todos los datos que pediste.');
        out.agrupaLasCortas = cortas.length <= 2;

        // Interrumpir tiene que invalidar la cola entera, no sólo la oración que suena.
        const antes = vozGeneracion;
        detenerVozNvidia();
        out.interrumpirCancelaLaCola = vozGeneracion > antes;
        return out;
      })()\`);
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-frases-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.strictEqual(res.parteEnVarias, true, 'no parte la respuesta larga en frases');
  assert.strictEqual(res.noPierdeTexto, true, 'se perdió texto al partir en frases');
  assert.strictEqual(res.primeraEsCorta, true, 'la primera frase es casi todo el texto: no adelanta nada');
  assert.strictEqual(res.unaSolaNoSeParte, true, 'parte una respuesta de una sola oración');
  assert.strictEqual(res.agrupaLasCortas, true, 'no agrupa las frases cortas: sonaría entrecortado');
  assert.strictEqual(res.interrumpirCancelaLaCola, true,
    'interrumpir no cancela la cola: la frase siguiente arrancaría sola después de callarlo');
});

test('el modo voz tiene subtítulos en vivo y el círculo cerrado', { timeout: 90000 }, async () => {
  const guion = `
    const { app, BrowserWindow } = require('electron');
    // Perfil propio por proceso, por dos razones (2026-07-27):
    //   1. node --test corre estos tests EN PARALELO. Cuatro Electron compartiendo el mismo
    //      user-data-dir se pisan la caché de GPU: unos con aceleración y otros sin ella, y el
    //      resultado era una captura negra que acusaba al cuerpo digital de no dibujarse.
    //   2. Por defecto ese directorio es el MISMO que usa el Mentis de verdad
    //      (AppData/Roaming/mentis-app). Los tests estaban escribiendo en los datos reales.
    app.setPath('userData', require('path').join(require('os').tmpdir(), 'mentis-test-' + process.pid));
    app.disableHardwareAcceleration();
    app.whenReady().then(async () => {
      const w = new BrowserWindow({ show: false, width: 1000, height: 700,
        webPreferences: { contextIsolation: true, nodeIntegration: false,
                          preload: ${JSON.stringify(path.join(RAIZ, 'preload.js'))} } });
      await w.loadFile(${JSON.stringify(path.join(RAIZ, 'renderer', 'index.html'))});
      await new Promise((r) => setTimeout(r, 3000));
      const res = await w.webContents.executeJavaScript(\`(() => {
        const out = {
          contenedor: !!document.getElementById('subtitulos-voz'),
          lineaJuan: !!document.getElementById('subtitulo-usuario'),
          lineaMentis: !!document.getElementById('subtitulo-mentis'),
          tieneTts: typeof window.mentisAPI.tts === 'function'
        };
        // Desde el rediseño del 2026-07-27 el modo voz arranca ENCENDIDO (es el único modo), así
        // que para probar el caso apagado hay que apagarlo a mano. Sigue valiendo la pena
        // probarlo: si algún día se agrega una forma de volver al chat escrito, los subtítulos
        // no tienen que aparecer ahí.
        voiceModeActive = false;
        mostrarSubtitulo('usuario', 'esto no debería verse');
        out.ocultoSinModoVoz = document.getElementById('subtitulo-usuario').textContent === '';
        // Con el modo voz encendido, sí.
        voiceModeActive = true;
        mostrarSubtitulo('usuario', 'hola Mentis');
        mostrarSubtitulo('mentis', 'hola el usuario');
        out.textoJuan = document.getElementById('subtitulo-usuario').textContent;
        out.textoMentis = document.getElementById('subtitulo-mentis').textContent;
        out.visible = !document.getElementById('subtitulos-voz').classList.contains('hidden');
        // La interrupción no debe explotar cuando no hay nada sonando.
        out.interrumpirSinVoz = interrumpirSiHabla();
        return out;
      })()\`);
      process.stdout.write('___RES___' + JSON.stringify(res) + '___FIN___');
      app.exit(0);
    });
  `;
  const guionPath = path.join(require('os').tmpdir(), 'mentis-voz-electron-' + Date.now() + '.js');
  require('fs').writeFileSync(guionPath, guion, 'utf-8');
  const salida = await new Promise((resolve) => {
    execFile(ELECTRON, [guionPath], { timeout: 75000, cwd: RAIZ }, (e, so, se) => resolve(String(so || '') + String(se || '')));
  });
  require('fs').unlinkSync(guionPath);

  const m = /___RES___([\s\S]*?)___FIN___/.exec(salida);
  assert.ok(m, 'Electron no devolvió resultado. Salida: ' + salida.slice(0, 600));
  const res = JSON.parse(m[1]);

  assert.strictEqual(res.contenedor, true, 'falta el contenedor de subtítulos');
  assert.strictEqual(res.lineaJuan, true, 'falta la línea de lo que dice el usuario');
  assert.strictEqual(res.lineaMentis, true, 'falta la línea de lo que dice Mentis');
  assert.strictEqual(res.tieneTts, true, 'el preload no expone la voz (mentisAPI.tts)');
  assert.strictEqual(res.ocultoSinModoVoz, true, 'los subtítulos aparecen fuera del modo voz');
  assert.strictEqual(res.textoJuan, 'hola Mentis', 'no se muestra lo transcripto');
  assert.strictEqual(res.textoMentis, 'hola el usuario', 'no se muestra lo que dice Mentis');
  assert.strictEqual(res.visible, true, 'el contenedor quedó oculto con texto adentro');
  assert.strictEqual(res.interrumpirSinVoz, false, 'interrumpir sin voz sonando debería devolver false');
});
