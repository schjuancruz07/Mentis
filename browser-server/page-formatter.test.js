'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { chromium } = require('playwright');
const { formatPage } = require('./page-formatter');

test('formatPage extrae texto y elementos interactivos de una pagina fixture', async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,' + encodeURIComponent(
      '<html><body><p>Hola mundo</p><a href="#">Ir a X</a><button>Enviar</button><input type="text" placeholder="usuario"></body></html>'
    ));
    const result = await formatPage(page, 2000);
    assert.ok(result.text.includes('Hola mundo'), 'el texto incluye el contenido visible');
    assert.strictEqual(result.elements.length, 3, 'detecta los 3 elementos interactivos');
    assert.strictEqual(result.elements[0].kind, 'link');
    assert.strictEqual(result.elements[0].label, 'Ir a X');
    assert.strictEqual(result.elements[0].n, 1);
    assert.strictEqual(result.elements[1].kind, 'button');
    assert.strictEqual(result.elements[1].label, 'Enviar');
    assert.strictEqual(result.elements[2].kind, 'input');
    assert.strictEqual(result.elements[2].label, 'usuario');
    assert.strictEqual(result.handles.length, 3, 'devuelve un ElementHandle por cada elemento detectado');
  } finally {
    await browser.close();
  }
});

test('formatPage trunca el texto a maxChars y agrega sufijo', async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    const longText = 'x'.repeat(3000);
    await page.goto('data:text/html,' + encodeURIComponent(`<html><body><p>${longText}</p></body></html>`));
    const result = await formatPage(page, 100);
    assert.ok(result.text.length <= 103, 'el texto truncado no excede maxChars + "..."');
    assert.ok(result.text.endsWith('...'), 'el texto truncado termina con...');
  } finally {
    await browser.close();
  }
});

test('formatPage ignora elementos no visibles', async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,' + encodeURIComponent(
      '<html><body><a href="#" style="display:none">oculto</a><a href="#">visible</a></body></html>'
    ));
    const result = await formatPage(page, 2000);
    assert.strictEqual(result.elements.length, 1, 'solo cuenta el elemento visible');
    assert.strictEqual(result.elements[0].label, 'visible');
  } finally {
    await browser.close();
  }
});
