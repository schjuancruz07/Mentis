// Que la APP arme bien las lineas del motor, incluso cuando un chunk de stderr corta una linea
// al medio.
//
// POR QUE EXISTE (2026-08-18): _emitLines partia el texto por '\n' y emitia lo que hubiera, sin
// guardar el resto. Con un chunk partido, "NVANSWER hola mundo" salia como dos eventos: el
// primero perdia su cola y el segundo ya no matcheaba el marcador de main.js, asi que se iba al
// panel de progreso como ruido. Los tests de entonces verificaban el cableado con grep sobre el
// fuente y no podian ver esto.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { MentisProcess } = require(path.join(__dirname, '..', 'app', 'lib', 'mentis-process.js'));

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mentis-stream-'));
const emisor = path.join(dir, 'emisor.sh');
const COLA = '-COLA-QUE-SE-PERDIA';
fs.writeFileSync(emisor, [
  '#!/usr/bin/env bash',
  '# lineas completas',
  'for i in 1 2 3; do printf "NVANSWER trozo-%s\n" "$i" >&2; sleep 0.05; done',
  '# una linea larga partida en dos escrituras -> dos chunks de stderr',
  'printf "NVANSWER %s" "$(printf "X%.0s" $(seq 1 200))" >&2',
  'sleep 0.05',
  'printf "%s\n" "' + COLA + '" >&2',
  '# una ultima linea SIN salto final: tiene que salir igual al cerrar',
  'printf "NVANSWER sin-salto-final" >&2',
].join('\n'), { mode: 0o755 });

const p = new MentisProcess({ bashPath: 'bash', scriptPath: emisor, args: [] });
const vistos = [];
p.on('log', (l) => vistos.push(l));
p.on('exit', () => {
  const fallos = [];
  const marker = /^NVANSWER (.*)$/;

  const noReconocidas = vistos.filter((l) => !marker.exec(l));
  if (noReconocidas.length > 0) {
    fallos.push('cayeron al panel de progreso como ruido: ' + JSON.stringify(noReconocidas));
  }
  const larga = vistos.find((l) => l.indexOf('XXX') !== -1);
  if (!larga) fallos.push('se perdio la linea larga');
  else if (larga.indexOf(COLA) === -1) fallos.push('la linea partida perdio su cola: len=' + larga.length);
  if (!vistos.some((l) => l.indexOf('sin-salto-final') !== -1)) {
    fallos.push('se perdio la ultima linea, la que no trae salto final');
  }

  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* nada */ }
  if (fallos.length > 0) { fallos.forEach((f) => console.log('MAL ' + f)); process.exit(1); }
  console.log('casos: 4');
  process.exit(0);
});
p.start();
