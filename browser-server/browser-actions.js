'use strict';

const { chromium } = require('playwright');
const { formatPage } = require('./page-formatter');

let browser = null;
let page = null;
let lastHandles = [];

async function ensureBrowser() {
  if (!browser) {
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage();
  }
  return page;
}

async function _snapshot() {
  const result = await formatPage(page, 2000);
  lastHandles = result.handles;
  return { text: result.text, elements: result.elements };
}

function _resolveTarget(targetStr) {
  const idx = parseInt(targetStr, 10) - 1;
  if (Number.isNaN(idx) || idx < 0 || idx >= lastHandles.length) {
    return null;
  }
  return lastHandles[idx];
}

async function openUrl(url) {
  await ensureBrowser();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
  // Esperar a que la página TERMINE de cargar antes de sacarle la foto (bug real 2026-07-27).
  // Con sólo 'domcontentloaded' el snapshot salía a mitad de camino: en Bing devolvía la barra
  // de navegación y CERO resultados, porque los resultados los pinta JavaScript después. Mentis
  // concluyó de eso que "la búsqueda web está bloqueada" y se lo guardó como una limitación
  // permanente en memoria -- durante semanas se negó a buscar en la web por esta línea.
  // clickElement() ya esperaba networkidle; abrir una URL no. El.catch() es a propósito: si la
  // página tiene conexiones que nunca cierran (websockets, analytics), se sigue igual con lo que
  // haya cargado, que es mejor que fallar.
  await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
  return _snapshot();
}

async function clickElement(targetStr) {
  await ensureBrowser();
  const handle = _resolveTarget(targetStr);
  if (!handle) {
    throw new Error(`target invalido: ${targetStr}`);
  }
  await handle.click();
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
  return _snapshot();
}

async function fillElement(targetStr, value) {
  await ensureBrowser();
  const handle = _resolveTarget(targetStr);
  if (!handle) {
    throw new Error(`target invalido: ${targetStr}`);
  }
  await handle.fill(value);
  return _snapshot();
}

async function scrollPage(direction) {
  await ensureBrowser();
  const delta = direction === 'up' ? -500 : 500;
  await page.evaluate((d) => window.scrollBy(0, d), delta);
  return _snapshot();
}

async function readCurrent() {
  await ensureBrowser();
  return _snapshot();
}

async function shutdownBrowser() {
  if (browser) {
    await browser.close();
    browser = null;
    page = null;
    lastHandles = [];
  }
}

module.exports = { openUrl, clickElement, fillElement, scrollPage, readCurrent, shutdownBrowser };
