const { app, BrowserWindow } = require('electron');
const path = require('path');
const fs = require('fs');
app.setPath('userData', path.join(require('os').tmpdir(), 'mentis-diag-' + process.pid));
app.whenReady().then(async () => {
  const w = new BrowserWindow({
    show: true, width: 1000, height: 720, frame: false, backgroundColor: '#0a0a0b',
    webPreferences: { contextIsolation: true, nodeIntegration: false,
                      preload: path.join(__dirname, 'preload.js') }
  });
  w.showInactive();
  await w.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  await new Promise((r) => setTimeout(r, 4000));
  const info = await w.webContents.executeJavaScript(`(() => {
    const b = document.getElementById('btn-win-close');
    const r = b.getBoundingClientRect();
    const svg = b.querySelector('svg');
    const rs = svg ? svg.getBoundingClientRect() : null;
    return { botonX: r.x, botonY: r.y, ancho: r.width, alto: r.height,
             svgAncho: rs ? rs.width : null, svgAlto: rs ? rs.height : null,
             colorBoton: getComputedStyle(b).color, anchoVentana: window.innerWidth };
  })()`);
  const img = await w.webContents.capturePage();
  fs.writeFileSync(path.join('C:/Users/<usuario>\Mentis\dist', 'diag-barra.png'), img.toPNG());
  process.stdout.write('___RES___' + JSON.stringify(info) + '___FIN___');
  app.exit(0);
});
