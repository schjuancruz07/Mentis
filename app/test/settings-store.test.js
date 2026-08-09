'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const store = require('../lib/settings-store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'settings-store-test-'));
}

test('getPublicSettings devuelve defaults si no hay archivo', () => {
  const dir = tmpDir();
  const settings = store.getPublicSettings(dir);
  assert.deepStrictEqual(settings.customModels, {});
  assert.strictEqual(settings.theme, 'bitacora-de-campo');
  assert.strictEqual(settings.profile.fullName, '');
  assert.strictEqual(settings.profile.userMemory, '');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveProfile persiste y no pisa otros campos del profile', () => {
  const dir = tmpDir();
  store.saveProfile(dir, { fullName: 'el usuario Cruz', nickname: 'Sr.' });
  store.saveProfile(dir, { role: 'otro', customRole: 'no-code' });
  const profile = store.getProfile(dir);
  assert.strictEqual(profile.fullName, 'el usuario Cruz');
  assert.strictEqual(profile.nickname, 'Sr.');
  assert.strictEqual(profile.role, 'otro');
  assert.strictEqual(profile.customRole, 'no-code');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveUserMemory persiste texto y timestamp, sin pisar el resto del perfil', () => {
  const dir = tmpDir();
  store.saveProfile(dir, { fullName: 'el usuario Cruz' });
  const before = store.saveUserMemory(dir, 'Prefiere respuestas breves.', 'usuario');
  assert.strictEqual(before.userMemory, 'Prefiere respuestas breves.');
  assert.strictEqual(before.userMemoryUpdatedBy, 'usuario');
  assert.ok(before.userMemoryUpdatedAt);
  assert.strictEqual(before.fullName, 'el usuario Cruz');

  const after = store.saveUserMemory(dir, 'Ahora tambien usa Windows.', 'mentis');
  assert.strictEqual(after.userMemory, 'Ahora tambien usa Windows.');
  assert.strictEqual(after.userMemoryUpdatedBy, 'mentis');
  assert.strictEqual(after.fullName, 'el usuario Cruz');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveSelfMemory persiste texto y timestamp, independiente de userMemory', () => {
  const dir = tmpDir();
  store.saveProfile(dir, { fullName: 'el usuario Cruz' });
  store.saveUserMemory(dir, 'A el usuario le gusta el mate.', 'mentis');

  const before = store.saveSelfMemory(dir, 'Soy directa, tiendo a cuestionar suposiciones.', 'mentis');
  assert.strictEqual(before.selfMemory, 'Soy directa, tiendo a cuestionar suposiciones.');
  assert.strictEqual(before.selfMemoryUpdatedBy, 'mentis');
  assert.ok(before.selfMemoryUpdatedAt);
  assert.strictEqual(before.userMemory, 'A el usuario le gusta el mate.', 'no debe pisar la memoria sobre el usuario');

  const after = store.saveSelfMemory(dir, 'Corregido por el usuario a mano.', 'usuario');
  assert.strictEqual(after.selfMemory, 'Corregido por el usuario a mano.');
  assert.strictEqual(after.selfMemoryUpdatedBy, 'usuario');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveCustomModel + getPublicSettings no expone la api key real', () => {
  const dir = tmpDir();
  store.saveCustomModel(dir, 'code', {
    provider: 'openai-compatible', baseUrl: 'https://api.example.com/v1', model: 'gpt-4o', apiKey: 'sk-secreta'
  });
  const settings = store.getPublicSettings(dir);
  assert.strictEqual(settings.customModels.code.hasKey, true);
  assert.strictEqual(JSON.stringify(settings).includes('sk-secreta'), false);
  store.removeCustomModel(dir, 'code');
  assert.deepStrictEqual(store.getPublicSettings(dir).customModels, {});
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveIdeogramKey y removeIdeogramKey', () => {
  const dir = tmpDir();
  assert.strictEqual(store.getIdeogramStatus(dir).hasKey, false);
  store.saveIdeogramKey(dir, 'ideo-key-123');
  assert.strictEqual(store.getIdeogramStatus(dir).hasKey, true);
  store.removeIdeogramKey(dir);
  assert.strictEqual(store.getIdeogramStatus(dir).hasKey, false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('getConnectorEnabled default true si nunca se toco, y persiste el toggle', () => {
  const dir = tmpDir();
  assert.strictEqual(store.getConnectorEnabled(dir, 'local:terminal'), true, 'default debe ser habilitado');
  store.setConnectorEnabled(dir, 'local:terminal', false);
  assert.strictEqual(store.getConnectorEnabled(dir, 'local:terminal'), false);
  assert.strictEqual(store.getConnectorEnabled(dir, 'api:runway'), true, 'no debe afectar otros ids');
  store.setConnectorEnabled(dir, 'local:terminal', true);
  assert.strictEqual(store.getConnectorEnabled(dir, 'local:terminal'), true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveRunwayKey y removeRunwayKey, sin pisar la de Ideogram', () => {
  const dir = tmpDir();
  store.saveIdeogramKey(dir, 'ideo-key-123');
  assert.strictEqual(store.getRunwayStatus(dir).hasKey, false);
  store.saveRunwayKey(dir, 'key_runway_test');
  assert.strictEqual(store.getRunwayStatus(dir).hasKey, true);
  assert.strictEqual(store.getIdeogramStatus(dir).hasKey, true, 'guardar Runway no debe borrar la key de Ideogram');
  store.removeRunwayKey(dir);
  assert.strictEqual(store.getRunwayStatus(dir).hasKey, false);
  assert.strictEqual(store.getIdeogramStatus(dir).hasKey, true, 'borrar Runway no debe tocar Ideogram');
  fs.rmSync(dir, { recursive: true, force: true });
});

// --- Voz / fin de frase (2026-07-28) -------------------------------------------------------
test('getVoz devuelve los defaults cuando no hay nada guardado', () => {
  const dir = tmpDir();
  const voz = store.getVoz(dir);
  assert.strictEqual(voz.silencioMs, 1100);
  assert.strictEqual(voz.factorSensibilidad, 3.5);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('saveVoz persiste y deja modificar un campo sin pisar el otro', () => {
  const dir = tmpDir();
  store.saveVoz(dir, { silencioMs: 1800 });
  assert.strictEqual(store.getVoz(dir).factorSensibilidad, 3.5);
  store.saveVoz(dir, { factorSensibilidad: 5 });
  const voz = store.getVoz(dir);
  assert.strictEqual(voz.silencioMs, 1800);
  assert.strictEqual(voz.factorSensibilidad, 5);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('getVoz acota valores absurdos en vez de dejar a Mentis sordo o colgado', () => {
  const dir = tmpDir();
  // 50 ms cortaria en la primera pausa entre palabras; 10 minutos parece que se colgo.
  store.saveVoz(dir, { silencioMs: 50, factorSensibilidad: 0.1 });
  let voz = store.getVoz(dir);
  assert.strictEqual(voz.silencioMs, 400, 'silencio minimo acotado');
  assert.strictEqual(voz.factorSensibilidad, 1.5, 'factor minimo acotado');
  store.saveVoz(dir, { silencioMs: 600000, factorSensibilidad: 99 });
  voz = store.getVoz(dir);
  assert.strictEqual(voz.silencioMs, 4000, 'silencio maximo acotado');
  assert.strictEqual(voz.factorSensibilidad, 8, 'factor maximo acotado');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('getVoz ignora basura no numerica y vuelve al default', () => {
  const dir = tmpDir();
  store.saveVoz(dir, { silencioMs: 'mucho' });
  assert.strictEqual(store.getVoz(dir).silencioMs, 1100);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('getPublicSettings incluye los ajustes de voz para el renderer', () => {
  const dir = tmpDir();
  store.saveVoz(dir, { silencioMs: 1500 });
  assert.strictEqual(store.getPublicSettings(dir).voz.silencioMs, 1500);
  fs.rmSync(dir, { recursive: true, force: true });
});
