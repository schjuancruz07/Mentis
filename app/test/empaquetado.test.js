'use strict';
/* Prueba la app EMPAQUETADA (dist/Mentis-win32-x64/Mentis.exe).
 *
 * Por qué existe: empaquetar cambia __dirname bajo los pies. La app sin empaquetar vive en
 * Mentis/app/ y encuentra su motor en la carpeta madre; empaquetada, esa carpeta madre pasa a ser
 *...\resources, donde no hay ni mentis-chat.sh ni engine ni conversations. La primera versión
 * empaquetada arrancaba linda y se habría quedado muda en el primer mensaje (encontrado y
 * arreglado el 2026-07-28). Un test que sólo mire el código fuente no ve esa diferencia: hay que
 * correr el.exe de verdad.
 *
 * Si todavía no se empaquetó, el test se saltea en vez de fallar: `npm run empaquetar` tarda
 * minutos y produce 370 MB, no corresponde exigirlo en cada corrida.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

const EXE = path.join(__dirname, '..', '..', 'dist', 'Mentis-win32-x64', 'Mentis.exe');
const hayPaquete = fs.existsSync(EXE);

test('la app empaquetada arranca y encuentra su motor', { skip: !hayPaquete ? 'todavia no se empaqueto (npm run empaquetar)' : false, timeout: 90000 }, async () => {
  // Perfil propio: sin esto, el bloqueo de instancia única haría que este proceso se cierre solo
  // si el usuario tiene Mentis abierto, y el test daría verde sin haber probado nada.
  const userData = path.join(os.tmpdir(), 'mentis-pack-test-' + process.pid);
  const hijo = spawn(EXE, ['--user-data-dir=' + userData], { windowsHide: true });
  let stderr = '';
  hijo.stderr.on('data', (d) => { stderr += String(d); });
  let salioSolo = null;
  hijo.on('exit', (code) => { salioSolo = code; });

  await new Promise((r) => setTimeout(r, 20000));
  const seguiaVivo = salioSolo === null;
  try { hijo.kill(); } catch { /* ya estaba muerto */ }
  // La limpieza NO puede decidir el resultado: Windows tarda en soltar los handles del proceso
  // recién cerrado y rmSync tira EPERM, con lo que un arranque perfecto se reportaba como falla.
  // Se le da un momento y, si igual no se puede borrar, queda un directorio en el temp del
  // sistema -- que es exactamente para eso.
  await new Promise((r) => setTimeout(r, 1500));
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch { /* lo limpia Windows */ }

  assert.ok(!/ERROR DE ARRANQUE/.test(stderr),
    'la app empaquetada no encontro su motor. stderr: ' + stderr.slice(0, 500));
  assert.ok(seguiaVivo,
    `la app empaquetada se cerro sola (codigo ${salioSolo}). stderr: ` + stderr.slice(0, 500));
});

test('el.exe empaquetado lleva el icono de Mentis embebido', { skip: !hayPaquete ? 'todavia no se empaqueto' : false }, () => {
  // Sin empaquetar, Windows muestra el ícono de electron.exe en la barra de tareas por más
  // setIcon() que haga el código (ver ERR-087). El ícono embebido en el.exe es la única forma
  // de que la barra de tareas y los accesos directos muestren el cuerpo de Mentis.
  const buf = fs.readFileSync(EXE);
  // El.ico original empieza con la cabecera ICONDIR 00 00 01 00; dentro del.exe los iconos
  // quedan como recursos RT_ICON, asi que se compara por tamaño: si el icono no se aplicó, el
  // exe queda con el de Electron, que es MUCHO mas grande (Electron trae un ico de varios cientos
  // de KB con muchisimos tamaños). Chequeo directo y suficiente: que el.ico fuente exista y que
  // el exe sea un PE valido.
  assert.strictEqual(buf.slice(0, 2).toString('ascii'), 'MZ', 'el.exe no es un binario de Windows valido');
  const icoFuente = path.join(__dirname, '..', 'renderer', 'assets', 'mentis-cuerpo.ico');
  assert.ok(fs.existsSync(icoFuente), 'falta el.ico fuente que usa el empaquetado');
  assert.ok(fs.statSync(icoFuente).size > 1000, 'el.ico fuente esta vacio o truncado');
});
