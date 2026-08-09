'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const store = require('../lib/project-store');

// OJO: createProject() escribe la carpeta real SIEMPRE bajo el Documents/Mentis/Proyectos/ del
// usuario de verdad (projectsRootDir() no es inyectable, es fijo) -- el convDir de tmpDir()
// solo controla el projects.json de indice. Cada test tiene que borrar p.dir explicitamente
// para no ensuciar la carpeta real del usuario con proyectos de prueba con nombre "test-...".
function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'project-store-test-'));
}

test('migración: un proyecto legacy (solo conversationId, sin conversationIds) queda encontrable', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'projects.json'), JSON.stringify({
    projects: [{ id: 'proj-legacy', name: 'Legacy', slug: 'legacy', dir: 'C:\\fake', conversationId: 'conv-vieja', createdAt: '2026-01-01T00:00:00Z' }]
  }), 'utf-8');
  const projects = store.listProjects(dir);
  assert.deepStrictEqual(projects[0].conversationIds, ['conv-vieja']);
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-vieja').id, 'proj-legacy');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('migración: conversationId legacy que quedó afuera de un conversationIds parcial se recupera', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'projects.json'), JSON.stringify({
    projects: [{ id: 'proj-partial', name: 'Partial', slug: 'partial', dir: 'C:\\fake', conversationId: 'conv-vieja', conversationIds: ['conv-nueva'], createdAt: '2026-01-01T00:00:00Z' }]
  }), 'utf-8');
  const projects = store.listProjects(dir);
  assert.deepStrictEqual(projects[0].conversationIds, ['conv-vieja', 'conv-nueva']);
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-vieja').id, 'proj-partial');
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-nueva').id, 'proj-partial');
  fs.rmSync(dir, { recursive: true, force: true });
});

function cleanup(convDir,...projectDirs) {
  fs.rmSync(convDir, { recursive: true, force: true });
  for (const d of projectDirs) fs.rmSync(d, { recursive: true, force: true });
}

test('createProject crea Archivos/ y Referencias/ reales en disco', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'test-mentis-cdp-1', 'conv-1');
  assert.ok(fs.existsSync(p.workRoot));
  assert.ok(fs.existsSync(p.referencesDir));
  assert.deepStrictEqual(p.conversationIds, ['conv-1']);
  cleanup(dir, p.dir);
});

test('addConversationToProject agrega sin pisar las anteriores', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'test-mentis-cdp-2', 'conv-1');
  store.addConversationToProject(dir, p.id, 'conv-2');
  store.addConversationToProject(dir, p.id, 'conv-3');
  const reloaded = store.getProject(dir, p.id);
  assert.deepStrictEqual(reloaded.conversationIds, ['conv-1', 'conv-2', 'conv-3']);
  cleanup(dir, p.dir);
});

test('getProjectByConversation encuentra el proyecto para CUALQUIERA de sus conversaciones', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'test-mentis-cdp-3', 'conv-1');
  store.addConversationToProject(dir, p.id, 'conv-2');
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-1').id, p.id);
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-2').id, p.id);
  assert.strictEqual(store.getProjectByConversation(dir, 'conv-otra'), null);
  cleanup(dir, p.dir);
});

test('dos proyectos con el mismo nombre no colisionan de carpeta', () => {
  const dir = tmpDir();
  const p1 = store.createProject(dir, 'test-mentis-cdp-dup', 'conv-1');
  const p2 = store.createProject(dir, 'test-mentis-cdp-dup', 'conv-2');
  assert.notStrictEqual(p1.dir, p2.dir);
  assert.ok(fs.existsSync(p1.workRoot));
  assert.ok(fs.existsSync(p2.workRoot));
  cleanup(dir, p1.dir, p2.dir);
});

// ===== Nombre de carpeta real + subdivisiones (pedido del usuario, 2026-07-25) =====
// Antes la carpeta usaba el slug: escribías "Proyecto de prueba" y en el disco te aparecía
// "proyecto-de-prueba". Estos tests fijan que la carpeta lleve el nombre tal cual se escribió,
// que Windows no la rechace, y que estén las cinco subdivisiones.

test('la carpeta del proyecto usa el NOMBRE escrito, no el slug', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'Proyecto de prueba', 'conv-1');
  try {
    assert.strictEqual(path.basename(p.dir), 'Proyecto de prueba',
      `la carpeta deberia llamarse como lo escribio el usuario, no "${path.basename(p.dir)}"`);
    assert.strictEqual(p.slug, 'proyecto-de-prueba', 'el slug se sigue guardando en el indice');
    assert.ok(fs.existsSync(p.dir), 'la carpeta tiene que existir de verdad en el disco');
  } finally {
    fs.rmSync(p.dir, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('se crean las cinco subdivisiones y el LEEME', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'Test Subdivisiones', 'conv-1');
  try {
    for (const sub of store.SUBCARPETAS) {
      assert.ok(fs.existsSync(path.join(p.dir, sub.nombre)), `falta la subcarpeta ${sub.nombre}`);
    }
    assert.ok(fs.existsSync(path.join(p.dir, 'LEEME.md')), 'falta el LEEME que explica cada carpeta');
    assert.ok(fs.readFileSync(path.join(p.dir, 'LEEME.md'), 'utf-8').includes('Entregables'));
    // las rutas nuevas quedan en el indice, no solo en el disco
    assert.strictEqual(p.memoryDir, path.join(p.dir, 'Memoria'));
    assert.strictEqual(p.deliverablesDir, path.join(p.dir, 'Entregables'));
  } finally {
    fs.rmSync(p.dir, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('nombres que Windows prohibe se sanean en vez de romper el mkdir', () => {
  // Sin saneo, "Cliente: ACME" o "CON" hacen fallar el mkdir con un error criptico de Node.
  assert.strictEqual(store.nombreDeCarpetaSeguro('Cliente: ACME'), 'Cliente- ACME');
  // String.raw para que la barra invertida sea una barra invertida de verdad y no un escape de JS
  assert.strictEqual(store.nombreDeCarpetaSeguro(String.raw`a/b\c*d?`), 'a-b-c-d-');
  assert.strictEqual(store.nombreDeCarpetaSeguro('CON'), 'CON-proyecto');
  assert.strictEqual(store.nombreDeCarpetaSeguro('termina en punto.'), 'termina en punto');
  assert.strictEqual(store.nombreDeCarpetaSeguro('   '), 'Proyecto');
  assert.ok(store.nombreDeCarpetaSeguro('x'.repeat(300)).length <= 120);
});

test('dos proyectos con el mismo nombre no comparten carpeta', () => {
  const dir = tmpDir();
  const a = store.createProject(dir, 'Duplicado Test', 'conv-a');
  const b = store.createProject(dir, 'Duplicado Test', 'conv-b');
  try {
    assert.notStrictEqual(a.dir, b.dir, 'el segundo tiene que ir a una carpeta propia');
    assert.strictEqual(path.basename(b.dir), 'Duplicado Test (2)');
    assert.ok(fs.existsSync(a.dir) && fs.existsSync(b.dir));
  } finally {
    fs.rmSync(a.dir, { recursive: true, force: true });
    fs.rmSync(b.dir, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('un nombre con acentos y ñ sobrevive tal cual en el disco', () => {
  const dir = tmpDir();
  const p = store.createProject(dir, 'Diseño Gráfico Ñandú', 'conv-1');
  try {
    assert.strictEqual(path.basename(p.dir), 'Diseño Gráfico Ñandú');
    assert.ok(fs.existsSync(path.join(p.dir, 'Entregables')));
  } finally {
    fs.rmSync(p.dir, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('un proyecto viejo (solo Archivos/Referencias) recibe las subdivisiones nuevas al listarlo', () => {
  const dir = tmpDir();
  const viejoDir = path.join(os.tmpdir(), 'proyecto-viejo-test-' + Date.now());
  fs.mkdirSync(path.join(viejoDir, 'Archivos'), { recursive: true });
  fs.mkdirSync(path.join(viejoDir, 'Referencias'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'projects.json'), JSON.stringify({
    projects: [{ id: 'proj-viejo', name: 'Viejo', slug: 'viejo', dir: viejoDir, conversationIds: ['c1'], createdAt: '2026-07-13T00:00:00Z' }]
  }), 'utf-8');
  try {
    const [p] = store.listProjects(dir);
    assert.ok(fs.existsSync(path.join(viejoDir, 'Memoria')), 'deberia haberse creado Memoria/');
    assert.ok(fs.existsSync(path.join(viejoDir, 'Entregables')), 'deberia haberse creado Entregables/');
    assert.strictEqual(p.memoryDir, path.join(viejoDir, 'Memoria'), 'y las rutas quedan en el objeto');
    // La carpeta NO se renombra: puede ser el ROOT de una conversacion abierta ahora mismo.
    assert.strictEqual(p.dir, viejoDir, 'la carpeta vieja no se toca');
  } finally {
    fs.rmSync(viejoDir, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('listProjects no explota si la carpeta del proyecto ya no existe en el disco', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'projects.json'), JSON.stringify({
    projects: [{ id: 'p1', name: 'Borrado a mano', slug: 'borrado', dir: path.join(os.tmpdir(), 'no-existe-' + Date.now()), conversationIds: ['c1'] }]
  }), 'utf-8');
  try {
    const proyectos = store.listProjects(dir);
    assert.strictEqual(proyectos.length, 1, 'sigue apareciendo en el indice aunque falte la carpeta');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
