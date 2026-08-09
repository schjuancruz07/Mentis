'use strict';
/* Contrato entre el motor (bash) y la app (Electron) para la aprobación por acción.
 *
 * Son dos programas distintos, en dos lenguajes distintos, hablando por una línea de texto en
 * stderr. Cada uno tiene su test y los dos pueden estar verdes mientras la línea que uno escribe
 * y la que el otro espera no coinciden -- y entonces Mentis pide permiso al vacío y se queda 120
 * segundos esperando una respuesta que nadie va a dar.
 *
 * Este test genera la línea con el bash REAL y la parsea con la expresión regular REAL de main.js,
 * las dos leídas de los archivos de producción. Si alguien cambia una punta, esto se pone rojo.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');

const RAIZ_MENTIS = path.join(__dirname, '..', '..');
const MAIN_JS = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf-8');
const AGENTE = path.join(RAIZ_MENTIS, 'engine', 'nv-agent.sh');

function regexDeMain() {
  // Se toma la regex tal como está escrita en main.js, no una copia a mano: una copia se
  // desincroniza y este test dejaría de probar lo único que vino a probar.
  // Se arma con new RegExp separando cuerpo y flags -- nada de eval, ni siquiera sobre código
  // propio: leer un archivo y ejecutarlo son dos cosas distintas y sólo hace falta la primera.
  const m = /const APROBACION_MARKER = \/(.*)\/([a-z]*);/.exec(MAIN_JS);
  assert.ok(m, 'no encontré APROBACION_MARKER en main.js');
  return new RegExp(m[1], m[2]);
}

function lineaQueEmiteElMotor(accion, detalle) {
  const fuente = fs.readFileSync(AGENTE, 'utf-8');
  const fn = /^_pedir_aprobacion\(\)[\s\S]*?\n}/m.exec(fuente);
  assert.ok(fn, 'no encontré _pedir_aprobacion en nv-agent.sh');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aprob-contrato-'));
  const guion = `
set -uo pipefail
${fn[0]}
_pedir_aprobacion ${JSON.stringify(accion)} ${JSON.stringify(detalle)}
`;
  const guionPath = path.join(dir, 'g.sh');
  fs.writeFileSync(guionPath, guion, 'utf-8');
  let salida = '';
  try {
    execFileSync('bash', [guionPath], {
      env: {...process.env, MENTIS_APROBACION_DIR: dir, NV_APROB_TIMEOUT: '1' },
      encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000
    });
  } catch (e) {
    salida = String((e && e.stderr) || '');   // devuelve 1 (nadie aprueba); lo que importa es stderr
  }
  fs.rmSync(dir, { recursive: true, force: true });
  return salida.split('\n').find((l) => l.includes('APROBACION')) || '';
}

test('la app entiende el pedido de permiso que escribe el motor', { timeout: 60000 }, () => {
  const linea = lineaQueEmiteElMotor('borrar una carpeta entera', 'rm -rf /tmp/algo');
  assert.ok(linea, 'el motor no emitió ninguna línea de APROBACION');
  const m = regexDeMain().exec(linea.trim());
  assert.ok(m, `la app NO reconoce la línea del motor.\nlínea: ${linea}`);
  assert.ok(/^ap-/.test(m[1]), 'el id del pedido no salió bien parseado: ' + m[1]);
  assert.strictEqual(m[2], 'borrar una carpeta entera', 'la acción no llegó legible a la app');
  assert.ok(m[3].includes('rm -rf /tmp/algo'), 'el comando concreto no llegó a la app: ' + m[3]);
});

test('un comando con saltos de línea no rompe el canal (que es línea por línea)', { timeout: 60000 }, () => {
  // Un comando de varias líneas es lo normal cuando Mentis arma un script. Si eso partiera la
  // línea de stderr, la app leería un pedido cortado y el motor esperaría al vacío.
  const linea = lineaQueEmiteElMotor('ejecutar un script', 'cd /tmp\nrm -rf basura\necho listo');
  const m = regexDeMain().exec(linea.trim());
  assert.ok(m, `la app NO reconoce el pedido de un comando multilínea.\nlínea: ${linea}`);
  assert.ok(!m[3].includes('\n'), 'el detalle llegó con saltos de línea y parte el canal');
  assert.ok(m[3].includes('rm -rf basura'), 'se perdió el comando en el aplanado: ' + m[3]);
});

test('el default del diálogo es NO', () => {
  // Cerrar la ventana con Escape, o darle enter sin leer, tiene que significar "no". Es la
  // diferencia entre pedir permiso y avisar.
  const bloque = /function atenderPedidoDeAprobacion[\s\S]*?\n}/.exec(MAIN_JS);
  assert.ok(bloque, 'no encontré atenderPedidoDeAprobacion en main.js');
  assert.match(bloque[0], /defaultId:\s*0/, 'el botón por defecto debería ser el de cancelar');
  assert.match(bloque[0], /cancelId:\s*0/, 'cerrar el diálogo debería contar como "no"');
  assert.match(bloque[0], /catch\(\)\s*=>\s*respuesta\('no'\)|catch\(\(\)\s*=>\s*respuesta\('no'\)\)/,
    'si el diálogo falla, la respuesta tiene que ser "no"');
});
