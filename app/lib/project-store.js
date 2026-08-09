'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

// Proyectos (pedido del usuario, 2026-07-13): a diferencia de una "carpeta" (agrupa conversaciones
// existentes, sin tocar el disco), un proyecto es una carpeta REAL bajo Documents/Mentis con
// subdivisiones fijas -- "Archivos" (donde Mentis lee/escribe, pasa a ser el ROOT del chat de
// ese proyecto) y "Referencias" (material que el usuario deja ahí para que Mentis lo tenga a mano).
// No limita a Mentis a ese entorno cerrado -- es su espacio de trabajo para ESE proyecto, las
// demás capacidades (browse/mcp/gen/etc.) siguen funcionando igual que en cualquier chat.

function projectsRootDir() {
  return path.join(os.homedir(), 'Documents', 'Mentis', 'Proyectos');
}

function indexPath(convDir) {
  return path.join(convDir, 'projects.json');
}

// Migración real encontrada (2026-07-14, revisando el estado real de projects.json): proyectos
// creados ANTES de que conversationId (singular) pasara a conversationIds[] quedaban con su
// conversación original huérfana -- getProjectByConversation/listProjectConversations solo
// miran conversationIds, así que esa conversación vieja dejaba de mostrar el badge/aparecer en
// el sidebar. Se normaliza acá, en el único punto de lectura, para que sea invisible en todos
// los callers -- si conversationId (legacy) existe y no está en conversationIds, se agrega
// (al principio, respetando el orden original).
function migrateProject(p) {
  if (p.conversationId && !(p.conversationIds || []).includes(p.conversationId)) {
    p.conversationIds = [p.conversationId,...(p.conversationIds || [])];
  } else if (!p.conversationIds) {
    p.conversationIds = [];
  }
  return p;
}

function loadIndex(convDir) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(indexPath(convDir), 'utf-8'));
  } catch {
    return { projects: [] };
  }
  let migrated = false;
  for (const p of data.projects || []) {
    const before = JSON.stringify(p.conversationIds || null);
    migrateProject(p);
    if (JSON.stringify(p.conversationIds) !== before) migrated = true;
  }
  if (migrated) saveIndex(convDir, data);
  return data;
}

function saveIndex(convDir, data) {
  fs.mkdirSync(convDir, { recursive: true });
  fs.writeFileSync(indexPath(convDir), JSON.stringify(data, null, 2), 'utf-8');
}

function slugify(name) {
  const base = name
.trim().toLowerCase()
.normalize('NFD').replace(/[̀-ͯ]/g, '')
.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  return base || 'proyecto';
}

// Nombre de carpeta = el nombre que el usuario escribió (pedido 2026-07-25). Antes la carpeta usaba
// el slug: escribías "Proyecto de prueba" y en el disco aparecía "proyecto-de-prueba" -- en
// minúscula y con guiones, que no es lo que pusiste. El slug se sigue guardando en el índice
// (lo usan las URLs internas y el código viejo), pero ya no manda en el disco.
//
// Windows prohíbe < > : " / \ | ? * y los caracteres de control en nombres de archivo, no
// permite terminar en punto o espacio, y reserva nombres del DOS (CON, PRN, AUX, NUL, COM1..9,
// LPT1..9) incluso con extensión. Si no se sanea, un proyecto llamado "Cliente: ACME" o "CON"
// hace fallar el mkdir con un error críptico de Node en vez de crearse.
const NOMBRES_RESERVADOS_WINDOWS = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;
function nombreDeCarpetaSeguro(name) {
  let limpio = (name || '')
.trim()
.replace(/[<>:"/\\|?*]/g, '-')      // prohibidos por Windows -> guion
    // eslint-disable-next-line no-control-regex
.replace(/[\x00-\x1f]/g, '')         // caracteres de control
.replace(/\s+/g, ' ')                // espacios repetidos
.replace(/[. ]+$/, '');              // Windows no tolera terminar en punto o espacio
  if (NOMBRES_RESERVADOS_WINDOWS.test(limpio)) limpio = limpio + '-proyecto';
  // 120 caracteres deja aire para las subcarpetas y los archivos de adentro sin acercarse al
  // límite de 260 de las rutas de Windows.
  if (limpio.length > 120) limpio = limpio.slice(0, 120).trim();
  return limpio || 'Proyecto';
}

// Subdivisiones de cada proyecto (pedido del usuario 2026-07-25: "todas las subdivisiones que
// tenés vos en tu carpeta de proyectos"). Calcadas de cómo Claude Code organiza un proyecto:
// el trabajo en curso, el material de consulta, la memoria persistente, lo que se adjunta y
// lo que sale terminado -- cada cosa en su lugar en vez de todo mezclado en una carpeta.
// Para cambiarlas alcanza con editar esta lista: createProject las crea todas.
const SUBCARPETAS = [
  { nombre: 'Archivos',    descripcion: 'Donde Mentis lee y escribe mientras trabaja. Es la raíz del chat de este proyecto.' },
  { nombre: 'Referencias', descripcion: 'Material de consulta que dejás vos para que Mentis lo tenga a mano.' },
  { nombre: 'Memoria',     descripcion: 'Notas que persisten entre conversaciones de este proyecto.' },
  { nombre: 'Adjuntos',    descripcion: 'Lo que subís al chat dentro de este proyecto.' },
  { nombre: 'Entregables', descripcion: 'Lo terminado: lo que se entrega o se publica.' }
];

// Los proyectos creados ANTES del 2026-07-25 solo tienen Archivos/ y Referencias/. Esto les
// agrega las subdivisiones nuevas cuando se los lista, para que no queden a medias respecto de
// los que se creen de ahora en adelante.
// Deliberadamente NO renombra la carpeta vieja al nombre nuevo: la ruta de un proyecto puede
// ser el ROOT de una conversación abierta en este mismo momento, y moverla debajo de un proceso
// vivo dejaría a Mentis escribiendo en una carpeta que ya no existe. Renombrar es una decisión
// del usuario, no un efecto colateral de abrir la lista.
function ensureSubfolders(project) {
  try {
    if (!project.dir || !fs.existsSync(project.dir)) return project;
    for (const sub of SUBCARPETAS) {
      const p = path.join(project.dir, sub.nombre);
      if (!fs.existsSync(p)) fs.mkdirSync(p, { recursive: true });
    }
    if (!project.memoryDir) project.memoryDir = path.join(project.dir, 'Memoria');
    if (!project.attachmentsDir) project.attachmentsDir = path.join(project.dir, 'Adjuntos');
    if (!project.deliverablesDir) project.deliverablesDir = path.join(project.dir, 'Entregables');
    if (!project.folderName) project.folderName = path.basename(project.dir);
  } catch { /* si el disco no deja, el proyecto sigue usable con lo que ya tenía */ }
  return project;
}

function listProjects(convDir) {
  return loadIndex(convDir).projects.map(ensureSubfolders);
}

function createProject(convDir, name, conversationId) {
  const trimmed = (name || '').trim();
  if (!trimmed) throw new Error('el proyecto necesita un nombre');
  const root = projectsRootDir();
  fs.mkdirSync(root, { recursive: true });
  const baseSlug = slugify(trimmed);
  const baseNombre = nombreDeCarpetaSeguro(trimmed);
  // La carpeta lleva el nombre escrito; el sufijo numérico solo aparece si ya existe otra con
  // ese mismo nombre (dos proyectos "Cliente ACME" no pueden compartir carpeta).
  let slug = baseSlug;
  let nombreCarpeta = baseNombre;
  let dir = path.join(root, nombreCarpeta);
  let n = 2;
  while (fs.existsSync(dir)) {
    nombreCarpeta = `${baseNombre} (${n})`;
    slug = `${baseSlug}-${n}`;
    dir = path.join(root, nombreCarpeta);
    n += 1;
  }
  for (const sub of SUBCARPETAS) {
    fs.mkdirSync(path.join(dir, sub.nombre), { recursive: true });
  }
  // Un LEEME dentro del proyecto: sin esto, cinco carpetas vacías no le dicen a nadie para qué
  // es cada una (ni al usuario dentro de dos meses, ni a Mentis si explora el directorio).
  try {
    const leeme = [
      `# ${trimmed}`,
      '',
      `Proyecto de Mentis, creado el ${new Date().toLocaleDateString('es-AR')}.`,
      '',
      '## Para qué es cada carpeta',
      '',
...SUBCARPETAS.map((s) => `- **${s.nombre}/** — ${s.descripcion}`),
      ''
    ].join('\n');
    fs.writeFileSync(path.join(dir, 'LEEME.md'), leeme, 'utf-8');
  } catch { /* el LEEME es un extra: si falla, el proyecto igual queda usable */ }
  const project = {
    id: 'proj-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8),
    name: trimmed,
    slug,
    folderName: nombreCarpeta,
    dir,
    workRoot: path.join(dir, 'Archivos'),
    referencesDir: path.join(dir, 'Referencias'),
    memoryDir: path.join(dir, 'Memoria'),
    attachmentsDir: path.join(dir, 'Adjuntos'),
    deliverablesDir: path.join(dir, 'Entregables'),
    // Historial scopeado por proyecto (pedido del usuario, 2026-07-13: "el historial de chat
    // INCLUIDO en el proyecto" -- un proyecto puede tener VARIAS conversaciones propias, no
    // solo una fija para siempre). Se guarda un array; conversationId queda como alias del
    // primero, SOLO para no romper código viejo que todavia lo lea así.
    conversationIds: [conversationId],
    createdAt: new Date().toISOString()
  };
  const data = loadIndex(convDir);
  data.projects.push(project);
  saveIndex(convDir, data);
  return project;
}

// Agrega una conversación nueva a un proyecto ya existente (pedido del usuario: poder abrir más de
// un chat dentro del mismo proyecto, todos viendo el mismo ROOT de Archivos/).
function addConversationToProject(convDir, projectId, conversationId) {
  const data = loadIndex(convDir);
  const project = data.projects.find((p) => p.id === projectId);
  if (!project) throw new Error('proyecto no encontrado: ' + projectId);
  project.conversationIds = project.conversationIds || [];
  project.conversationIds.push(conversationId);
  saveIndex(convDir, data);
  return project;
}

function getProjectByConversation(convDir, conversationId) {
  return loadIndex(convDir).projects.find((p) => (p.conversationIds || []).includes(conversationId)) || null;
}

function getProject(convDir, projectId) {
  return loadIndex(convDir).projects.find((p) => p.id === projectId) || null;
}

function deleteProject(convDir, projectId) {
  const data = loadIndex(convDir);
  const before = data.projects.length;
  data.projects = data.projects.filter((p) => p.id !== projectId);
  if (data.projects.length === before) return false;
  saveIndex(convDir, data);
  return true;
}

module.exports = {
  listProjects, createProject, addConversationToProject, getProjectByConversation, getProject,
  deleteProject, projectsRootDir, nombreDeCarpetaSeguro, SUBCARPETAS
};
