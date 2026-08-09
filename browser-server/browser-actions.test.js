'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const actions = require('./browser-actions');

test('openUrl navega y devuelve texto+elementos', async () => {
  const url = 'data:text/html,' + encodeURIComponent(
    '<html><body><p>Pagina inicial</p><a href="#">Click aqui</a></body></html>'
  );
  const result = await actions.openUrl(url);
  assert.ok(result.text.includes('Pagina inicial'));
  assert.strictEqual(result.elements.length, 1);
  assert.strictEqual(result.elements[0].label, 'Click aqui');
  assert.strictEqual(result.elements[0].n, 1);
  assert.strictEqual(result.handles, undefined, 'openUrl no expone los ElementHandle crudos al llamador');
});

test('fillElement completa un input sin navegar', async () => {
  const url = 'data:text/html,' + encodeURIComponent('<html><body><input type="text" placeholder="nombre"></body></html>');
  const opened = await actions.openUrl(url);
  assert.strictEqual(opened.elements[0].kind, 'input');
  const result = await actions.fillElement('1', 'el usuario');
  assert.ok(result.text !== undefined, 'fillElement devuelve un snapshot valido');
});

test('clickElement con target invalido tira error legible', async () => {
  const url = 'data:text/html,' + encodeURIComponent('<html><body><p>sin elementos</p></body></html>');
  await actions.openUrl(url);
  await assert.rejects(() => actions.clickElement('99'), /target inv[aá]lido/);
});

test('scrollPage no tira error y devuelve un snapshot', async () => {
  const url = 'data:text/html,' + encodeURIComponent('<html><body><p>una pagina larga</p></body></html>');
  await actions.openUrl(url);
  const result = await actions.scrollPage('down');
  assert.ok(result.text.includes('una pagina larga'));
});

test('readCurrent devuelve el estado actual sin actuar', async () => {
  const url = 'data:text/html,' + encodeURIComponent('<html><body><p>leer sin actuar</p></body></html>');
  await actions.openUrl(url);
  const result = await actions.readCurrent();
  assert.ok(result.text.includes('leer sin actuar'));
});

test('cleanup: shutdownBrowser cierra el browser sin tirar error', async () => {
  await actions.shutdownBrowser();
});
