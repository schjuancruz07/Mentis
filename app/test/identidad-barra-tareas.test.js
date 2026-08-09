'use strict';
/* La identidad de Mentis en la barra de tareas (ícono + nombre) no la puede pisar un test.
 *
 * BUG REAL, dos veces (2026-07-28 y 2026-07-31): el botón de la barra mostraba el átomo de Electron
 * y el nombre "Electron" aunque el.exe empaquetado tuviera su ícono correcto. Windows cachea ícono
 * y nombre por AppUserModelID, no por ejecutable. La segunda vez la causa fui yo: el test que prueba
 * el arranque hace require() de main.js desde electron.exe, y así registraba a Electron bajo el
 * identificador de la app del usuario. Cuatro corridas de la suite alcanzaron para romperlo.
 *
 * Por eso este test no mira "que el id sea el correcto" sino algo más fuerte: que la app empaquetada
 * y lo que corre sin empaquetar NO puedan compartir identidad. Mientras eso se cumpla, correr los
 * tests las veces que haga falta no le toca la barra de tareas a nadie.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const MAIN = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf-8');

test('el identificador de la barra de tareas depende de si la app está empaquetada', () => {
  const i = MAIN.indexOf('setAppUserModelId');
  assert.ok(i >= 0, 'main.js ya no llama a setAppUserModelId: sin eso Windows agrupa la ventana bajo Electron');
  const bloque = MAIN.slice(i, i + 260);

  assert.match(bloque, /app\.isPackaged/,
    'el identificador NO distingue empaquetado de desarrollo: cualquier corrida de los tests le ' +
    'vuelve a pisar el ícono a la app del usuario (pasó el 2026-07-31)');

  const ids = [...bloque.matchAll(/'(com\.[a-z0-9.]+)'/gi)].map((m) => m[1]);
  assert.ok(ids.length >= 2, 'se esperaban dos identificadores (empaquetado y desarrollo), hay: ' + ids.join(', '));
  assert.notStrictEqual(ids[0], ids[1], 'los dos identificadores son iguales: no sirve de nada separarlos');
});

test('el ícono que se empaqueta existe de verdad', () => {
  // Si el.ico no está, electron-packager no falla: deja el ícono por defecto de Electron y te
  // enterás mirando la barra de tareas una semana después.
  //
  // Se busca el --icon en TODOS los lugares desde donde se puede empaquetar, no en uno solo: los
  // flags se mudaron de package.json a empaquetar.js (2026-08-01, el chequeo previo de ERR-106) y
  // un test que mirara una sola ruta se habría puesto rojo por un cambio que no rompía nada -- o,
  // peor, se habría puesto verde para siempre si el flag se mudaba al lado que no mira.
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf-8'));
  const fuentes = Object.values(pkg.scripts || {});
  const envoltorio = path.join(__dirname, '..', 'empaquetar.js');
  if (fs.existsSync(envoltorio)) fuentes.push(fs.readFileSync(envoltorio, 'utf-8'));

  let m = null;
  for (const fuente of fuentes) {
    m = /--icon=(\S+?)['"\s,]/.exec(fuente + ' ') || /--icon=(\S+)/.exec(fuente);
    if (m) break;
  }
  assert.ok(m, 'ningún camino de empaquetado pasa --icon (ni package.json ni empaquetar.js)');
  const ruta = path.join(__dirname, '..', m[1]);
  assert.ok(fs.existsSync(ruta), 'el ícono que se le pasa al empaquetador no existe: ' + ruta);
  assert.ok(fs.statSync(ruta).size > 10000, 'el.ico es sospechosamente chico: ' + ruta);
});

test('la ventana pide su propio ícono', () => {
  assert.match(MAIN, /icon:\s*path\.join\([^)]*mentis-cuerpo\.ico'\)/,
    'la ventana no declara ícono propio: en Windows quedaría con el de Electron');
});
