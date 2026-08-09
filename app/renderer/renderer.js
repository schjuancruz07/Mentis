'use strict';

let activeConversationId = null;
let turnInFlight = false;
let foldersData = { folders: [], assignments: {} };
let collapsedFolders = new Set();
let pendingAttachments = [];
const TASK_LOG_RE = /^\[nv-agent\] iter \d+: (.+)$/;
const PREVIEW_LOG_RE = /^\[nv-agent\] PREVIEW: (.*)$/;
// Cuántos pasos tiene permitidos el turno. Lo emite nv-agent.sh al arrancar; sirve para mostrar
// "paso 3 de 10" en vez de un "paso 3" que no dice si falta mucho o nada.
const PRESUPUESTO_LOG_RE = /^\[nv-agent\] PRESUPUESTO: (\d+)$/;

// Miniatura de adjuntos en el historial (pedido del usuario, 2026-07-14): antes el tag
// "[archivo adjunto:...]" quedaba visible como texto crudo en la burbuja, tanto en el mensaje
// recién mandado como al recargar el historial. Ahora se saca del texto y, si es imagen, se
// muestra como miniatura real (mismo mecanismo file:// que ya usa la previsualización del
// composer -- ver copyAttachment en main.js).
const ATTACHMENT_TAG_RE = /\[archivo adjunto: ([^\]]+)\]\s*/g;
const IMAGE_EXT_RE = /\.(png|jpe?g|gif|webp|svg|bmp)$/i;
let workspaceRootPromise = null;
function getWorkspaceRoot() {
  if (!workspaceRootPromise) workspaceRootPromise = window.mentisAPI.getWorkspaceRoot();
  return workspaceRootPromise;
}
function attachmentFileUrl(root, relativePath) {
  return 'file://' + `${root}/${relativePath}`.replace(/\\/g, '/');
}
function extractAttachmentPaths(text) {
  const paths = [];
  const cleanText = text.replace(ATTACHMENT_TAG_RE, (_match, p) => { paths.push(p); return ''; }).trim();
  return { cleanText, paths };
}
// Fix 2026-07-15 (el chat se corria al llegar una miniatura): antes cada mensaje con
// adjunto pedia getWorkspaceRoot() y armaba su fila de miniatura por su cuenta, async,
// DESPUES de que renderMessages() ya habia terminado de pintar todo -- con varios mensajes
// con adjunto en el historial, cada uno insertaba su fila en un tick propio, y el chat se
// iba corriendo de a poco. Ahora el root se resuelve UNA sola vez por render (ver
// renderMessages/appendOptimisticBubble) y esta version sincronica arma la fila al toque,
// en la misma pasada que arma el resto del mensaje.
function buildMessageAttachmentThumbsSync(root, paths) {
  if (paths.length === 0) return null;
  const row = document.createElement('div');
  row.className = 'message-attach-row';
  paths.forEach((relPath) => {
    if (IMAGE_EXT_RE.test(relPath)) {
      const img = document.createElement('img');
      img.className = 'message-attach-thumb';
      img.src = attachmentFileUrl(root, relPath);
      img.alt = relPath.split(/[\\/]/).pop();
      row.appendChild(img);
    } else {
      const chip = document.createElement('span');
      chip.className = 'message-attach-file-chip';
      chip.textContent = relPath.split(/[\\/]/).pop();
      row.appendChild(chip);
    }
  });
  return row;
}

// Catálogo de skills/plugins para el autocomplete "/" (pedido del usuario, 2026-07-12).
let capabilityCatalog = [];
async function loadCapabilityCatalog() {
  try {
    capabilityCatalog = await window.mentisAPI.listCapabilities();
  } catch {
    capabilityCatalog = [];
  }
}

// Traduce una línea cruda de acción (ej. "read foo.sh", "delegate -> code") a una frase legible
// en español para la narración de proceso en vivo (pedido del usuario, 2026-07-12: "que vaya
// diciendo qué está haciendo, como vos"). Sin emoji (pedido del usuario, 2026-07-13) -- el estado
// se distingue por color (ver.live-step.error en el CSS), no por pictograma. Las líneas de
// rechazo/fallo se muestran tal cual, ya son más informativas que cualquier traducción genérica.
function humanizeStep(action) {
  if (/RECHAZADO|FALLO|BLOQUEADO|no devolvió JSON/.test(action)) {
    return { text: action, isError: true };
  }
  const word = action.split(' ')[0];
  const rest = action.slice(word.length).trim();
  let text;
  switch (word) {
    case 'read': text = rest ? `Leyendo ${rest}` : 'Leyendo un archivo'; break;
    case 'write': text = rest ? `Escribiendo ${rest}` : 'Escribiendo un archivo'; break;
    case 'search': text = rest ? `Buscando ${rest}` : 'Buscando en el proyecto'; break;
    case 'run': text = 'Ejecutando código en un sandbox aislado'; break;
    case 'exec': text = 'Ejecutando un comando'; break;
    case 'browse': text = `Navegando la web (${rest || '...'})`; break;
    case 'mcp': text = rest.startsWith('list') ? 'Consultando qué herramientas externas hay disponibles' : `Usando una herramienta externa (${rest.replace(/^call /, '')})`; break;
    case 'gen': text = `Generando contenido (${rest})`; break;
    case 'screen': text = 'Mirando la pantalla'; break;
    case 'webcam': text = 'Mirando por la cámara'; break;
    case 'control': text = `Controlando mouse/teclado (${rest})`; break;
    case 'recordar': text = 'Buscando en lo que hablamos antes'; break;
    case 'delegate': text = `Consultando a otro cerebro (${rest.replace('-> ', '')})`; break;
    case 'parallel': text = `Consultando varios cerebros a la vez (${rest})`; break;
    case 'done': text = 'Preparando la respuesta'; break;
    default: text = action;
  }
  return { text, isError: false };
}

// Panel de estadisticas (pedido del usuario, 2026-07-13, imagen 4): HORAS pico/racha/etc reales via
// IPC (lib/stats-store.js) -- si no hay actividad todavia, un mensaje corto en vez de un grid de
// ceros que parezca roto.
const PEAK_HOUR_FMT = new Intl.NumberFormat('es-AR', { minimumIntegerDigits: 2 });

function statTile(value, label) {
  const tile = document.createElement('div');
  tile.className = 'usage-stat-tile';
  const v = document.createElement('div');
  v.className = 'usage-stat-value';
  v.textContent = value;
  const l = document.createElement('div');
  l.className = 'usage-stat-label';
  l.textContent = label;
  tile.appendChild(v);
  tile.appendChild(l);
  return tile;
}

function heatmapLevel(count) {
  if (count <= 0) return 0;
  if (count <= 2) return 1;
  if (count <= 5) return 2;
  return 3;
}

// Costo/gasto real (pedido del usuario, 2026-07-14): SOLO Ideogram/Runway generan un costo real
// (NVIDIA NIM es gratis, ver ask-nvidia.sh -- no se fabrica un numero para NIM). El ledger lo
// llena mentis-usage-log.sh en cada generacion exitosa de esos dos scripts.
function renderUsageCosts(container, costs) {
  const box = document.createElement('div');
  box.className = 'usage-stats-costs';
  const total = document.createElement('div');
  total.className = 'usage-stats-costs-total';
  total.textContent = `Gasto real (Ideogram + Runway): $${costs.totalUsd.toFixed(2)}`;
  box.appendChild(total);
  if (costs.providers.length > 0) {
    const breakdown = document.createElement('div');
    breakdown.className = 'usage-stats-costs-breakdown';
    breakdown.textContent = costs.providers
.map((p) => `${p.label}: $${p.costUsd.toFixed(2)} (${p.calls} generación${p.calls === 1 ? '' : 'es'})`)
.join(' · ');
    box.appendChild(breakdown);
  }
  container.appendChild(box);
}

async function renderUsageStatsPanel(container) {
  let stats;
  let costs = null;
  try {
    stats = await window.mentisAPI.getUsageStats();
    costs = await window.mentisAPI.getUsageCosts();
  } catch {
    return; // sin IPC (no deberia pasar en la app real) -- se deja el panel vacio, no se rompe la bienvenida
  }
  container.innerHTML = '';
  if (!stats || stats.messages === 0) {
    const empty = document.createElement('div');
    empty.className = 'usage-stats-empty';
    empty.textContent = 'Tus estadísticas de uso van a aparecer acá apenas empieces a charlar con Mentis.';
    container.appendChild(empty);
    if (costs) renderUsageCosts(container, costs);
    return;
  }

  const grid = document.createElement('div');
  grid.className = 'usage-stats-grid';
  grid.appendChild(statTile(stats.sessions, 'Sesiones'));
  grid.appendChild(statTile(stats.messages, 'Mensajes'));
  grid.appendChild(statTile(stats.daysActive, 'Días activos'));
  grid.appendChild(statTile(stats.currentStreak, 'Racha actual'));
  grid.appendChild(statTile(stats.longestStreak, 'Racha más larga'));
  grid.appendChild(statTile(stats.peakHour !== null ? `${PEAK_HOUR_FMT.format(stats.peakHour)}h` : '—', 'Hora pico'));
  container.appendChild(grid);

  if (stats.modelDataAvailable) {
    const fav = document.createElement('div');
    fav.className = 'usage-stats-empty';
    fav.textContent = `Cerebro favorito: ${stats.favoriteModel}`;
    container.appendChild(fav);
  }

  const heatmap = document.createElement('div');
  heatmap.className = 'usage-heatmap';
  for (const day of stats.heatmap) {
    const cell = document.createElement('div');
    cell.className = 'usage-heatmap-cell level-' + heatmapLevel(day.count);
    cell.title = `${day.date}: ${day.count} mensaje${day.count === 1 ? '' : 's'}`;
    heatmap.appendChild(cell);
  }
  container.appendChild(heatmap);
  if (costs) renderUsageCosts(container, costs);
}

// El saludo textual (logo + burbuja aleatoria) que vivia aca se elimino (pedido del usuario,
// 2026-07-15): ese "hola" ahora pasa UNA sola vez, animado y hablado, en el splash de arranque
// de la app (ver splash.js/splash.html) -- no tiene sentido repetirlo cada vez que se abre una
// conversacion vacia. Lo unico que queda en el estado vacio es el panel de estadisticas.
function renderEmptyState() {
  // El panel de estadísticas (sesiones, mensajes, racha, mapa de calor, gasto) se retiró de acá
  // el 2026-07-27 a pedido del usuario: este cuadro pasa a ser del cuerpo digital. Los números no se
  // borraron -- renderUsageStatsPanel() sigue existiendo y se puede colgar de otra pantalla --
  // pero dejaron de ser lo primero que ves al abrir Mentis.
  const container = document.getElementById('messages');
  container.innerHTML = '';
  if (typeof acomodarCuerpo === 'function') acomodarCuerpo(false);
}

// Detecta el bloque ```mentis-question...``` que Mentis puede agregar al final
// de su respuesta para pedir una elección entre opciones concretas (protocolo
// definido en el prompt de sistema de mentis-chat.sh, MC_PERSONA).
function parseQuestionBlock(text) {
  const match = text.match(/```mentis-question\s*([\s\S]*?)```/);
  if (!match) return null;
  let data;
  try {
    data = JSON.parse(match[1]);
  } catch {
    return null;
  }
  if (!data || !Array.isArray(data.options) || data.options.length === 0) return null;
  return { before: text.slice(0, match.index).trim(), data };
}

// Nombre corto y legible para un artefacto (ruta relativa o URL) -- se muestra en el chip.
function artifactLabel(artifact) {
  if (/^https?:\/\//i.test(artifact)) {
    try {
      const host = new URL(artifact).hostname.replace(/^www\./, '');
      return 'Abrir en ' + host;
    } catch {
      return 'Abrir link';
    }
  }
  const name = artifact.split(/[\\/]/).pop();
  return 'Abrir ' + name;
}

function buildArtifactRow(artifacts) {
  const row = document.createElement('div');
  row.className = 'artifact-row';
  artifacts.forEach((artifact) => {
    const btn = document.createElement('button');
    btn.className = 'artifact-chip';
    btn.type = 'button';
    btn.textContent = artifactLabel(artifact);
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      const original = btn.textContent;
      const result = await window.mentisAPI.openArtifact(artifact);
      if (!result || !result.ok) {
        btn.textContent = 'No se pudo abrir';
        setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 2000);
      } else {
        btn.disabled = false;
      }
    });
    row.appendChild(btn);
  });
  return row;
}

let lastRenderedEntries = null;

// Edición de mensajes con ramas (pedido del usuario, 2026-07-14): SOLO los mensajes de usuario se
// pueden editar (nunca las respuestas de Mentis, mismo criterio que Claude/ChatGPT). Cada
// mensaje de usuario queda envuelto en una "fila" con un botón Editar (visible al hover, ver CSS) y
// un espacio para flechas de navegación entre ramas -- ese espacio se llena async después
// (ver injectBranchNav), no bloquea el render inicial de los mensajes.
function buildJuanMessageRow(entry, idx, workspaceRoot) {
  const row = document.createElement('div');
  row.className = 'message-row usuario';
  row.dataset.entryIndex = String(idx);

  const { cleanText, paths } = extractAttachmentPaths(entry.text);
  const bubble = document.createElement('div');
  bubble.className = 'bubble usuario';
  bubble.textContent = cleanText;
  if (paths.length > 0) {
    const thumbRow = buildMessageAttachmentThumbsSync(workspaceRoot, paths);
    if (thumbRow) row.appendChild(thumbRow);
  }
  row.appendChild(bubble);

  const toolbar = document.createElement('div');
  toolbar.className = 'message-toolbar';
  const editBtn = document.createElement('button');
  editBtn.type = 'button';
  editBtn.className = 'message-edit-btn';
  editBtn.textContent = 'Editar';
  editBtn.addEventListener('click', () => startEditingMessage(row, idx, entry.text));
  toolbar.appendChild(editBtn);
  const navSlot = document.createElement('span');
  navSlot.className = 'branch-nav-slot';
  toolbar.appendChild(navSlot);
  row.appendChild(toolbar);

  return row;
}

function startEditingMessage(row, idx, originalText) {
  if (turnInFlight) return;
  row.innerHTML = '';
  row.classList.add('editing');
  const textarea = document.createElement('textarea');
  textarea.className = 'message-edit-textarea';
  textarea.value = originalText;
  row.appendChild(textarea);

  const actions = document.createElement('div');
  actions.className = 'message-edit-actions';
  const cancelBtn = document.createElement('button');
  cancelBtn.type = 'button';
  cancelBtn.textContent = 'Cancelar';
  cancelBtn.addEventListener('click', () => renderMessagesWithBranches(lastRenderedEntries));
  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.className = 'primary';
  saveBtn.textContent = 'Guardar y regenerar';
  saveBtn.addEventListener('click', async () => {
    const newText = textarea.value.trim();
    if (!newText) return;
    saveBtn.disabled = true;
    cancelBtn.disabled = true;
    const result = await window.mentisAPI.createBranch(activeConversationId, idx);
    if (!result.ok) {
      showToast(`No se pudo crear la rama: ${result.error}`);
      saveBtn.disabled = false;
      cancelBtn.disabled = false;
      return;
    }
    await openConversation(result.conversationId);
    await sendCurrentMessage(newText);
  });
  actions.appendChild(cancelBtn);
  actions.appendChild(saveBtn);
  row.appendChild(actions);
  textarea.focus();
  textarea.setSelectionRange(textarea.value.length, textarea.value.length);
}

// Flechas "‹ i/N ›" -- se agregan DESPUES del render inicial (fetch async de siblings), para no
// meterle latencia a cada mensaje nuevo que llega en un turno normal (el caso común, sin ramas).
function injectBranchNav(siblings, conversationId) {
  const container = document.getElementById('messages');
  for (const [idxStr, members] of Object.entries(siblings)) {
    const row = container.querySelector(`.message-row[data-entry-index="${idxStr}"]`);
    const slot = row ? row.querySelector('.branch-nav-slot') : null;
    if (!slot) continue;
    const position = members.indexOf(conversationId);
    if (position === -1) continue;
    slot.innerHTML = '';
    const prevBtn = document.createElement('button');
    prevBtn.type = 'button';
    prevBtn.className = 'branch-nav-btn';
    prevBtn.textContent = '‹';
    prevBtn.disabled = position === 0;
    prevBtn.setAttribute('aria-label', 'Versión anterior de este mensaje');
    prevBtn.addEventListener('click', async () => { if (!turnInFlight) await openConversation(members[position - 1]); });
    const label = document.createElement('span');
    label.className = 'branch-nav-label';
    label.textContent = `${position + 1}/${members.length}`;
    const nextBtn = document.createElement('button');
    nextBtn.type = 'button';
    nextBtn.className = 'branch-nav-btn';
    nextBtn.textContent = '›';
    nextBtn.disabled = position === members.length - 1;
    nextBtn.setAttribute('aria-label', 'Versión siguiente de este mensaje');
    nextBtn.addEventListener('click', async () => { if (!turnInFlight) await openConversation(members[position + 1]); });
    slot.appendChild(prevBtn);
    slot.appendChild(label);
    slot.appendChild(nextBtn);
  }
}

async function renderMessagesWithBranches(entries) {
  renderMessages(entries);
  const forConversationId = activeConversationId;
  if (!forConversationId) return;
  let siblings;
  try {
    siblings = await window.mentisAPI.getBranchSiblings(forConversationId);
  } catch {
    return;
  }
  if (forConversationId !== activeConversationId || !siblings || Object.keys(siblings).length === 0) return;
  injectBranchNav(siblings, forConversationId);
}

async function renderMessages(entries) {
  lastRenderedEntries = entries;
  if (!entries || entries.length === 0) {
    renderEmptyState();
    return;
  }
  // Hay conversación: el cuerpo se corre al rincón y le deja el cuadro a los mensajes.
  if (typeof acomodarCuerpo === 'function') acomodarCuerpo(true);
  // FUGA REAL (2026-07-27): más abajo se hace container.innerHTML = '', que borra el nodo del
  // indicador de "pensando" SIN pasar por hideThinkingIndicator(). Mientras el indicador era una
  // imagen no pasaba nada; ahora es un cuerpo digital, y sin este desmontaje quedaba una escena
  // 3D viva dibujando contra un canvas que ya no está en la página.
  if (window.MentisCuerpo) window.MentisCuerpo.desmontar('pensando');
  // Fix 2026-07-15: el root de workspace se resuelve UNA sola vez ACA, antes de armar
  // ningun mensaje -- no por mensaje (ver buildMessageAttachmentThumbsSync), asi el chat
  // entero se pinta en una sola pasada sincronica sin ir corriendose de a poco.
  const needsRoot = entries.some((e) => typeof e.text === 'string' && e.text.includes('[archivo adjunto:'));
  const workspaceRoot = needsRoot ? await getWorkspaceRoot() : null;
  const container = document.getElementById('messages');
  container.innerHTML = '';
  entries.forEach((entry, idx) => {
    const isMentis = entry.role !== 'usuario';
    if (isMentis && Array.isArray(entry.steps) && entry.steps.length > 0) {
      container.appendChild(buildStepsSummary(entry.steps));
    }
    const parsed = isMentis ? parseQuestionBlock(entry.text) : null;
    if (parsed) {
      if (parsed.before) {
        const div = document.createElement('div');
        div.className = 'bubble mentis';
        pintarFormateado(div, parsed.before);
        container.appendChild(div);
      }
      if (idx === entries.length - 1) {
        container.appendChild(buildQuestionCard(parsed.data));
      }
    } else if (isMentis) {
      const div = document.createElement('div');
      div.className = 'bubble mentis';
      pintarFormateado(div, entry.text);
      container.appendChild(div);
    } else {
      container.appendChild(buildJuanMessageRow(entry, idx, workspaceRoot));
    }
    if (isMentis && Array.isArray(entry.artifacts) && entry.artifacts.length > 0) {
      container.appendChild(buildArtifactRow(entry.artifacts));
    }
  });
  container.scrollTop = container.scrollHeight;
}

// Resumen colapsado de los pasos que Mentis dio en un turno ya persistido (entry.steps,
// guardado por mentis-chat.sh junto al resto del historial) -- "▾ N pasos" arriba de la
// respuesta, plegado por defecto (no repite en cada reload lo que ya se vio en vivo).
function buildStepsSummary(steps) {
  const details = document.createElement('details');
  details.className = 'steps-summary';
  const summary = document.createElement('summary');
  summary.textContent = `${steps.length} paso${steps.length === 1 ? '' : 's'}`;
  details.appendChild(summary);
  const list = document.createElement('div');
  list.className = 'steps-summary-list';
  steps.forEach((action) => {
    list.appendChild(buildStepRow(action));
  });
  details.appendChild(list);
  return details;
}

function buildStepRow(action) {
  const { text, isError } = humanizeStep(action);
  const row = document.createElement('div');
  row.className = 'live-step' + (isError ? ' live-step-error' : '');
  const textSpan = document.createElement('span');
  textSpan.className = 'live-step-text';
  textSpan.textContent = text;
  row.appendChild(textSpan);
  return row;
}

function buildQuestionCard(data) {
  const card = document.createElement('div');
  card.className = 'question-card';

  const title = document.createElement('div');
  title.className = 'question-title';
  title.textContent = data.question || '';
  card.appendChild(title);

  const optionsList = document.createElement('div');
  optionsList.className = 'question-options';
  const inputType = data.multiSelect ? 'checkbox' : 'radio';
  data.options.forEach((opt, i) => {
    const label = document.createElement('label');
    label.className = 'question-option';
    const input = document.createElement('input');
    input.type = inputType;
    input.name = 'question-option-group';
    input.value = opt.label;
    label.appendChild(input);
    const textWrap = document.createElement('span');
    const strong = document.createElement('strong');
    strong.textContent = opt.label;
    textWrap.appendChild(strong);
    if (opt.description) {
      const desc = document.createElement('span');
      desc.className = 'question-option-desc';
      desc.textContent = ' — ' + opt.description;
      textWrap.appendChild(desc);
    }
    label.appendChild(textWrap);
    optionsList.appendChild(label);
  });
  card.appendChild(optionsList);

  const customInput = document.createElement('input');
  customInput.type = 'text';
  customInput.placeholder = 'O escribí tu propia respuesta…';
  customInput.className = 'question-custom-input';
  card.appendChild(customInput);

  const submitBtn = document.createElement('button');
  submitBtn.className = 'question-submit';
  submitBtn.textContent = 'Responder';
  submitBtn.addEventListener('click', () => {
    const chosen = [...optionsList.querySelectorAll('input:checked')].map((i) => i.value);
    const custom = customInput.value.trim();
    const parts = [...chosen];
    if (custom) parts.push(custom);
    if (parts.length === 0) return;
    card.querySelectorAll('input, button').forEach((el) => { el.disabled = true; });
    sendCurrentMessage(parts.join(', '));
  });
  card.appendChild(submitBtn);

  return card;
}

function closeModal() {
  document.getElementById('modal-overlay').classList.add('hidden');
}

function baseModal(title) {
  const overlay = document.getElementById('modal-overlay');
  const body = document.getElementById('modal-body');
  const actions = document.getElementById('modal-actions');
  document.getElementById('modal-title').textContent = title;
  body.innerHTML = '';
  actions.innerHTML = '';
  overlay.classList.remove('hidden');
  return { overlay, body, actions };
}

function addModalButton(actions, label, primary, onClick) {
  const btn = document.createElement('button');
  btn.textContent = label;
  if (primary) btn.className = 'primary';
  btn.addEventListener('click', onClick);
  actions.appendChild(btn);
  return btn;
}

// Modal de texto libre: usado para crear/renombrar carpetas. Resuelve con el
// string ingresado, o null si se cancela (Escape o botón Cancelar).
function textModal(title, defaultValue, confirmLabel) {
  return new Promise((resolve) => {
    const { overlay, body, actions } = baseModal(title);
    const input = document.createElement('input');
    input.type = 'text';
    input.value = defaultValue || '';
    body.appendChild(input);

    const finish = (value) => {
      overlay.removeEventListener('keydown', onKeydown);
      closeModal();
      resolve(value);
    };
    const onKeydown = (e) => {
      if (e.key === 'Enter') finish(input.value);
      if (e.key === 'Escape') finish(null);
    };
    overlay.addEventListener('keydown', onKeydown);

    addModalButton(actions, 'Cancelar', false, () => finish(null));
    addModalButton(actions, confirmLabel || 'Aceptar', true, () => finish(input.value));
    setTimeout(() => { input.focus(); input.select(); }, 0);
  });
}

// Modal para elegir una carpeta destino (o crear una nueva, o sacarla de
// carpetas). Reemplaza el viejo protocolo de texto libre basado en prompt().
// Resuelve con { type: 'clear' } | { type: 'assign', folderId } | null (cancelado).
function folderPickerModal(title, folders) {
  return new Promise((resolve) => {
    const { overlay, body, actions } = baseModal(title);

    const clearOpt = document.createElement('button');
    clearOpt.className = 'modal-option';
    clearOpt.textContent = 'Sin carpeta';
    clearOpt.addEventListener('click', () => finish({ type: 'clear' }));
    body.appendChild(clearOpt);

    for (const folder of folders) {
      const opt = document.createElement('button');
      opt.className = 'modal-option';
      opt.textContent = folder.name;
      opt.addEventListener('click', () => finish({ type: 'assign', folderId: folder.id }));
      body.appendChild(opt);
    }

    const newOpt = document.createElement('button');
    newOpt.className = 'modal-option';
    newOpt.textContent = '+ Nueva carpeta…';
    newOpt.addEventListener('click', async () => {
      finish(null, false);
      const nombre = await textModal('Nombre de la nueva carpeta', '', 'Crear');
      resolve(nombre && nombre.trim() ? { type: 'create', name: nombre.trim() } : null);
    });
    body.appendChild(newOpt);

    const finish = (value, doResolve = true) => {
      overlay.removeEventListener('keydown', onKeydown);
      closeModal();
      if (doResolve) resolve(value);
    };
    const onKeydown = (e) => { if (e.key === 'Escape') finish(null); };
    overlay.addEventListener('keydown', onKeydown);

    addModalButton(actions, 'Cancelar', false, () => finish(null));
  });
}

function appendLog(line) {
  const pre = document.getElementById('logs-content');
  pre.textContent += line + '\n';
  pre.scrollTop = pre.scrollHeight;
}

// Panel "Tareas" sacado (pedido del usuario, 2026-07-13) -- la narración de pasos en vivo en el
// chat ya cubre esa función, no hace falta duplicarla en un panel aparte.
//
// Bug real encontrado en el previsualizador (2026-07-13): antes solo mostraba contenido para
// read/write (podía releer el archivo del disco); para browse/mcp/gen/screen/control/delegate
// el resultado real vivía y moría DENTRO del proceso de nv-agent.sh -- nunca salía hacia la
// app, así que el usuario solo veía la etiqueta de la acción sin nada más. Fix: nv-agent.sh ahora
// manda una línea "[nv-agent] PREVIEW: <observación aplanada>" después de cada acción (ver
// nv-agent.sh), que se renderiza acá tal cual para todo lo que no sea un archivo real.
let lastPreviewIsFile = false;

// EL PANEL SE ABRE SOLO CUANDO HAY ALGO QUE MOSTRAR (2026-08-08).
//
// Esto es lo que hacía que la previsualización "nunca funcionara", y no era que no funcionara:
// el panel se llenaba bien y se quedaba CERRADO. #status-panel nace con la clase `collapsed`
// (que es display:none) y el único lugar de todo el archivo que la sacaba era
// renderScreenPreview -- o sea, sólo cuando había una captura de pantalla. Un `write` o un
// `read` escribían el contenido adentro de un cajón cerrado.
//
// Y no alcanzaba con abrirlo a mano después, porque al empezar cada turno se resetea a
// "Sin actividad todavía en este turno": para cuando el usuario apretaba el ojo, lo que quería ver ya
// no estaba. Tres días de "esto no anda" por una clase CSS.
//
// Se abre UNA sola vez por turno y sólo si el usuario no lo cerró a propósito: si lo cierra en el medio,
// no se lo volvemos a abrir en la cara a cada paso.
let panelAbiertoEsteTurno = false;
let panelCerradoPorJuan = false;

function abrirPanelSiHaceFalta() {
  if (panelCerradoPorJuan) return;
  const panel = document.getElementById('status-panel');
  if (!panel || !panel.classList.contains('collapsed')) return;
  panel.classList.remove('collapsed');
  panelAbiertoEsteTurno = true;
}

function handleAgentLogLine(line) {
  const pres = line.match(PRESUPUESTO_LOG_RE);
  if (pres) { pasosTotales = parseInt(pres[1], 10) || 0; actualizarProgreso(0); return; }

  const taskMatch = line.match(TASK_LOG_RE);
  if (taskMatch) {
    const action = taskMatch[1];
    appendLiveStep(action);
    // El número de iteración viaja en la misma línea que ya se parsea: "iter 3: write x.txt".
    const nro = line.match(/^\[nv-agent\] iter (\d+):/);
    if (nro) actualizarProgreso(parseInt(nro[1], 10));
    abrirPanelSiHaceFalta();
    const readMatch = action.match(/^read (.+)$/);
    const writeMatch = action.match(/^write (.+)$/);
    if (readMatch || writeMatch) {
      lastPreviewIsFile = true;
      renderFilePreview(action, readMatch ? readMatch[1] : writeMatch[1], !!writeMatch);
    } else {
      lastPreviewIsFile = false;
      renderPreviewLabel(action);
    }
    return;
  }
  if (!lastPreviewIsFile) {
    const previewMatch = line.match(PREVIEW_LOG_RE);
    if (previewMatch) { abrirPanelSiHaceFalta(); renderRawPreview(previewMatch[1]); }
  }
}

// PROGRESO: "paso 3 de 10" (2026-08-08, pedido del usuario).
// Es lo único de las cuatro cosas que pidió que no existía de ninguna forma. El motor siempre
// supo en qué iteración iba y cuál era su presupuesto; nunca lo decía. La cuenta no es tiempo
// restante -- eso sería inventar -- sino cuántos pasos le quedan antes de quedarse sin margen.
let pasosTotales = 0;

function actualizarProgreso(actual) {
  const el = document.getElementById('status-progreso');
  if (!el) return;
  if (!pasosTotales) { el.textContent = actual ? `paso ${actual}` : ''; return; }
  el.textContent = actual ? `paso ${actual} de ${pasosTotales}` : `hasta ${pasosTotales} pasos`;
  // Cuando quedan dos o menos, se avisa: es la señal de que puede cortar sin terminar.
  el.classList.toggle('cerca-del-limite', actual > 0 && (pasosTotales - actual) <= 2);
}

function renderPreviewLabel(action) {
  const content = document.getElementById('preview-content');
  content.innerHTML = '';
  const label = document.createElement('div');
  label.className = 'preview-action';
  label.textContent = action;
  content.appendChild(label);
}

function renderRawPreview(text) {
  const content = document.getElementById('preview-content');
  const pre = document.createElement('pre');
  pre.textContent = text && text.trim() ? text : '(sin contenido)';
  content.appendChild(pre);
}

// Narración en vivo: cada acción de nv-agent.sh aparece como un paso propio en la
// conversación, arriba del spinner, mientras el turno todavía está en curso.
function appendLiveStep(action) {
  const steps = document.getElementById('live-steps');
  if (!steps) return;
  steps.appendChild(buildStepRow(action));
  const container = document.getElementById('messages');
  container.scrollTop = container.scrollHeight;
}

// Muestra en el panel de previsualización qué está tocando Mentis ahora mismo:
// la acción tal cual la reporta nv-agent.sh y, si es un read/write con ruta,
// el contenido actual de ese archivo dentro del workspace de la app.
// Cache del último contenido conocido de cada archivo (relPath -> texto), viva
// durante toda la sesión de la app (el workspace es compartido entre
// conversaciones). Permite mostrar un diff real cuando un "write" vuelve a
// tocar un archivo que ya habíamos visto antes.
const filePreviewCache = new Map();

async function renderFilePreview(action, relPath, isWrite) {
  renderPreviewLabel(action);
  const content = document.getElementById('preview-content');

  const newContent = await window.mentisAPI.readWorkspaceFile(relPath);
  if (newContent === null) return;
  const oldContent = filePreviewCache.get(relPath);
  filePreviewCache.set(relPath, newContent);

  if (isWrite && oldContent !== undefined && oldContent !== newContent) {
    content.appendChild(buildDiffView(oldContent, newContent));
  } else {
    const pre = document.createElement('pre');
    pre.textContent = newContent;
    content.appendChild(pre);
  }
}

// Computer-use en vivo (pedido del usuario, 2026-07-16): reusa el panel de "Previsualización" que
// ya existe (mismo lugar donde se ve un read/write de archivo) en vez de inventar una ventanita
// nueva -- cuando 'screen'/'control' sacan una captura, se agrega la imagen debajo de la
// etiqueta de acción que ya puso renderPreviewLabel(). Se abre el panel solo si estaba
// colapsado, para que el usuario la vea sin tener que acordarse de abrirlo él mismo.
function renderScreenPreview(imgPath) {
  const content = document.getElementById('preview-content');
  const img = document.createElement('img');
  img.className = 'preview-screenshot';
  img.src = 'file://' + imgPath.replace(/\\/g, '/') + '?t=' + Date.now();
  img.alt = 'Lo que ve/hace Mentis en tu pantalla ahora';
  content.appendChild(img);
  document.getElementById('status-panel').classList.remove('collapsed');
}

// Diff de líneas via LCS (programación dinámica). Los archivos que pasan por
// acá ya vienen truncados a 4000 caracteres (ver mentis:read-workspace-file en
// main.js), así que el costo O(n*m) es despreciable en la práctica.
function diffLines(oldText, newText) {
  const a = oldText.split('\n');
  const b = newText.split('\n');
  const n = a.length;
  const m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const result = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { result.push({ type: 'same', line: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { result.push({ type: 'del', line: a[i] }); i++; }
    else { result.push({ type: 'add', line: b[j] }); j++; }
  }
  while (i < n) { result.push({ type: 'del', line: a[i] }); i++; }
  while (j < m) { result.push({ type: 'add', line: b[j] }); j++; }
  return result;
}

function buildDiffView(oldText, newText) {
  const pre = document.createElement('pre');
  pre.className = 'preview-diff';
  for (const { type, line } of diffLines(oldText, newText)) {
    const div = document.createElement('div');
    div.className = 'diff-line diff-' + type;
    div.textContent = (type === 'add' ? '+ ' : type === 'del' ? '- ' : '  ') + line;
    pre.appendChild(div);
  }
  return pre;
}

/* ===== El cuerpo digital refleja lo que Mentis hace de verdad =====================
   (pedido del usuario, 2026-07-26: "la sinapsis conectada a Mentis, pero que no lo ralentice en
   absoluto".)

   Cómo se logra el costo cero: el cuerpo NO consulta nada ni le pregunta al motor. Se cuelga de
   eventos que YA existían y ya viajaban del motor a esta ventana:
     - setBusy()                -> PROCESSING / STANDBY
     - el audio de la voz       -> SPEAKING
     - onTurnError / frenado    -> ALERT
     - 'mentis:log' del motor   -> una sinapsis por cada paso real (write, exec, búsqueda...)
   Ni una llamada extra, ni un temporizador, ni un sondeo. Si el módulo del cuerpo no cargó
   (o falla), todas estas funciones no hacen nada y la app sigue igual que antes. */
// Se declara ACÁ y no junto al resto del código de voz (que vive 1800 líneas más abajo) porque
// setBusy lo lee, y con `let` una variable declarada después tira ReferenceError al usarla antes.
let hablando = false;

/* ===== Subtítulos en vivo del modo voz (pedido del usuario, 2026-07-26) ==================
   Dos líneas: lo que Mentis entendió que dijiste, y lo que está diciendo ahora.
   La del usuario resuelve un problema real: hablando no sabés si te entendió bien hasta que
   contesta, y ahí ya perdiste el turno. Verlo al instante te deja corregir en el acto. */
let temporizadorSubtitulo = null;

function mostrarSubtitulo(quien, texto) {
  const cont = document.getElementById('subtitulos-voz');
  const el = document.getElementById(quien === 'usuario' ? 'subtitulo-usuario' : 'subtitulo-mentis');
  if (!cont || !el) return;
  if (!voiceModeActive) return;   // fuera del modo voz no molestan
  cont.classList.remove('hidden');
  el.textContent = texto || '';
  el.classList.toggle('visible', !!texto);
}

function borrarSubtitulosAhora() {
  for (const id of ['subtitulo-usuario', 'subtitulo-mentis']) {
    const el = document.getElementById(id);
    if (el) { el.classList.remove('visible'); el.textContent = ''; }
  }
  const cont = document.getElementById('subtitulos-voz');
  if (cont) cont.classList.add('hidden');
}

function limpiarSubtitulos(demoraMs) {
  if (temporizadorSubtitulo) clearTimeout(temporizadorSubtitulo);
  // `demoraMs || 3000` (lo que había) convertía el 0 en 3000: apagar el modo voz pedía limpiar YA
  // y en realidad limpiaba tres segundos después. Con ?? el cero se respeta, y además se limpia
  // en el acto en vez de agendar un timer para dentro de nada.
  const demora = demoraMs ?? 3000;
  if (demora <= 0) { borrarSubtitulosAhora(); return; }
  temporizadorSubtitulo = setTimeout(borrarSubtitulosAhora, demora);
}

/* Va mostrando lo que Mentis dice a medida que lo dice. No hay marcas de tiempo por palabra
   (el TTS devuelve el audio entero), así que se reparte el texto sobre la duración real del
   audio: no es exacto palabra por palabra, pero acompaña el ritmo y no se adelanta al final.
   Si el audio se pausa o se corta, esto se detiene con él. */
let temporizadorKaraoke = null;

function subtitularMientrasHabla(texto, audio) {
  if (temporizadorKaraoke) clearInterval(temporizadorKaraoke);
  if (!texto || !voiceModeActive) return;
  const palabras = texto.split(/\s+/).filter(Boolean);
  if (!palabras.length) return;

  const pintar = () => {
    const dur = audio && isFinite(audio.duration) && audio.duration > 0 ? audio.duration : null;
    if (!dur) { mostrarSubtitulo('mentis', texto); return; }
    const avance = Math.min(1, (audio.currentTime || 0) / dur);
    const hasta = Math.max(1, Math.round(avance * palabras.length));
    mostrarSubtitulo('mentis', palabras.slice(0, hasta).join(' '));
  };
  temporizadorKaraoke = setInterval(() => {
    if (!audio || audio.paused || audio.ended) {
      if (audio && audio.ended) mostrarSubtitulo('mentis', texto);
      return;
    }
    pintar();
  }, 120);
}

function frenarKaraoke() {
  if (temporizadorKaraoke) { clearInterval(temporizadorKaraoke); temporizadorKaraoke = null; }
}

function cuerpoSetEstado(estado) {
  if (window.MentisCuerpo) window.MentisCuerpo.setEstado(estado);
}

// ===== El núcleo late con tu voz de verdad (Fase 4, 2026-07-27) =====
// Se cuelga del MISMO stream que ya abre getUserMedia para grabar: no pide un segundo micrófono
// ni una segunda autorización, y si el usuario corta la grabación el analizador muere con ella.
// Un AnalyserNode no toca el audio -- solo mira -- así que la grabación que va a Whisper sale
// idéntica a como salía antes.
let audioCtxNivel = null;
let rafNivel = null;
// Testigos de la última grabación: sirven para no mandarle al motor un audio en el que no se
// dijo nada. Cuando llega una transcripción sin sentido, el clasificador no la reconoce, la
// manda al loop agéntico, y volvés con un "no pude terminar la tarea" que no tiene NADA que ver
// con lo que pediste (pasó de verdad el 2026-07-27, ver ERR-077). Es más honesto -- y mucho más
// rápido -- decir "no te escuché" acá.
let nivelMaxGrabacion = 0;
let inicioGrabacion = 0;

// ===== FIN DE FRASE AUTOMÁTICO (VAD + End-of-Utterance, 2026-07-27) =====
// Hasta ahora hablarle a Mentis eran DOS toques: uno para empezar y otro para cortar. El segundo
// es el que rompe la ilusión -- nadie toca un botón para avisarle a una persona que terminó de
// hablar. Ahora Mentis se da cuenta solo: detecta que arrancaste a hablar y que dejaste de
// hacerlo, y corta él.
// No hace falta un modelo de VAD aparte: el medidor de nivel de la Fase 4 ya calcula el volumen
// cuadro por cuadro, así que la detección sale de algo que ya estaba corriendo.
// CALIBRACIÓN (2026-07-28): el 0,035 fijo era un número puesto a ojo, antes de que nadie le
// hubiera hablado a un micrófono. Un umbral fijo no puede estar bien: depende del micrófono, de
// la ganancia de Windows, de a qué distancia esté el usuario y del ruido de la pieza. Puesto muy bajo,
// el ventilador cuenta como voz y no corta nunca; muy alto, le corta la frase por la mitad.
// Ahora se calibra SOLO, en cada grabación: se mide el piso de ruido real de la sala (el mínimo
// que entra por el micrófono, que aparece siempre entre palabra y palabra) y la voz es lo que
// esté claramente por encima de ese piso. Se prefirió esto a un botón de "calibrar micrófono"
// porque una calibración que hay que acordarse de hacer -- y rehacer al cambiar de lugar o de
// micrófono -- es una que va a quedar desactualizada.
const VAD_FACTOR_DEFAULT = 3.5;    // cuánto más fuerte que el ruido de fondo tiene que ser la voz
const VAD_UMBRAL_MIN = 0.012;      // piso: por debajo de esto ni el silencio absoluto baja
const VAD_UMBRAL_MAX = 0.070;      // techo: con una sala muy ruidosa, no exigir un grito
let vadFactor = VAD_FACTOR_DEFAULT;
let VAD_SILENCIO_MS = 1100;        // silencio seguido que cierra la frase (ajustable en settings)
const VAD_MINIMO_HABLADO_MS = 350; // hay que haber hablado algo antes de que un silencio cuente
let vadPisoRuido = 0;              // mínimo móvil del RMS = el ruido de la sala, medido en vivo
let vadUmbralActual = 0.035;       // umbral efectivo (piso * factor, acotado) -- se ve en el diagnóstico
let vadDiagnostico = false;        // Ctrl+Shift+V: muestra nivel/umbral/piso en vivo
let vadHabloAlgunaVez = false;
let vadUltimaVozMs = 0;
let vadInicioVozMs = 0;
let vadActivo = true;              // se apaga solo si el micrófono no da niveles utilizables
let tempMaxGrabacion = null;       // corte por tiempo, red de seguridad si el VAD no dispara
// 15 minutos, y NO es un límite de mensaje: es el único seguro contra un micrófono que no entrega
// niveles (silenciado por hardware, ganancia en cero), caso en el que el VAD no dispararía nunca
// y la grabación quedaría abierta para siempre. Antes esto valía 45 s y sí cortaba mensajes
// reales -- era la mitad del bug que reportó el usuario el 2026-07-30.
const MAX_GRABACION_MS = 15 * 60 * 1000;
// Bandera propia en vez de mirar mediaRecorder.state: mediaRecorder se declara mucho más abajo
// con `let`, y consultarlo desde acá arriba entraría en su zona muerta temporal. Además esto
// dice lo que importa -- "el cuerpo está escuchando" -- que no es exactamente lo mismo que
// "hay un MediaRecorder grabando".
let escuchandoVoz = false;

// Las dos cuentas del VAD viven en funciones puras y no sueltas dentro del bucle de medición:
// así se pueden probar de verdad con números concretos, en vez de "probar" que la pantalla se
// montó y dar eso por bueno (el pecado que ya cometí en ERR-075).
function actualizarPisoRuido(pisoActual, rms) {
  if (!(pisoActual > 0)) return rms;      // primer cuadro: el piso arranca donde esté el micrófono
  if (rms < pisoActual) return rms;       // baja al instante: el silencio real manda
  return pisoActual + (rms - pisoActual) * 0.0005;  // sube muy lento: una frase larga no lo arrastra
}
function calcularUmbralVAD(pisoRuido, factor) {
  return Math.min(VAD_UMBRAL_MAX, Math.max(VAD_UMBRAL_MIN, pisoRuido * factor));
}

// --- MENSAJES LARGOS (bug real que reportó el usuario, 2026-07-30) ---------------------------------
// "El transcriptor no aguanta mensajes largos y se corta y envía."
//
// Eran DOS cortes distintos, y por eso parecía caprichoso:
//   1. un tope duro de 45 s, que mataba cualquier dictado largo aunque estuvieras hablando;
//   2. este VAD, que cerraba la frase a los 1100 ms de silencio -- o sea que una pausa para
//      pensar, en medio de una idea, mandaba el mensaje por la mitad.
//
// El 1 se fue (ahora la red de seguridad son 15 minutos y existe sólo para el caso en que el
// micrófono no entregue niveles utilizables). El 2 se arregla acá: la pausa que se tolera CRECE
// con lo que venís hablando. Un "sí, dale" de dos segundos se cierra tan rápido como siempre;
// un dictado de un minuto te deja respirar casi tres segundos antes de dar la idea por terminada.
//
// Por qué en función de lo hablado y no un valor fijo más grande: subir el fijo a 3 s haría que
// cada "gracias" tarde 3 segundos en cerrarse, y eso arruina la conversación corta, que es la
// mayoría. La duración de lo que venís diciendo es la mejor pista de si terminaste o respiraste.
const VAD_PAUSA_CORTA_DESDE_MS = 8000;   // hasta acá se comporta igual que siempre
const VAD_PAUSA_LARGA_HASTA_MS = 45000;  // de acá en adelante, tolerancia máxima
const VAD_PAUSA_TECHO_MS = 3000;         // lo máximo que se espera en un dictado largo
function pausaPermitidaMs(hablandoMs, base) {
  const piso = Number.isFinite(base) ? base : VAD_SILENCIO_MS;
  const techo = Math.max(piso, VAD_PAUSA_TECHO_MS);
  if (!(hablandoMs > VAD_PAUSA_CORTA_DESDE_MS)) return piso;
  if (hablandoMs >= VAD_PAUSA_LARGA_HASTA_MS) return techo;
  const avance = (hablandoMs - VAD_PAUSA_CORTA_DESDE_MS) / (VAD_PAUSA_LARGA_HASTA_MS - VAD_PAUSA_CORTA_DESDE_MS);
  return piso + (techo - piso) * avance;
}

// ¿Se terminó la frase? Predicado puro para poder probarlo con números en vez de con la boca.
function debeCortarFrase({ habloAlgunaVez, hablandoMs, silencioMs, base }) {
  if (!habloAlgunaVez) return false;
  if (hablandoMs < VAD_MINIMO_HABLADO_MS) return false;
  return silencioMs >= pausaPermitidaMs(hablandoMs, base);
}

// ¿Conviene cerrar un TRAMO y seguir grabando? (no termina el mensaje: lo parte para ir
// transcribiendo mientras seguís hablando). Sólo en un silencio y sólo si el tramo ya es largo:
// un mensaje corto se transcribe entero de una y no vale la pena partirlo.
const SEGMENTO_MIN_MS = 20000;           // antes de 20 s no se parte nada
const SEGMENTO_PAUSA_MIN_MS = 700;       // y sólo aprovechando un silencio real
function debeSegmentar({ tramoMs, silencioMs, cortando }) {
  if (cortando) return false;            // si ya se está cerrando la frase, no partir
  return tramoMs >= SEGMENTO_MIN_MS && silencioMs >= SEGMENTO_PAUSA_MIN_MS;
}

// Expuestas para los tests (y para poder mirarlas desde la consola si algo se comporta raro).
window.__mentisVAD = {
  actualizarPisoRuido, calcularUmbralVAD, pausaPermitidaMs, debeCortarFrase, debeSegmentar,
  limites: () => ({ min: VAD_UMBRAL_MIN, max: VAD_UMBRAL_MAX, factor: vadFactor, silencioMs: VAD_SILENCIO_MS,
                    pausaTecho: VAD_PAUSA_TECHO_MS, segmentoMin: SEGMENTO_MIN_MS, maxGrabacionMs: MAX_GRABACION_MS })
};

// Los ajustes de voz se leen una vez al arrancar. Si falla la lectura (settings corrupto, IPC
// caído) se sigue con los valores por defecto: que no se pueda leer una preferencia no puede
// dejar a Mentis sin escuchar -- la voz es el único modo de hablarle.
async function cargarAjustesDeVoz() {
  try {
    const s = await window.mentisAPI.getSettings();
    if (s && s.voz) {
      if (Number.isFinite(Number(s.voz.silencioMs))) VAD_SILENCIO_MS = Number(s.voz.silencioMs);
      if (Number.isFinite(Number(s.voz.factorSensibilidad))) vadFactor = Number(s.voz.factorSensibilidad);
    }
  } catch (e) { /* con los defaults alcanza */ }
}
cargarAjustesDeVoz();

// Ctrl+Shift+V: modo diagnóstico del micrófono. Muestra en vivo el nivel que entra, el umbral
// calculado y el ruido de fondo medido. Es lo que hace falta para entender por qué corta antes
// de tiempo o por qué no corta -- sin esto, ajustar los números es adivinar.
window.addEventListener('keydown', (ev) => {
  if (ev.ctrlKey && ev.shiftKey && (ev.key === 'V' || ev.key === 'v')) {
    ev.preventDefault();
    vadDiagnostico = !vadDiagnostico;
    if (voiceStatus) {
      voiceStatus.textContent = vadDiagnostico
        ? 'Diagnóstico de micrófono ACTIVADO (Ctrl+Shift+V para salir)'
        : 'Tocá para hablar';
    }
  }
});

function arrancarMedidorDeVoz(stream) {
  frenarMedidorDeVoz();
  escuchandoVoz = true;
  nivelMaxGrabacion = 0;
  inicioGrabacion = Date.now();
  // Estado del fin-de-frase, limpio en cada grabación.
  vadHabloAlgunaVez = false;
  vadUltimaVozMs = 0;
  vadInicioVozMs = 0;
  vadActivo = true;
  vadPisoRuido = 0;                 // el ruido se vuelve a medir en cada grabación
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;                     // sin Web Audio, el cuerpo late solo con su respiración
    audioCtxNivel = new Ctx();
    const fuente = audioCtxNivel.createMediaStreamSource(stream);
    const analizador = audioCtxNivel.createAnalyser();
    // 1024 muestras: suficiente para un RMS estable y lo bastante corto para responder rápido.
    analizador.fftSize = 1024;
    fuente.connect(analizador);           // OJO: no se conecta a destination, o te escuchás en eco
    const muestras = new Float32Array(analizador.fftSize);

    const medir = () => {
      rafNivel = requestAnimationFrame(medir);
      analizador.getFloatTimeDomainData(muestras);
      let suma = 0;
      for (let i = 0; i < muestras.length; i++) suma += muestras[i] * muestras[i];
      const rms = Math.sqrt(suma / muestras.length);
      if (rms > nivelMaxGrabacion) nivelMaxGrabacion = rms;
      // Una voz normal a un palmo del micrófono da un RMS de 0,05 a 0,2. Dividir por 0,25 lleva
      // ese rango útil a 0-1 sin que haya que gritar para llegar al tope.
      if (window.MentisCuerpo) window.MentisCuerpo.setNivelVoz(rms / 0.25);

      // --- piso de ruido: el mínimo que entra cuando el usuario NO está hablando ---
      // Baja al instante (así aprende el silencio real apenas aparece) y sube muy de a poco (para
      // que una frase larga y sostenida no lo arrastre hacia arriba y termine tapando la voz).
      vadPisoRuido = actualizarPisoRuido(vadPisoRuido, rms);
      vadUmbralActual = calcularUmbralVAD(vadPisoRuido, vadFactor);

      if (vadDiagnostico && voiceStatus) {
        voiceStatus.textContent = `nivel ${rms.toFixed(3)} · umbral ${vadUmbralActual.toFixed(3)} · ruido ${vadPisoRuido.toFixed(3)}`;
      } else if (voiceStatus && escuchandoVoz) {
        // Reloj en vivo a partir de los 5 segundos. Sin esto, en un dictado largo no hay forma de
        // saber si te sigue escuchando o si se cortó calladito -- y era justo lo que pasaba.
        const llevaMs = Date.now() - inicioGrabacion;
        if (llevaMs >= 5000) {
          const seg = Math.floor(llevaMs / 1000);
          const tramos = tramosPendientes.length;
          voiceStatus.textContent = `Te escucho · ${Math.floor(seg / 60)}:${String(seg % 60).padStart(2, '0')}`
            + (tramos ? ` · ${tramos} tramo${tramos > 1 ? 's' : ''} ya transcribiéndose` : '');
        }
      }

      // --- fin de frase: Mentis corta solo cuando dejás de hablar ---
      if (vadActivo) {
        const ahora = Date.now();
        if (rms >= vadUmbralActual) {
          vadUltimaVozMs = ahora;
          if (!vadHabloAlgunaVez) { vadHabloAlgunaVez = true; vadInicioVozMs = ahora; }
        } else if (vadHabloAlgunaVez) {
          const hablandoMs = ahora - vadInicioVozMs;
          const silencioMs = ahora - vadUltimaVozMs;
          if (debeCortarFrase({ habloAlgunaVez: true, hablandoMs, silencioMs, base: VAD_SILENCIO_MS })) {
            // Se cortó la frase. Se apaga el VAD antes de parar para no dispararlo dos veces
            // (el bucle de medición sigue vivo unos cuadros más después del stop).
            vadActivo = false;
            if (!vadDiagnostico) voiceStatus.textContent = 'Listo, te escuché.';
            _mc_stopRecordingIfActive();
          } else if (debeSegmentar({ tramoMs: ahora - inicioTramo, silencioMs, cortando: false })) {
            // Dictado largo: se cierra el TRAMO en una pausa y se sigue grabando en el acto. Lo
            // que ya dijiste se va transcribiendo mientras seguís hablando, así al terminar no
            // esperás por todo junto (whisper 'base' tarda ~0,3 s por cada segundo de audio: dos
            // minutos de dictado serían ~35 s de espera si se hiciera al final, de una sola vez).
            cerrarTramoYSeguir();
          }
        }
      }
    };
    medir();
  } catch (e) {
    // Que falle el medidor no puede impedir grabar: el micrófono importa más que la animación.
    frenarMedidorDeVoz();
  }
}

function frenarMedidorDeVoz() {
  escuchandoVoz = false;
  vadActivo = false;
  if (tempMaxGrabacion) { clearTimeout(tempMaxGrabacion); tempMaxGrabacion = null; }
  if (rafNivel) { cancelAnimationFrame(rafNivel); rafNivel = null; }
  if (audioCtxNivel) {
    try { audioCtxNivel.close(); } catch (e) { /* ya estaba cerrado */ }
    audioCtxNivel = null;
  }
  // El nivel vence solo a los 300 ms, pero bajarlo acá hace que el núcleo se desinfle en el
  // mismo instante en que soltás el micrófono, sin ese cuarto de segundo de retardo.
  if (window.MentisCuerpo) window.MentisCuerpo.setNivelVoz(0);
}

function setBusy(busy) {
  turnInFlight = busy;
  // Trabajando o en reposo. Dos estados mandan sobre esto y no se pisan: SPEAKING mientras suena
  // la voz, y LISTENING mientras estás hablándole. Sin la segunda guarda, un turno anterior que
  // termina justo cuando apretás el micrófono apagaría el estado de escucha a mitad de frase.
  if (!hablando && !escuchandoVoz) cuerpoSetEstado(busy ? 'PROCESSING' : 'STANDBY');
  document.getElementById('btn-new-chat').disabled = busy;
  document.querySelectorAll('.conv-item').forEach((li) => {
    li.classList.toggle('disabled', busy);
  });
  // Botón Detener (pedido del usuario, 2026-07-16): visible solo mientras hay un turno en curso.
  document.getElementById('btn-stop-turn').classList.toggle('hidden', !busy);
}

async function refreshConversationList() {
  const [list, folders, projects] = await Promise.all([
    window.mentisAPI.listConversations(),
    window.mentisAPI.listFolders(),
    window.mentisAPI.listProjects()
  ]);
  foldersData = folders;
  const root = document.getElementById('conversation-list');
  root.innerHTML = '';

  // Proyectos primero (pedido del usuario, 2026-07-14): cada proyecto con SUS conversaciones,
  // visibles y clickeables directo desde el sidebar -- sin esto había que abrir el mosaico de
  // Proyectos para ver ese historial. Lo que ya está en un proyecto se saca del resto de abajo
  // (carpetas / sueltas) para no duplicarlo en dos grupos.
  //
  // OJO: inProjectIds sale de project.conversationIds (el índice), NO de filtrar `list` --
  // `list` (listConversations global) solo trae conversaciones con.jsonl YA escrito en disco,
  // así que una conversación de proyecto recién creada (todavía sin mensajes) desaparecía del
  // sidebar (mismo bug que ya se encontró y arregló en listProjectConversations -- acá hacía
  // falta el mismo fix, en otro lugar del código). Se reusa esa misma IPC (ya sintetiza una
  // entrada para las que no tienen archivo todavía) en vez de reimplementar el filtro.
  const inProjectIds = new Set();
  for (const project of projects) {
    for (const id of project.conversationIds || []) inProjectIds.add(id);
  }
  const projectConvLists = await Promise.all(
    projects.map((project) => window.mentisAPI.listProjectConversations(project.id))
  );
  for (let i = 0; i < projects.length; i++) {
    root.appendChild(renderProjectGroup(projects[i], projectConvLists[i]));
  }

  const remaining = list.filter((c) => !inProjectIds.has(c.id));
  const byFolder = new Map();
  const noFolder = [];
  for (const conv of remaining) {
    const fid = foldersData.assignments[conv.id];
    if (fid) {
      if (!byFolder.has(fid)) byFolder.set(fid, []);
      byFolder.get(fid).push(conv);
    } else {
      noFolder.push(conv);
    }
  }

  for (const folder of foldersData.folders) {
    root.appendChild(renderFolderGroup(folder.name, byFolder.get(folder.id) || [], folder.id));
  }
  root.appendChild(renderFolderGroup('Conversaciones sueltas', noFolder, null));
}

function renderProjectGroup(project, conversations) {
  const group = document.createElement('div');
  group.className = 'folder-group project-group';

  const header = document.createElement('div');
  header.className = 'folder-header';
  const key = 'proj:' + project.id;
  const collapsed = collapsedFolders.has(key);
  header.innerHTML = `<span>${collapsed ? '▸' : '▾'} ${project.name}</span>`;
  header.addEventListener('click', () => {
    if (collapsedFolders.has(key)) collapsedFolders.delete(key);
    else collapsedFolders.add(key);
    refreshConversationList();
  });
  group.appendChild(header);

  if (!collapsed) {
    for (const conv of conversations) group.appendChild(renderConversationItem(conv));
    const newTile = document.createElement('div');
    newTile.className = 'conv-item conv-item-new-in-project';
    newTile.textContent = '+ Nueva conversación acá';
    newTile.addEventListener('click', async () => {
      if (turnInFlight) return;
      const { conversationId } = await window.mentisAPI.createProjectConversation(project.id);
      await openConversation(conversationId);
    });
    group.appendChild(newTile);
  }
  return group;
}

function renderFolderGroup(name, conversations, folderId) {
  const group = document.createElement('div');
  group.className = 'folder-group';

  const header = document.createElement('div');
  header.className = 'folder-header';
  const collapsed = collapsedFolders.has(folderId || 'none');
  header.innerHTML = `<span>${collapsed ? '▸' : '▾'} ${name}</span>`;
  const actions = document.createElement('span');
  actions.className = 'folder-actions';
  if (folderId) {
    const renameBtn = document.createElement('button');
    renameBtn.textContent = 'renombrar';
    renameBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const nuevo = await textModal('Nuevo nombre de la carpeta', name, 'Renombrar');
      if (nuevo && nuevo.trim()) {
        await window.mentisAPI.renameFolder(folderId, nuevo.trim());
        await refreshConversationList();
      }
    });
    const delBtn = document.createElement('button');
    delBtn.textContent = 'eliminar';
    delBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      if (confirm(`¿Eliminar la carpeta "${name}"? Las conversaciones no se borran.`)) {
        await window.mentisAPI.deleteFolder(folderId);
        await refreshConversationList();
      }
    });
    actions.appendChild(renameBtn);
    actions.appendChild(delBtn);
  }
  header.appendChild(actions);
  header.addEventListener('click', () => {
    const key = folderId || 'none';
    if (collapsedFolders.has(key)) collapsedFolders.delete(key);
    else collapsedFolders.add(key);
    refreshConversationList();
  });
  group.appendChild(header);

  if (!collapsed) {
    for (const conv of conversations) {
      group.appendChild(renderConversationItem(conv));
    }
  }
  return group;
}

function renderConversationItem(conv) {
  const item = document.createElement('div');
  item.className = 'conv-item';
  if (conv.id === activeConversationId) item.classList.add('active');
  if (turnInFlight) item.classList.add('disabled');
  const label = document.createElement('span');
  label.textContent = conv.title;
  item.appendChild(label);

  const menuBtn = document.createElement('button');
  menuBtn.className = 'conv-menu-btn';
  menuBtn.textContent = '⋯';
  menuBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const result = await folderPickerModal(`Mover "${conv.title}" a…`, foldersData.folders);
    if (!result) return;
    if (result.type === 'clear') {
      await window.mentisAPI.assignFolder(conv.id, null);
    } else if (result.type === 'create') {
      const nuevaCarpeta = await window.mentisAPI.createFolder(result.name);
      await window.mentisAPI.assignFolder(conv.id, nuevaCarpeta.id);
    } else if (result.type === 'assign') {
      await window.mentisAPI.assignFolder(conv.id, result.folderId);
    }
    await refreshConversationList();
  });
  item.appendChild(menuBtn);

  item.addEventListener('click', () => {
    if (!turnInFlight) openConversation(conv.id);
  });
  return item;
}

// 2026-07-12 ("sin fronteras", pedido del usuario): navegar/MCP/generar/ver-pantalla vienen
// ACTIVOS por defecto (checkboxes tildados de entrada en el HTML) -- si el usuario destilda uno,
// mandamos el flag en MAYUSCULA que lo desactiva puntualmente (mentis-chat.sh: -B/-T/-G/-S).
// "Modo sin frenos" (-x) es la excepcion: sigue siendo opt-in (default destildado), con
// confirmacion explicita antes de poder tildarlo (ver wireDangerToggle).
// Computer-use (pedido del usuario, 2026-07-16): un solo checkbox gobierna DOS flags de
// mentis-chat.sh (screen + control) -- destildado (default) apaga las dos ('-S', screen
// arranca prendida sola así que hay que apagarla explícito); tildado prende control ('-c') y
// deja screen en su default prendido, sin mandar nada extra.
function currentFlags() {
  const flags = [];
  if (!document.getElementById('flag-b').checked) flags.push('-B');
  if (!document.getElementById('flag-t').checked) flags.push('-T');
  if (!document.getElementById('flag-g').checked) flags.push('-G');
  const computerUseOn = document.getElementById('flag-computer-use').checked;
  if (!computerUseOn) flags.push('-S');
  if (computerUseOn) flags.push('-c');
  if (!document.getElementById('flag-datos').checked) flags.push('-N');
  if (document.getElementById('flag-x').checked) flags.push('-x');
  if (document.getElementById('flag-a').checked) flags.push('-a');
  // El teléfono necesita SU bandera además del conector (las dos llaves): sin -p, mentis-chat.sh
  // no le pasa la herramienta al agente aunque el conector esté prendido.
  if (document.getElementById('flag-telefono').checked) flags.push('-p');
  return flags;
}

// ===== Protocolo de pérdida de contexto (pedido del usuario, 2026-07-13) =====
// mentis-chat.sh solo manda las últimas 20 entradas del historial como contexto en cada turno
// (_mc_tail_history 20) -- pasado ese punto, lo más viejo se pierde en silencio para el modelo,
// aunque el usuario lo siga viendo en pantalla. Umbral elegido con margen (24, no 20 justo) para
// avisar un poco ANTES de que se empiece a perder contexto, no después.
const HANDOFF_SUGGEST_THRESHOLD = 24;
const handoffDismissed = new Set();

function updateHandoffBanner(conversationId, entryCount) {
  const banner = document.getElementById('handoff-banner');
  const shouldShow = conversationId && entryCount >= HANDOFF_SUGGEST_THRESHOLD && !handoffDismissed.has(conversationId);
  banner.classList.toggle('hidden', !shouldShow);
}

async function runSummarizeAndHandoff() {
  if (!activeConversationId || turnInFlight) return;
  const handoffBtn = document.getElementById('btn-summarize-handoff');
  const acceptBtn = document.getElementById('btn-handoff-accept');
  const originalHandoffTitle = handoffBtn.title;
  handoffBtn.disabled = true;
  acceptBtn.disabled = true;
  handoffBtn.title = 'Resumiendo la conversación…';
  acceptBtn.textContent = 'Resumiendo…';
  try {
    const { newConversationId } = await window.mentisAPI.summarizeAndHandoff(activeConversationId);
    document.getElementById('handoff-banner').classList.add('hidden');
    await openConversation(newConversationId);
    await refreshConversationList();
  } catch (err) {
    appendErrorBubble(`No pude resumir y armar el chat nuevo: ${err && err.message ? err.message : err}`);
  } finally {
    handoffBtn.disabled = false;
    acceptBtn.disabled = false;
    handoffBtn.title = originalHandoffTitle;
    acceptBtn.textContent = 'Resumir y continuar';
  }
}

document.getElementById('btn-summarize-handoff').addEventListener('click', runSummarizeAndHandoff);
document.getElementById('btn-handoff-accept').addEventListener('click', runSummarizeAndHandoff);
document.getElementById('btn-handoff-dismiss').addEventListener('click', () => {
  if (activeConversationId) handoffDismissed.add(activeConversationId);
  document.getElementById('handoff-banner').classList.add('hidden');
});

async function updateHeaderProjectBadge(conversationId) {
  const badge = document.getElementById('header-project-badge');
  const project = conversationId ? await window.mentisAPI.projectForConversation(conversationId) : null;
  badge.innerHTML = '';
  if (project) {
    badge.appendChild(document.createTextNode(`Proyecto: ${project.name}`));
    // Flechita para salir del proyecto (pedido del usuario, 2026-07-14): arranca una conversación
    // nueva fuera de cualquier proyecto, sin tener que pasar por el mosaico de Proyectos.
    const exitBtn = document.createElement('button');
    exitBtn.type = 'button';
    exitBtn.id = 'btn-exit-project';
    exitBtn.setAttribute('aria-label', 'Salir del proyecto');
    exitBtn.title = 'Salir del proyecto (nueva conversación suelta)';
    exitBtn.innerHTML = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="13 6 19 12 13 18"/></svg>';
    exitBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      if (!turnInFlight) await openConversation(null);
    });
    badge.appendChild(exitBtn);
    badge.classList.remove('hidden');
  } else {
    badge.classList.add('hidden');
  }
}

async function openConversation(id) {
  // Lo que se dijo en la conversación anterior no tiene por qué seguir escrito en pantalla al
  // abrir otra: el subtítulo es el eco de ESTE turno, no un cartel permanente.
  borrarSubtitulosAhora();
  const result = await window.mentisAPI.openConversation(id, currentFlags());
  activeConversationId = result.id;
  renderMessagesWithBranches(result.entries);
  await refreshConversationList();
  await updateHeaderProjectBadge(result.id);
  updateHandoffBanner(result.id, result.entries.length);
}

// Botón Detener (pedido del usuario, 2026-07-16): mentis-chat.sh recién persiste el mensaje de
// el usuario al DISCO cuando el turno TERMINA (junto con la respuesta, ver _mc_append_history) -- no
// al enviarlo. Bug real encontrado probando el botón: si se frena a mitad de camino, casi
// siempre no hay nada que "popear" del archivo (el mensaje todavía no se escribió), así que el
// texto para restaurar en el cuadro tiene que rastrearse ACÁ, del lado del renderer, no confiar
// solo en lo que devuelva el backend.
let lastSentText = null;

async function sendCurrentMessage(text) {
  const trimmed = text.trim();
  if (!trimmed || turnInFlight) return;
  let finalText = trimmed;
  if (pendingAttachments.length > 0) {
    const tags = pendingAttachments.map((a) => `[archivo adjunto: ${a.relativePath}]`).join(' ');
    finalText = `${tags} ${trimmed}`;
  }
  lastSentText = finalText;
  setBusy(true);
  document.getElementById('preview-content').textContent = 'Sin actividad todavía en este turno.';
  // Turno nuevo, decisión nueva: si cerró el panel en el turno anterior, no se lo arrastramos.
  panelCerradoPorJuan = false;
  panelAbiertoEsteTurno = false;
  pasosTotales = 0;
  actualizarProgreso(0);
  if (!activeConversationId) {
    await openConversation(null);
  }
  await appendOptimisticBubble(finalText);
  showThinkingIndicator();
  await window.mentisAPI.sendMessage(finalText);
  pendingAttachments = [];
  renderAttachChips();
}

async function appendOptimisticBubble(text) {
  const container = document.getElementById('messages');
  const empty = document.getElementById('empty-state');
  if (empty) container.innerHTML = '';
  const { cleanText, paths } = extractAttachmentPaths(text);
  const div = document.createElement('div');
  div.className = 'bubble usuario';
  div.textContent = cleanText;
  // Fix 2026-07-15: root resuelto antes de tocar el DOM, thumb armado sincronico -- ver
  // renderMessages/buildMessageAttachmentThumbsSync (mismo fix del chat corriendose).
  if (paths.length > 0) {
    const root = await getWorkspaceRoot();
    const thumbRow = buildMessageAttachmentThumbsSync(root, paths);
    if (thumbRow) container.appendChild(thumbRow);
  }
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

let thinkingInterval = null;
let thinkingStart = null;

function showThinkingIndicator() {
  const container = document.getElementById('messages');
  const steps = document.createElement('div');
  steps.id = 'live-steps';
  container.appendChild(steps);

  const wrap = document.createElement('div');
  wrap.id = 'thinking-indicator';
  // El logo estático se retira también de acá (pedido del usuario, 2026-07-27: "el cuerpo digital
  // iba a ser el nuevo logo"). Mentis pensando ahora es el mismo núcleo, chico y en PROCESSING:
  // gira más rápido y dispara más sinapsis que en reposo, así que el indicador dice algo real
  // en vez de ser un logo con una animación de brillo encima.
  const lienzo = document.createElement('canvas');
  lienzo.id = 'thinking-cuerpo';
  lienzo.setAttribute('aria-label', 'Mentis está pensando');
  const timer = document.createElement('span');
  timer.id = 'thinking-timer';
  timer.textContent = '0.0s';
  wrap.appendChild(lienzo);
  wrap.appendChild(timer);
  container.appendChild(wrap);
  // Detalle bajo: a este tamaño no se distingue un anillo de 120 segmentos de uno de 48, y esto
  // corre justamente mientras el motor está ocupado. Se monta después de estar en el DOM para
  // que el canvas ya tenga su tamaño real.
  if (window.MentisCuerpo) {
    window.MentisCuerpo.montar('pensando', lienzo, { detalle: 'bajo', estado: 'PROCESSING', deriva: false });
  }
  container.scrollTop = container.scrollHeight;

  thinkingStart = Date.now();
  thinkingInterval = setInterval(() => {
    const elapsed = ((Date.now() - thinkingStart) / 1000).toFixed(1);
    timer.textContent = elapsed + 's';
  }, 100);
}

function hideThinkingIndicator() {
  if (thinkingInterval) {
    clearInterval(thinkingInterval);
    thinkingInterval = null;
  }
  // Desmontar ANTES de sacar el nodo: si se borra el canvas primero, queda la escena 3D viva
  // dibujando contra un elemento que ya no está en la página.
  if (window.MentisCuerpo) window.MentisCuerpo.desmontar('pensando');
  const el = document.getElementById('thinking-indicator');
  if (el) el.remove();
  // Normalmente renderMessages() ya limpió #live-steps al reconstruir #messages desde el
  // historial (onHistoryUpdated llega antes que turn-complete/turn-error) -- esto es solo la
  // red de seguridad para el caso turn-error, donde no hay history-updated que lo haga.
  const liveSteps = document.getElementById('live-steps');
  if (liveSteps) liveSteps.remove();
}

// Pinta el texto de Mentis con formato (negrita, cursiva, listas, codigo).
//
// El escapado de HTML lo hace formato.js ANTES de formatear -- ver el comentario de seguridad de
// ese archivo. Aca no se puede pasar innerHTML sin ese paso: el texto viene de un modelo que
// pudo haber leido cualquier pagina.
//
// Si el modulo todavia no cargo (se carga como <script type="module">, o sea despues), se pinta
// como texto plano: mostrar los asteriscos crudos es feo, no mostrar nada seria un bug.
function pintarFormateado(el, texto) {
  const f = window.MentisFormato;
  if (f && typeof f.formatearMensaje === 'function') {
    el.innerHTML = f.formatearMensaje(texto);
  } else {
    el.textContent = texto;
  }
}

function appendErrorBubble(text) {
  const container = document.getElementById('messages');
  const empty = document.getElementById('empty-state');
  if (empty) container.innerHTML = '';
  const div = document.createElement('div');
  div.className = 'bubble mentis error';
  div.textContent = text;
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

window.mentisAPI.onLog((line) => {
  appendLog(line);
  handleAgentLogLine(line);
  // SINAPSIS SOBRE ACTIVIDAD REAL: cada paso del motor (write, exec, búsqueda, navegación...)
  // enciende una conexión en el cuerpo. Este flujo de líneas YA existía para el panel de
  // progreso -- engancharse acá no le agrega ni una llamada al motor, que era la condición.
  if (window.MentisCuerpo && /^\[nv-agent\] iter \d+:/.test(line)) {
    const c = window.MentisCuerpo.get('voz') || window.MentisCuerpo.get('chat');
    if (c && typeof c.dispararSinapsis === 'function') c.dispararSinapsis();
  }
});
window.mentisAPI.onLivePreview((imgPath) => {
  renderScreenPreview(imgPath);
});

// RESPUESTA EN VIVO (2026-08-06). El motor ya escribia por chunks, pero la respuesta final viaja
// dentro de {"tool":"done","answer":"..."} y pintar los tokens crudos habria mostrado el JSON. Lo
// que llega aca ya viene des-escapado por nv_stream.py, trozo por trozo.
//
// La burbuja es PROVISORIA: cuando el turno cierra, onHistoryUpdated reconstruye #messages desde
// el historial guardado y esta se borra. Se dibuja aparte justamente para que la version buena --
// la que quedo en disco, con sus artefactos y su markdown -- sea siempre la que manda.
let streamBubble = null;
let streamTexto = '';
function limpiarBurbujaEnVivo() {
  if (streamBubble) streamBubble.remove();
  streamBubble = null;
  streamTexto = '';
}
window.mentisAPI.onAnswerChunk((trozo) => {
  const container = document.getElementById('messages');
  if (!container) return;
  if (!streamBubble) {
    // Se saca el "pensando..." recien con el PRIMER trozo: hasta que no llega texto de verdad,
    // seguir mostrandolo es lo correcto -- el modelo todavia esta pensando.
    hideThinkingIndicator();
    const empty = document.getElementById('empty-state');
    if (empty) container.innerHTML = '';
    streamBubble = document.createElement('div');
    streamBubble.className = 'bubble mentis streaming';
    container.appendChild(streamBubble);
    streamTexto = '';
  }
  streamTexto += trozo;
  // Se re-formatea el acumulado entero en cada trozo, no el trozo suelto: un **negrita** puede
  // llegar partido en varios chunks, y formatear pedazos daria asteriscos sueltos hasta que
  // cierre. El escapado de HTML sigue estando (lo hace formato.js primero).
  pintarFormateado(streamBubble, streamTexto);
  container.scrollTop = container.scrollHeight;
});
window.mentisAPI.onHistoryUpdated((entries) => {
  // La respuesta definitiva ya esta en el historial: la burbuja en vivo cumplio y se va. Primero
  // se borra y despues se re-renderiza, para que no se vea un instante duplicada.
  limpiarBurbujaEnVivo();
  renderMessagesWithBranches(entries);
  updateHandoffBanner(activeConversationId, entries ? entries.length : 0);
  if (voiceModeActive && entries && entries.length > 0) {
    const last = entries[entries.length - 1];
    if (last.role !== 'usuario' && last.text) {
      const parsed = parseQuestionBlock(last.text);
      let toSpeak = parsed ? parsed.before : last.text;
      // SEGUNDO CAMINO MUDO (arreglado 2026-07-27): cuando Mentis contesta SÓLO con un bloque de
      // opciones, sin texto antes, `before` queda vacío y no se decía nada -- justo cuando más
      // hace falta, porque te está preguntando algo y espera respuesta. Con el chat escrito las
      // opciones se leían en pantalla; hablando, Mentis se quedaba callado esperando.
      if (!toSpeak && parsed && parsed.data) {
        const pregunta = parsed.data.question || 'Tengo algunas opciones para vos';
        const opciones = parsed.data.options
.map((o) => (typeof o === 'string' ? o : (o && (o.label || o.text)) || ''))
.filter(Boolean);
        toSpeak = opciones.length ? `${pregunta}. Las opciones son: ${opciones.join(', ')}.` : pregunta;
      }
      if (toSpeak) speakText(toSpeak);
    }
  }
});
window.mentisAPI.onTurnComplete(() => {
  hideThinkingIndicator();
  setBusy(false);
  lastSentText = null;
});
window.mentisAPI.onTurnError(({ code }) => {
  hideThinkingIndicator();
  // Un turno que muere por error NO pasa por onHistoryUpdated, asi que la burbuja en vivo se
  // quedaria colgada en pantalla con media respuesta y pinta de definitiva.
  limpiarBurbujaEnVivo();
  const aviso = `El proceso de Mentis se cerró inesperadamente (code ${code}). Probá enviar de nuevo o abrí otra conversación.`;
  appendErrorBubble(aviso);
  // MENTIS MUDO ANTE UN ERROR (arreglado 2026-07-27): la respuesta hablada sale de
  // onHistoryUpdated, y un turno que muere por error NUNCA pasa por ahí. Con el chat escrito no
  // se notaba -- el error se leía en pantalla. Ahora que la voz es el único modo, el usuario le habla,
  // el turno se cae y Mentis se queda callado: parece que no lo escuchó.
  if (voiceModeActive) speakText('Se me cortó el turno. Probá de nuevo, por favor.');
  setBusy(false);
  lastSentText = null;
  // El cuerpo se pone en rojo: que un turno se corte se tiene que VER, no solo leer.
  cuerpoSetEstado('ALERT');
  setTimeout(() => { if (!turnInFlight && !hablando) cuerpoSetEstado('STANDBY'); }, 4000);
});

document.getElementById('btn-new-chat').addEventListener('click', () => {
  if (!turnInFlight) openConversation(null);
});
document.getElementById('btn-new-folder').addEventListener('click', async () => {
  const nombre = await textModal('Nombre de la nueva carpeta', '', 'Crear');
  if (nombre && nombre.trim()) {
    await window.mentisAPI.createFolder(nombre.trim());
    await refreshConversationList();
  }
});
// ===== Directorio (pedido del usuario, 2026-07-13): "Habilidades" (skills/plugins -- mismo
// mecanismo, Mentis no distingue entre los dos, ver abajo) y "Conectores" (VS Code, Git Bash,
// Terminal, Google Workspace). Reemplaza al viejo modal chico "Agregar plugin o skill". =====
const directoryOverlay = document.getElementById('directory-overlay');
const directoryGrid = document.getElementById('directory-grid');
const directorySearch = document.getElementById('directory-search');
const btnDirectoryAdd = document.getElementById('btn-directory-add');
let directoryTab = 'habilidades';
let connectorStatusCache = null;

function directoryCard(title, desc, dotOn) {
  const card = document.createElement('div');
  card.className = 'directory-card';
  const titleRow = document.createElement('div');
  titleRow.className = 'directory-card-title';
  if (dotOn !== undefined) {
    const dot = document.createElement('span');
    dot.className = 'directory-status-dot' + (dotOn ? ' on' : '');
    titleRow.appendChild(dot);
  }
  const titleText = document.createElement('span');
  titleText.textContent = title;
  titleRow.appendChild(titleText);
  card.appendChild(titleRow);
  const descEl = document.createElement('div');
  descEl.className = 'directory-card-desc';
  descEl.textContent = desc;
  card.appendChild(descEl);
  return card;
}

function directoryEmpty(text) {
  const div = document.createElement('div');
  div.id = 'directory-empty';
  div.textContent = text;
  return div;
}

// Tarjeta de resultado de busqueda en el historial de chats (pedido del usuario, 2026-07-14): click
// abre esa conversacion de verdad (cierra Directorio y usa el mismo openConversation() del
// sidebar) -- distinto de directoryCard/connectorCard, no tiene switch ni descripcion fija.
function conversationSearchCard(item) {
  const card = document.createElement('div');
  card.className = 'directory-card directory-card-clickable';
  card.setAttribute('role', 'button');
  card.tabIndex = 0;
  const titleRow = document.createElement('div');
  titleRow.className = 'directory-card-title';
  const titleText = document.createElement('span');
  titleText.textContent = item.title;
  titleRow.appendChild(titleText);
  card.appendChild(titleRow);
  const descEl = document.createElement('div');
  descEl.className = 'directory-card-desc';
  descEl.textContent = item.snippet;
  card.appendChild(descEl);
  const open = async () => {
    closeDirectory();
    if (!turnInFlight) await openConversation(item.conversationId);
  };
  card.addEventListener('click', open);
  card.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } });
  return card;
}

async function renderDirectoryGrid() {
  directoryGrid.innerHTML = '';
  const query = directorySearch.value.trim().toLowerCase();
  if (directoryTab === 'habilidades') {
    btnDirectoryAdd.classList.remove('hidden');
    const items = capabilityCatalog.filter((c) =>
      !query || c.prefix.toLowerCase().includes(query) || c.description.toLowerCase().includes(query));
    if (items.length === 0) {
      directoryGrid.appendChild(directoryEmpty('Sin resultados.'));
      return;
    }
    items.forEach((item) => directoryGrid.appendChild(directoryCard(item.prefix, item.description)));
  } else if (directoryTab === 'conversaciones') {
    btnDirectoryAdd.classList.add('hidden');
    if (!query) {
      directoryGrid.appendChild(directoryEmpty('Escribí algo para buscar en tus conversaciones pasadas.'));
      return;
    }
    const results = await window.mentisAPI.searchConversations(query);
    if (results.length === 0) {
      directoryGrid.appendChild(directoryEmpty('Sin resultados.'));
      return;
    }
    results.forEach((item) => directoryGrid.appendChild(conversationSearchCard(item)));
  } else {
    btnDirectoryAdd.classList.add('hidden');
    // Conectores unificados (pedido del usuario, 2026-07-14): locales + MCP + API-key (Ideogram,
    // Runway) en UNA sola lista -- antes esto leía connectorStatus() (solo 3-4 locales
    // fijos), ahora usa la misma fuente que el popup de click-derecho del composer.
    if (!connectorStatusCache) connectorStatusCache = await window.mentisAPI.listAllConnectors();
    const items = connectorStatusCache.filter((c) =>
      !query || c.name.toLowerCase().includes(query) || c.detail.toLowerCase().includes(query));
    if (items.length === 0) {
      directoryGrid.appendChild(directoryEmpty('Sin resultados.'));
      return;
    }
    items.forEach((item) => directoryGrid.appendChild(connectorCard(item)));
  }
}

// Tarjeta de conector (distinta de directoryCard): agrega switch on/off real para todos los
// conectores togglables (pedido del usuario, 2026-07-14) -- la unica excepcion es Git Bash
// (toggleable: false), que es el sustrato donde corre el propio agente, sin una accion
// separada que apagar.
function connectorCard(item) {
  const card = document.createElement('div');
  card.className = 'directory-card';
  const titleRow = document.createElement('div');
  titleRow.className = 'directory-card-title';
  const dot = document.createElement('span');
  dot.className = 'directory-status-dot' + (item.connected === true ? ' on' : '');
  titleRow.appendChild(dot);
  const titleText = document.createElement('span');
  titleText.textContent = item.name;
  titleRow.appendChild(titleText);
  if (item.toggleable) {
    titleRow.appendChild(buildConnectorSwitch(item));
  }
  card.appendChild(titleRow);
  const descEl = document.createElement('div');
  descEl.className = 'directory-card-desc';
  descEl.textContent = item.detail;
  card.appendChild(descEl);
  return card;
}

function setDirectoryTab(tab) {
  directoryTab = tab;
  document.querySelectorAll('.directory-tab').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.tab === tab);
  });
  renderDirectoryGrid();
}

async function openDirectory() {
  directorySearch.value = '';
  connectorStatusCache = null;
  await loadCapabilityCatalog();
  setDirectoryTab('habilidades');
  directoryOverlay.classList.remove('hidden');
}

function closeDirectory() {
  directoryOverlay.classList.add('hidden');
}

document.getElementById('btn-open-directory').addEventListener('click', openDirectory);
document.getElementById('btn-close-directory').addEventListener('click', closeDirectory);
document.querySelectorAll('.directory-tab').forEach((btn) => {
  btn.addEventListener('click', () => setDirectoryTab(btn.dataset.tab));
});
directorySearch.addEventListener('input', renderDirectoryGrid);
// Crear skill nueva desde la UI (pedido del usuario, 2026-07-13): antes "+ Agregar" solo dejaba
// importar un.sh ya escrito a mano -- ahora primero pregunta el método.
function chooseAddSkillMethodModal() {
  return new Promise((resolve) => {
    const { overlay, body, actions } = baseModal('Agregar habilidad');
    const importOpt = document.createElement('button');
    importOpt.className = 'modal-option';
    importOpt.textContent = 'Importar un archivo.sh ya escrito';
    importOpt.addEventListener('click', () => finish('import'));
    body.appendChild(importOpt);
    const createOpt = document.createElement('button');
    createOpt.className = 'modal-option';
    createOpt.textContent = 'Crear una skill nueva acá mismo';
    createOpt.addEventListener('click', () => finish('create'));
    body.appendChild(createOpt);

    const finish = (value) => {
      overlay.removeEventListener('keydown', onKeydown);
      closeModal();
      resolve(value);
    };
    const onKeydown = (e) => { if (e.key === 'Escape') finish(null); };
    overlay.addEventListener('keydown', onKeydown);
    addModalButton(actions, 'Cancelar', false, () => finish(null));
  });
}

// Formulario de creación: prefijo (/nombre), descripción, y el cuerpo del script bash que corre
// cuando el usuario escribe ese prefijo en el chat (mismo contrato que cualquier capability existente
// -- recibe el resto del mensaje como "$1", puede llamar a ask-nvidia.sh, curl, etc.).
function createSkillModal() {
  return new Promise((resolve) => {
    const { overlay, body, actions } = baseModal('Crear skill nueva');

    const prefixInput = document.createElement('input');
    prefixInput.type = 'text';
    prefixInput.placeholder = 'Prefijo (ej. /traducir)';
    const descInput = document.createElement('input');
    descInput.type = 'text';
    descInput.placeholder = 'Descripción corta (para el catálogo y el autocomplete)';
    const bodyInput = document.createElement('textarea');
    bodyInput.placeholder = 'Qué hace la skill (script bash). El resto del mensaje llega en $1.\nEj: bash "$TOOLSDIR/ask-nvidia.sh" -r reason <<< "Traducí al inglés: $1"';
    bodyInput.rows = 6;
    bodyInput.className = 'modal-textarea';
    const status = document.createElement('div');
    status.className = 'capability-status';

    body.appendChild(prefixInput);
    body.appendChild(descInput);
    body.appendChild(bodyInput);
    body.appendChild(status);

    const finish = (value) => {
      overlay.removeEventListener('keydown', onKeydown);
      closeModal();
      resolve(value);
    };
    const onKeydown = (e) => { if (e.key === 'Escape') finish(null); };
    overlay.addEventListener('keydown', onKeydown);

    addModalButton(actions, 'Cancelar', false, () => finish(null));
    const createBtn = addModalButton(actions, 'Crear', true, async () => {
      status.textContent = '';
      status.className = 'capability-status';
      const result = await window.mentisAPI.createCapability({
        prefix: prefixInput.value.trim(), description: descInput.value.trim(), body: bodyInput.value
      });
      if (!result.ok) {
        status.textContent = result.error;
        status.className = 'capability-status error';
        return;
      }
      finish(result);
    });
    setTimeout(() => prefixInput.focus(), 0);
  });
}

btnDirectoryAdd.addEventListener('click', async () => {
  const method = await chooseAddSkillMethodModal();
  if (!method) return;
  let result;
  if (method === 'import') {
    result = await window.mentisAPI.pickCapability();
    if (!result) return;
  } else {
    result = await createSkillModal();
    if (!result) return;
  }
  if (!result.ok) {
    directoryGrid.innerHTML = '';
    directoryGrid.appendChild(directoryEmpty(result.error));
    return;
  }
  await loadCapabilityCatalog();
  renderDirectoryGrid();
});

// ===== Proyectos (pedido del usuario, 2026-07-13): mosaico de proyectos, cada uno con su propia
// carpeta real (Documents/Mentis/Proyectos/<nombre>/). Historial SCOPEADO por proyecto (pedido
// del usuario, aclarado el 2026-07-13: "el historial de chat incluido" se refería al de ESE
// proyecto) -- un proyecto puede tener VARIAS conversaciones propias; clickear un tile entra a
// una vista de detalle con solo esas, no al chat global. =====
const projectsOverlay = document.getElementById('projects-overlay');
const projectsGrid = document.getElementById('projects-grid');
const projectsTitle = document.getElementById('projects-title');
let projectsDetailId = null;

function showToast(text) {
  const toast = document.getElementById('toast');
  toast.textContent = text;
  toast.classList.remove('hidden');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => toast.classList.add('hidden'), 4500);
}

function formatProjectDate(iso) {
  try {
    return new Date(iso).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric' });
  } catch {
    return '';
  }
}

async function renderProjectsGrid() {
  projectsDetailId = null;
  projectsTitle.textContent = 'Proyectos';
  projectsGrid.innerHTML = '';
  const projects = await window.mentisAPI.listProjects();
  for (const project of projects) {
    // div, no button (pedido del usuario, 2026-07-14: agregar botón de borrar en cada tile -- un
    // botón real DENTRO de un <button> es HTML inválido, así que el tile pasa a ser clickeable
    // por rol/teclado en vez de <button> nativo).
    const tile = document.createElement('div');
    tile.className = 'project-tile';
    tile.setAttribute('role', 'button');
    tile.tabIndex = 0;
    const name = document.createElement('div');
    name.className = 'project-tile-name';
    name.textContent = project.name;
    const date = document.createElement('div');
    date.className = 'project-tile-date';
    date.textContent = formatProjectDate(project.createdAt);
    tile.appendChild(name);
    tile.appendChild(date);

    const deleteBtn = document.createElement('button');
    deleteBtn.type = 'button';
    deleteBtn.className = 'project-tile-delete';
    deleteBtn.setAttribute('aria-label', `Borrar proyecto ${project.name}`);
    deleteBtn.title = 'Borrar proyecto';
    deleteBtn.innerHTML = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>';
    deleteBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      // Auditoría de lógica (2026-07-14): borrar la carpeta real mientras hay una conversación
      // de ESTE proyecto activa borraría el directorio de trabajo debajo del proceso de
      // mentis-chat.sh en curso -- se bloquea, no se pregunta ni se intenta manejar el caso raro.
      if (activeConversationId && (project.conversationIds || []).includes(activeConversationId)) {
        appendErrorBubble(`No podés borrar "${project.name}" mientras estás adentro de una de sus conversaciones. Abrí otra conversación primero (podés usar la flecha del badge "Proyecto: ${project.name}") y volvé a intentarlo.`);
        return;
      }
      const confirmed = await confirmModal(
        'Borrar proyecto',
        `Esto borra "${project.name}" de Mentis Y su carpeta real en disco (${project.dir}), con todo lo que el usuario haya guardado adentro (Archivos/ y Referencias/). No se puede deshacer.\n\n¿Confirmás que querés borrarlo?`,
        'Sí, borrar todo'
      );
      if (!confirmed) return;
      const result = await window.mentisAPI.deleteProject(project.id);
      if (!result || !result.ok) {
        appendErrorBubble(`No pude borrar el proyecto "${project.name}".`);
        return;
      }
      if (!result.folderDeleted) {
        showToast(`"${project.name}" se sacó de Mentis, pero no pude borrar la carpeta real -- revisala a mano en ${project.dir}.`);
      }
      await renderProjectsGrid();
    });
    tile.appendChild(deleteBtn);

    tile.addEventListener('click', () => renderProjectDetail(project.id));
    tile.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); renderProjectDetail(project.id); }
    });
    projectsGrid.appendChild(tile);
  }
  const newTile = document.createElement('button');
  newTile.className = 'project-tile project-tile-new';
  newTile.type = 'button';
  const plus = document.createElement('div');
  plus.className = 'project-tile-new-plus';
  plus.textContent = '+';
  const label = document.createElement('div');
  label.textContent = 'Nuevo proyecto';
  newTile.appendChild(plus);
  newTile.appendChild(label);
  newTile.addEventListener('click', async () => {
    const nombre = await textModal('Nombre del proyecto', '', 'Crear');
    if (!nombre || !nombre.trim()) return;
    const project = await window.mentisAPI.createProject(nombre.trim());
    showToast(`Proyecto "${project.name}" creado en Documents\\Mentis\\Proyectos\\${project.slug}`);
    // Bug real encontrado con verificación en vivo (2026-07-13, mismo reclamo original del usuario
    // -- "parece que no se abre"): mostrar solo la vista de detalle (lista de conversaciones)
    // dejaba al usuario un click más lejos de poder escribir. Crear un proyecto tiene que abrir
    // directo SU primera conversación, igual que "Nueva conversación" -- la vista de detalle
    // queda para cuando reabre un proyecto YA existente desde el mosaico.
    closeProjects();
    if (!turnInFlight) await openConversation(project.conversationIds[0]);
  });
  projectsGrid.appendChild(newTile);
}

// Vista de detalle: SOLO las conversaciones de este proyecto (no el historial global), más un
// tile para arrancar una conversación nueva dentro del mismo proyecto.
async function renderProjectDetail(projectId) {
  projectsDetailId = projectId;
  const projects = await window.mentisAPI.listProjects();
  const project = projects.find((p) => p.id === projectId);
  if (!project) { await renderProjectsGrid(); return; }

  projectsTitle.innerHTML = '';
  const back = document.createElement('button');
  back.type = 'button';
  back.className = 'projects-back-btn';
  back.textContent = '← Proyectos';
  back.addEventListener('click', renderProjectsGrid);
  projectsTitle.appendChild(back);
  projectsTitle.appendChild(document.createTextNode(project.name));

  projectsGrid.innerHTML = '';
  const conversations = await window.mentisAPI.listProjectConversations(projectId);
  for (const conv of conversations) {
    const tile = document.createElement('button');
    tile.className = 'project-tile';
    tile.type = 'button';
    const name = document.createElement('div');
    name.className = 'project-tile-name';
    name.textContent = conv.title;
    const date = document.createElement('div');
    date.className = 'project-tile-date';
    date.textContent = formatProjectDate(conv.updatedAt);
    tile.appendChild(name);
    tile.appendChild(date);
    tile.addEventListener('click', async () => {
      closeProjects();
      if (!turnInFlight) await openConversation(conv.id);
    });
    projectsGrid.appendChild(tile);
  }
  const newTile = document.createElement('button');
  newTile.className = 'project-tile project-tile-new';
  newTile.type = 'button';
  const plus = document.createElement('div');
  plus.className = 'project-tile-new-plus';
  plus.textContent = '+';
  const label = document.createElement('div');
  label.textContent = 'Nueva conversación';
  newTile.appendChild(plus);
  newTile.appendChild(label);
  newTile.addEventListener('click', async () => {
    const { conversationId } = await window.mentisAPI.createProjectConversation(projectId);
    closeProjects();
    if (!turnInFlight) await openConversation(conversationId);
  });
  projectsGrid.appendChild(newTile);
}

async function openProjects() {
  await renderProjectsGrid();
  projectsOverlay.classList.remove('hidden');
}

function closeProjects() {
  projectsOverlay.classList.add('hidden');
}

document.getElementById('btn-open-projects').addEventListener('click', openProjects);
document.getElementById('btn-close-projects').addEventListener('click', closeProjects);

// ===== Tareas programadas (pedido del usuario, 2026-07-14): "todos los lunes a las 8am resumime
// el vault" -- corren solas, con el mismo agente completo de un chat normal, en su propia
// conversación agrupada bajo la carpeta "Tareas programadas" del sidebar. =====
const scheduleOverlay = document.getElementById('schedule-overlay');
const scheduleList = document.getElementById('schedule-list');
const DAY_OPTIONS = [
  { value: 1, label: 'lunes' }, { value: 2, label: 'martes' }, { value: 3, label: 'miércoles' },
  { value: 4, label: 'jueves' }, { value: 5, label: 'viernes' }, { value: 6, label: 'sábado' }, { value: 0, label: 'domingo' }
];

function scheduleTaskCard(task) {
  const card = document.createElement('div');
  card.className = 'directory-card schedule-card';

  const titleRow = document.createElement('div');
  titleRow.className = 'directory-card-title';
  const nameEl = document.createElement('span');
  nameEl.textContent = task.name;
  titleRow.appendChild(nameEl);
  titleRow.appendChild(buildToggleSwitch(task.enabled, task.name, async (checked) => {
    await window.mentisAPI.updateScheduledTask(task.id, { enabled: checked });
  }));
  card.appendChild(titleRow);

  const scheduleLine = document.createElement('div');
  scheduleLine.className = 'directory-card-desc';
  scheduleLine.textContent = task.scheduleLabel;
  card.appendChild(scheduleLine);

  const promptLine = document.createElement('div');
  promptLine.className = 'directory-card-desc';
  promptLine.textContent = `"${task.prompt}"`;
  card.appendChild(promptLine);

  if (task.lastRunAt) {
    const lastLine = document.createElement('div');
    lastLine.className = 'directory-card-desc schedule-card-last';
    const when = new Date(task.lastRunAt).toLocaleString('es-AR');
    lastLine.textContent = `Última corrida: ${when}${task.lastResult ? ' — ' + task.lastResult : ''}`;
    card.appendChild(lastLine);
  }

  const actionsRow = document.createElement('div');
  actionsRow.className = 'schedule-card-actions';
  if (task.conversationId) {
    const openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.textContent = 'Ver conversación';
    openBtn.addEventListener('click', async () => {
      closeSchedule();
      if (!turnInFlight) await openConversation(task.conversationId);
    });
    actionsRow.appendChild(openBtn);
  }
  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = 'Eliminar';
  deleteBtn.addEventListener('click', async () => {
    const ok = await confirmModal('Eliminar tarea programada', `¿Eliminar "${task.name}"? Esto no borra la conversación que ya generó, solo deja de programarse.`, 'Eliminar');
    if (!ok) return;
    await window.mentisAPI.deleteScheduledTask(task.id);
    renderScheduleList();
  });
  actionsRow.appendChild(deleteBtn);
  card.appendChild(actionsRow);

  return card;
}

// Switch generico reusable (mismo look que buildConnectorSwitch, pero sin depender de un objeto
// "connector" -- lo usan tanto conectores como tareas programadas).
function buildToggleSwitch(checked, label, onChange) {
  const wrap = document.createElement('label');
  wrap.className = 'connector-switch';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.checked = checked;
  input.setAttribute('aria-label', `Activar/desactivar ${label}`);
  input.addEventListener('change', async () => {
    input.disabled = true;
    try { await onChange(input.checked); } finally { input.disabled = false; }
  });
  const track = document.createElement('span');
  track.className = 'connector-switch-track';
  wrap.appendChild(input);
  wrap.appendChild(track);
  return wrap;
}

async function renderScheduleList() {
  const tasks = await window.mentisAPI.listScheduledTasks();
  scheduleList.innerHTML = '';
  if (tasks.length === 0) {
    scheduleList.appendChild(directoryEmpty('Todavía no programaste ninguna tarea.'));
    return;
  }
  tasks.forEach((task) => scheduleList.appendChild(scheduleTaskCard(task)));
}

function scheduleFormFields(body) {
  const nameInput = document.createElement('input');
  nameInput.type = 'text';
  nameInput.placeholder = 'Nombre (ej. Resumen matutino del vault)';
  body.appendChild(nameInput);

  const promptInput = document.createElement('textarea');
  promptInput.placeholder = 'Qué querés que Mentis haga (el prompt que recibiría en un chat normal)';
  promptInput.rows = 3;
  body.appendChild(promptInput);

  const typeSelect = document.createElement('select');
  [['daily', 'Todos los días'], ['weekly', 'Un día específico de la semana'], ['interval', 'Cada N minutos']]
.forEach(([value, label]) => {
      const opt = document.createElement('option');
      opt.value = value; opt.textContent = label;
      typeSelect.appendChild(opt);
    });
  body.appendChild(typeSelect);

  const dayRow = document.createElement('div');
  dayRow.id = 'schedule-form-day-row';
  const daySelect = document.createElement('select');
  DAY_OPTIONS.forEach(({ value, label }) => {
    const opt = document.createElement('option');
    opt.value = value; opt.textContent = label;
    daySelect.appendChild(opt);
  });
  dayRow.appendChild(daySelect);
  body.appendChild(dayRow);

  const timeRow = document.createElement('div');
  timeRow.id = 'schedule-form-time-row';
  const timeInput = document.createElement('input');
  timeInput.type = 'time';
  timeInput.value = '08:00';
  timeRow.appendChild(timeInput);
  body.appendChild(timeRow);

  const intervalRow = document.createElement('div');
  intervalRow.id = 'schedule-form-interval-row';
  const intervalInput = document.createElement('input');
  intervalInput.type = 'number';
  intervalInput.min = '5';
  intervalInput.step = '5';
  intervalInput.value = '60';
  intervalInput.placeholder = 'Minutos';
  intervalRow.appendChild(intervalInput);
  const intervalLabel = document.createElement('span');
  intervalLabel.textContent = ' minutos';
  intervalRow.appendChild(intervalLabel);
  body.appendChild(intervalRow);

  const syncVisibility = () => {
    dayRow.classList.toggle('hidden', typeSelect.value !== 'weekly');
    timeRow.classList.toggle('hidden', typeSelect.value === 'interval');
    intervalRow.classList.toggle('hidden', typeSelect.value !== 'interval');
  };
  typeSelect.addEventListener('change', syncVisibility);
  syncVisibility();

  return {
    getValues() {
      const [hour, minute] = timeInput.value.split(':').map(Number);
      let schedule;
      if (typeSelect.value === 'daily') schedule = { type: 'daily', hour, minute };
      else if (typeSelect.value === 'weekly') schedule = { type: 'weekly', dayOfWeek: Number(daySelect.value), hour, minute };
      else schedule = { type: 'interval', everyMinutes: Number(intervalInput.value) };
      return { name: nameInput.value.trim(), prompt: promptInput.value.trim(), schedule };
    },
    focus() { nameInput.focus(); }
  };
}

function openNewScheduleTaskModal() {
  const { overlay, body, actions } = baseModal('Nueva tarea programada');
  const form = scheduleFormFields(body);
  const errorEl = document.createElement('div');
  errorEl.id = 'schedule-form-error-msg';
  errorEl.className = 'hidden';
  body.appendChild(errorEl);

  const finish = () => { overlay.removeEventListener('keydown', onKeydown); closeModal(); };
  const onKeydown = (e) => { if (e.key === 'Escape') finish(); };
  overlay.addEventListener('keydown', onKeydown);

  addModalButton(actions, 'Cancelar', false, finish);
  addModalButton(actions, 'Crear', true, async () => {
    const payload = form.getValues();
    const result = await window.mentisAPI.createScheduledTask(payload);
    if (!result.ok) {
      errorEl.textContent = result.error;
      errorEl.classList.remove('hidden');
      return;
    }
    finish();
    renderScheduleList();
  });
  setTimeout(() => form.focus(), 0);
}

async function openSchedule() {
  await renderScheduleList();
  scheduleOverlay.classList.remove('hidden');
}

function closeSchedule() {
  scheduleOverlay.classList.add('hidden');
}

document.getElementById('btn-open-schedule').addEventListener('click', openSchedule);
document.getElementById('btn-close-schedule').addEventListener('click', closeSchedule);
document.getElementById('btn-new-scheduled-task').addEventListener('click', openNewScheduleTaskModal);

// Una tarea programada corrió sola en segundo plano -- si el modal está abierto, refresca la
// lista; si no, no hace falta nada (el sidebar ya se actualiza solo la próxima vez que el usuario lo mire).
window.mentisAPI.onScheduledTaskRan(() => {
  if (!scheduleOverlay.classList.contains('hidden')) renderScheduleList();
  refreshConversationList();
});

// ===== Configuración (pedido del usuario, 2026-07-13): perfil, memoria adaptativa, modelos
// personalizados por rol + tema visual. Las API keys nunca pasan por acá en texto plano mas de
// lo necesario para mandarlas una vez al guardar -- main.js las separa a un archivo de secretos
// aparte. =====
const settingsOverlay = document.getElementById('settings-overlay');
const settingsModelsList = document.getElementById('settings-models-list');

const ROLE_LABELS = {
  code: 'Código', reason: 'Razonamiento', deep: 'Razonamiento profundo', general: 'General',
  extract: 'Extracción', multimodal: 'Multimodal (imágenes)', ultra: 'Ultra (máximo)'
};
const PROVIDER_LABELS = {
  'openai-compatible': 'OpenAI-compatible',
  anthropic: 'Anthropic (guardado, no wireado)',
  gemini: 'Gemini (guardado, no wireado)'
};

// Feedback de guardado inequívoco (pedido del usuario, 2026-07-13): el botón cambia de texto/color
// un momento en vez de depender solo de un estado que se podía pasar por alto. Reusable para
// cualquier "Guardar" de Configuración.
function flashSaveOk(btn, label) {
  const original = btn.textContent;
  btn.textContent = label || 'Guardado ✓';
  btn.classList.add('save-flash-ok');
  setTimeout(() => {
    btn.textContent = original;
    btn.classList.remove('save-flash-ok');
  }, 1800);
}

// ----- Modelos por rol: lista de acordeón (pedido del usuario, 2026-07-13) -----
// Reemplaza el form siempre expuesto (selects/inputs a la vista todo el tiempo) por una fila
// compacta POR ROL (los 7, configurados o no); clickear una fila expande su propio form inline.
let openRoleRow = null;

function buildRoleForm(role, cm) {
  const form = document.createElement('div');
  form.className = 'cm-row-form';

  const providerSelect = document.createElement('select');
  for (const [value, label] of Object.entries(PROVIDER_LABELS)) {
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = label;
    providerSelect.appendChild(opt);
  }
  if (cm) providerSelect.value = cm.provider;

  const baseUrlInput = document.createElement('input');
  baseUrlInput.type = 'text';
  baseUrlInput.placeholder = 'URL base (ej. https://api.openai.com/v1/chat/completions)';
  if (cm) baseUrlInput.value = cm.baseUrl;

  const modelInput = document.createElement('input');
  modelInput.type = 'text';
  modelInput.placeholder = 'Nombre del modelo (ej. gpt-4o)';
  if (cm) modelInput.value = cm.model;

  const apiKeyInput = document.createElement('input');
  apiKeyInput.type = 'password';
  apiKeyInput.placeholder = cm && cm.hasKey ? 'API key (guardada -- dejar vacío para no cambiarla)' : 'API key';

  const actions = document.createElement('div');
  actions.className = 'cm-row-form-actions';
  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.className = 'cm-save';
  saveBtn.textContent = 'Guardar';
  saveBtn.addEventListener('click', async () => {
    const baseUrl = baseUrlInput.value.trim();
    const model = modelInput.value.trim();
    if (!baseUrl || !model) return;
    await window.mentisAPI.saveCustomModel({
      role, provider: providerSelect.value, baseUrl, model, apiKey: apiKeyInput.value
    });
    flashSaveOk(saveBtn);
    openRoleRow = role;
    await renderSettingsModelsList();
  });
  actions.appendChild(saveBtn);

  if (cm) {
    const removeBtn = document.createElement('button');
    removeBtn.type = 'button';
    removeBtn.className = 'cm-remove';
    removeBtn.textContent = 'Quitar';
    removeBtn.addEventListener('click', async () => {
      await window.mentisAPI.removeCustomModel(role);
      openRoleRow = null;
      await renderSettingsModelsList();
    });
    actions.appendChild(removeBtn);
  }

  form.appendChild(providerSelect);
  form.appendChild(baseUrlInput);
  form.appendChild(modelInput);
  form.appendChild(apiKeyInput);
  form.appendChild(actions);
  return form;
}

async function renderSettingsModelsList() {
  const settings = await window.mentisAPI.getSettings();
  const customModels = settings.customModels || {};
  settingsModelsList.innerHTML = '';
  for (const [role, label] of Object.entries(ROLE_LABELS)) {
    const cm = customModels[role];
    const row = document.createElement('div');
    row.className = 'cm-row' + (openRoleRow === role ? ' open' : '');

    const header = document.createElement('button');
    header.type = 'button';
    header.className = 'cm-row-header';
    const name = document.createElement('span');
    name.className = 'cm-row-name';
    name.textContent = label;
    const badge = document.createElement('span');
    badge.className = 'cm-row-badge' + (cm ? ' configured' : '');
    badge.textContent = cm
      ? `Configurado — ${cm.provider} — ${cm.model}${cm.hasKey ? '' : ' (sin key)'}`
      : 'NIM de fábrica';
    header.appendChild(name);
    header.appendChild(badge);
    header.addEventListener('click', () => {
      openRoleRow = openRoleRow === role ? null : role;
      renderSettingsModelsList();
    });
    row.appendChild(header);
    row.appendChild(buildRoleForm(role, cm));
    settingsModelsList.appendChild(row);
  }
}

async function renderIdeogramStatus() {
  const status = await window.mentisAPI.getIdeogramStatus();
  const statusEl = document.getElementById('ideogram-status');
  statusEl.innerHTML = '';
  const dot = document.createElement('span');
  dot.className = 'key-status-dot' + (status.hasKey ? ' on' : '');
  const text = document.createElement('span');
  text.textContent = status.hasKey ? 'API key guardada y activa.' : 'Sin API key guardada todavía.';
  statusEl.classList.toggle('on', status.hasKey);
  statusEl.appendChild(dot);
  statusEl.appendChild(text);
}

async function renderRunwayStatus() {
  const status = await window.mentisAPI.getRunwayStatus();
  const statusEl = document.getElementById('runway-status');
  statusEl.innerHTML = '';
  const dot = document.createElement('span');
  dot.className = 'key-status-dot' + (status.hasKey ? ' on' : '');
  const text = document.createElement('span');
  text.textContent = status.hasKey ? 'API key guardada y activa.' : 'Sin API key guardada todavía.';
  statusEl.classList.toggle('on', status.hasKey);
  statusEl.appendChild(dot);
  statusEl.appendChild(text);
}

// ----- Perfil (pedido del usuario, 2026-07-13) -----
const profileAvatarImg = document.getElementById('profile-avatar-img');
const profileAvatarFallback = document.getElementById('profile-avatar-fallback');
const profileFullnameInput = document.getElementById('profile-fullname');
const profileNicknameInput = document.getElementById('profile-nickname');
const profileRoleSelect = document.getElementById('profile-role');
const profileRoleCustomInput = document.getElementById('profile-role-custom');
const profileInstructionsInput = document.getElementById('profile-instructions');
let currentAvatarPath = '';

function applyAvatar(avatarPath, avatarUrl) {
  currentAvatarPath = avatarPath || '';
  if (currentAvatarPath) {
    profileAvatarImg.src = avatarUrl || ('file://' + currentAvatarPath.replace(/\\/g, '/') + '?t=' + Date.now());
    profileAvatarImg.classList.remove('hidden');
    profileAvatarFallback.classList.add('hidden');
  } else {
    profileAvatarImg.classList.add('hidden');
    profileAvatarFallback.classList.remove('hidden');
  }
}

function renderProfileForm(profile) {
  applyAvatar(profile.avatarPath, null);
  profileFullnameInput.value = profile.fullName || '';
  profileNicknameInput.value = profile.nickname || '';
  profileRoleSelect.value = profile.role || '';
  profileRoleCustomInput.value = profile.customRole || '';
  profileRoleCustomInput.classList.toggle('hidden', profile.role !== 'otro');
  profileInstructionsInput.value = profile.instructions || '';
}

function renderUserMemory(profile) {
  document.getElementById('user-memory-text').value = profile.userMemory || '';
  const meta = document.getElementById('user-memory-meta');
  if (profile.userMemoryUpdatedAt) {
    const who = profile.userMemoryUpdatedBy === 'mentis' ? 'Mentis' : 'vos';
    const when = new Date(profile.userMemoryUpdatedAt).toLocaleString('es-AR');
    meta.textContent = `Última actualización: ${when} (${who}).`;
  } else {
    meta.textContent = 'Todavía no se guardó nada.';
  }
}

function renderSelfMemory(profile) {
  document.getElementById('self-memory-text').value = profile.selfMemory || '';
  const meta = document.getElementById('self-memory-meta');
  if (profile.selfMemoryUpdatedAt) {
    const who = profile.selfMemoryUpdatedBy === 'mentis' ? 'Mentis' : 'vos';
    const when = new Date(profile.selfMemoryUpdatedAt).toLocaleString('es-AR');
    meta.textContent = `Última actualización: ${when} (${who}).`;
  } else {
    meta.textContent = 'Todavía no se guardó nada.';
  }
}

profileRoleSelect.addEventListener('change', () => {
  profileRoleCustomInput.classList.toggle('hidden', profileRoleSelect.value !== 'otro');
});

document.getElementById('btn-pick-avatar').addEventListener('click', async () => {
  const result = await window.mentisAPI.pickAvatar();
  if (result) applyAvatar(result.avatarPath, result.avatarUrl);
});

document.getElementById('btn-save-profile').addEventListener('click', async () => {
  const btn = document.getElementById('btn-save-profile');
  await window.mentisAPI.saveProfile({
    avatarPath: currentAvatarPath,
    fullName: profileFullnameInput.value.trim(),
    nickname: profileNicknameInput.value.trim(),
    role: profileRoleSelect.value,
    customRole: profileRoleCustomInput.value.trim(),
    instructions: profileInstructionsInput.value.trim()
  });
  flashSaveOk(btn, 'Perfil guardado ✓');
});

document.getElementById('btn-save-user-memory').addEventListener('click', async () => {
  const btn = document.getElementById('btn-save-user-memory');
  const text = document.getElementById('user-memory-text').value.trim();
  const profile = await window.mentisAPI.saveUserMemory(text);
  renderUserMemory(profile);
  flashSaveOk(btn, 'Memoria guardada ✓');
});

document.getElementById('btn-save-self-memory').addEventListener('click', async () => {
  const btn = document.getElementById('btn-save-self-memory');
  const text = document.getElementById('self-memory-text').value.trim();
  const profile = await window.mentisAPI.saveSelfMemory(text);
  renderSelfMemory(profile);
  flashSaveOk(btn, 'Memoria guardada ✓');
});

// --- MODO ADMINISTRADOR (2026-08-07) ----------------------------------------------------------
// El switch sólo se muestra si esta máquina tiene la clave privada de firma. No es para esconderlo
// -- el código está en todas las copias y cualquiera puede activarlo con DevTools -- sino porque
// sin la clave no hay nada que administrar, y un panel de botones que no hacen nada es peor que
// ningún panel. Lo que de verdad impide publicar sin permiso es la firma, no esta interfaz.
async function iniciarModoAdministrador() {
  let esAdmin = false;
  try { esAdmin = await window.mentisAPI.esAdministrador(); } catch (e) { return; }
  if (!esAdmin) return;

  const fila = document.getElementById('admin-switch-fila');
  const sw = document.getElementById('admin-switch');
  const panel = document.getElementById('admin-panel');
  const estado = document.getElementById('admin-estado');
  const salida = document.getElementById('admin-salida');
  const notas = document.getElementById('admin-notas');
  const btnRevisar = document.getElementById('btn-admin-revisar');
  const btnPublicar = document.getElementById('btn-admin-publicar');
  const btnRetirar = document.getElementById('btn-admin-retirar');
  if (!fila || !sw || !panel) return;
  fila.classList.remove('hidden');

  let revisado = false;

  // "Publicar" se habilita sólo con las dos condiciones juntas: haber mirado qué sale y haber
  // escrito qué cambia. Los frenos de verdad (tests, versión, firma) están en mentis-publicar.sh
  // y se aplican igual aunque alguien fuerce el botón desde la consola.
  const refrescarBoton = () => {
    btnPublicar.disabled = !(revisado && notas.value.trim().length >= 5);
    btnPublicar.title = btnPublicar.disabled
      ? 'Primero revisá qué saldría y escribí qué cambia'
      : 'Corre los tests y publica si están en verde';
  };

  async function mostrarEstado() {
    try {
      const e = await window.mentisAPI.estadoPublicacion();
      estado.textContent = e.publicada
        ? `Tu versión: ${e.version} · publicada: ${e.publicada.version} (${(e.publicada.fecha || '').slice(0, 10)})`
        : `Tu versión: ${e.version} · todavía no publicaste ninguna`;
    } catch (err) { estado.textContent = 'No pude leer el estado.'; }
  }

  sw.addEventListener('change', async () => {
    panel.classList.toggle('hidden', !sw.checked);
    if (sw.checked) { await mostrarEstado(); refrescarBoton(); }
  });

  notas.addEventListener('input', refrescarBoton);

  btnRevisar.addEventListener('click', async () => {
    btnRevisar.disabled = true; btnRevisar.textContent = 'Revisando…';
    const r = await window.mentisAPI.publicarRevisar();
    salida.textContent = r.salida || '(sin salida)';
    salida.classList.remove('hidden');
    revisado = true; refrescarBoton();
    btnRevisar.disabled = false; btnRevisar.textContent = 'Revisar qué saldría';
  });

  btnPublicar.addEventListener('click', async () => {
    // Última confirmación con el número de personas a la vista: el costo de equivocarse no es
    // "se rompió mi Mentis", es "se rompió el de todos".
    if (!confirm('Esto va a correr los tests y, si pasan, dejar la actualización lista para todos.\n\n¿Seguimos?')) return;
    btnPublicar.disabled = true; btnPublicar.textContent = 'Corriendo tests… (tarda unos minutos)';
    const r = await window.mentisAPI.publicar(notas.value.trim());
    salida.textContent = r.salida || '(sin salida)';
    salida.classList.remove('hidden');
    btnPublicar.textContent = 'Publicar';
    if (r.ok) { revisado = false; notas.value = ''; await mostrarEstado(); }
    refrescarBoton();
  });

  btnRetirar.addEventListener('click', async () => {
    if (!confirm('Retirar la última publicación.\n\nQuien no la instaló va a dejar de verla. Quien ya la instaló la sigue teniendo.\n\n¿Seguimos?')) return;
    const r = await window.mentisAPI.publicarRetirar();
    salida.textContent = r.salida || '(sin salida)';
    salida.classList.remove('hidden');
    await mostrarEstado();
  });
}
iniciarModoAdministrador();

// --- Apariencia: paleta y nombre (2026-08-06) -------------------------------------------------
// El color se aplica al instante al elegirlo, sin botón de guardar y sin recargar: probar un tema
// tiene que costar un clic, si no nadie los prueba y da igual haberlos hecho.
let aparienciaActual = { paleta: 'mentis-clasico', nombre: 'Mentis' };

function aplicarNombreEnPantalla(nombre) {
  const n = (nombre || 'Mentis').trim() || 'Mentis';
  document.title = n;
  document.querySelectorAll('[data-nombre-ia]').forEach((el) => { el.textContent = n; });
}

function renderTemas(paletaElegida) {
  const cont = document.getElementById('temas-grilla');
  const T = window.MentisTemas;
  if (!cont || !T) return;
  cont.innerHTML = '';
  for (const t of T.listaDeTemas()) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'tema-opcion' + (t.id === paletaElegida ? ' elegido' : '');
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(t.id === paletaElegida));
    b.title = t.nombre;
    const muestra = document.createElement('span');
    muestra.className = 'tema-muestra';
    // Las tres franjas son fondo, acento y texto: alcanza para reconocer la paleta de un vistazo
    // sin tener que aplicarla.
    muestra.style.background =
      `linear-gradient(135deg, ${t.muestra[0]} 0 55%, ${t.muestra[1]} 55% 80%, ${t.muestra[2]} 80% 100%)`;
    const cap = document.createElement('span');
    cap.className = 'tema-nombre';
    cap.textContent = t.nombre;
    b.appendChild(muestra);
    b.appendChild(cap);
    b.addEventListener('click', async () => {
      T.aplicarTema(t.id);
      aparienciaActual.paleta = t.id;
      renderTemas(t.id);
      try { await window.mentisAPI.saveApariencia({ paleta: t.id }); } catch (e) { /* el color ya se ve; si falla el guardado se pierde al reiniciar, no ahora */ }
    });
    cont.appendChild(b);
  }
}

async function openSettings() {
  document.getElementById('ideogram-apikey').value = '';
  document.getElementById('runway-apikey').value = '';
  openRoleRow = null;
  const settings = await window.mentisAPI.getSettings();
  aparienciaActual = settings.apariencia || aparienciaActual;
  document.getElementById('apariencia-nombre').value =
    aparienciaActual.nombre === 'Mentis' ? '' : aparienciaActual.nombre;
  renderTemas(aparienciaActual.paleta);
  renderProfileForm(settings.profile || {});
  renderUserMemory(settings.profile || {});
  renderSelfMemory(settings.profile || {});
  await renderSettingsModelsList();
  await renderIdeogramStatus();
  await renderRunwayStatus();
  settingsOverlay.classList.remove('hidden');
}

function closeSettings() {
  settingsOverlay.classList.add('hidden');
}

document.getElementById('btn-open-settings').addEventListener('click', openSettings);
document.getElementById('btn-close-settings').addEventListener('click', closeSettings);

// El nombre se guarda al salir del campo y no en cada tecla: guardar por tecla escribiria el
// archivo de configuración una vez por letra.
document.getElementById('apariencia-nombre').addEventListener('change', async (e) => {
  const nombre = String(e.target.value || '').trim();
  try {
    const a = await window.mentisAPI.saveApariencia({ nombre });
    aparienciaActual = a;
    aplicarNombreEnPantalla(a.nombre);
    e.target.value = a.nombre === 'Mentis' ? '' : a.nombre;
  } catch (err) { /* queda el nombre viejo, que es mejor que quedarse sin ninguno */ }
});

// Al arrancar: aplicar la paleta y el nombre guardados ANTES de que el usuario (o quien sea) vea la
// pantalla. Se espera a que el módulo de temas esté cargado porque es un <script type="module">
// y corre después de este archivo.
async function aplicarAparienciaGuardada() {
  try {
    const s = await window.mentisAPI.getSettings();
    aparienciaActual = s.apariencia || aparienciaActual;
    if (window.MentisTemas) window.MentisTemas.aplicarTema(aparienciaActual.paleta);
    aplicarNombreEnPantalla(aparienciaActual.nombre);
  } catch (e) { /* se queda con la paleta del CSS: fea pero usable */ }
}
if (window.MentisTemas) aplicarAparienciaGuardada();
else window.addEventListener('mentis-temas-listos', aplicarAparienciaGuardada, { once: true });
document.getElementById('btn-save-ideogram').addEventListener('click', async () => {
  const input = document.getElementById('ideogram-apikey');
  const btn = document.getElementById('btn-save-ideogram');
  if (!input.value.trim()) return;
  await window.mentisAPI.saveIdeogramKey(input.value.trim());
  input.value = '';
  await renderIdeogramStatus();
  flashSaveOk(btn);
});

document.getElementById('btn-save-runway').addEventListener('click', async () => {
  const input = document.getElementById('runway-apikey');
  const btn = document.getElementById('btn-save-runway');
  if (!input.value.trim()) return;
  await window.mentisAPI.saveRunwayKey(input.value.trim());
  input.value = '';
  await renderRunwayStatus();
  flashSaveOk(btn);
});

document.getElementById('btn-export-backup').addEventListener('click', async () => {
  const btn = document.getElementById('btn-export-backup');
  const statusEl = document.getElementById('export-backup-status');
  btn.disabled = true;
  statusEl.textContent = 'Exportando...';
  statusEl.classList.remove('on');
  try {
    const result = await window.mentisAPI.exportBackup();
    if (result.canceled) {
      statusEl.textContent = '';
    } else if (result.ok) {
      statusEl.textContent = `Exportado a ${result.path}`;
      statusEl.classList.add('on');
    } else {
      statusEl.textContent = `Error: ${result.error}`;
    }
  } finally {
    btn.disabled = false;
  }
});

document.getElementById('btn-toggle-logs').addEventListener('click', () => {
  document.getElementById('logs-panel').classList.toggle('collapsed');
});
// Panel de previsualización, sin tabs (pedido del usuario, 2026-07-13: sacar el panel "Tareas" --
// la narración en vivo del chat ya cumple esa función, así que "Previsualización" queda como
// la única sección, un simple abrir/cerrar).
// Cerrar el panel a mano es una DECISION, y se respeta por el resto del turno: si el usuario lo cierra
// mientras Mentis trabaja, no se lo volvemos a abrir de un salto en el paso siguiente. Volverlo a
// abrir con el ojo (o el turno siguiente) cancela esa decisión.
document.getElementById('btn-preview').addEventListener('click', () => {
  const panel = document.getElementById('status-panel');
  panel.classList.toggle('collapsed');
  panelCerradoPorJuan = panel.classList.contains('collapsed');
});
document.getElementById('btn-close-status').addEventListener('click', () => {
  document.getElementById('status-panel').classList.add('collapsed');
  panelCerradoPorJuan = true;
});
// Easter egg del wordmark (pedido del usuario, mejora visual 2026-07-14): clic sostenido ~600ms
// dispara una chispa dorada breve, sin interrumpir nada del flujo principal.
(() => {
  const wordmark = document.getElementById('header-wordmark');
  let holdTimer = null;
  const cancel = () => { if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; } };
  wordmark.addEventListener('pointerdown', () => {
    cancel();
    holdTimer = setTimeout(() => {
      wordmark.classList.remove('spark');
      void wordmark.offsetWidth;
      wordmark.classList.add('spark');
    }, 600);
  });
  wordmark.addEventListener('pointerup', cancel);
  wordmark.addEventListener('pointerleave', cancel);
})();

// Enviar (pedido del usuario, 2026-07-15: el boton de enviar se elimina del todo, ahora se manda
// SOLO con Enter -- ver el listener de keydown mas abajo, que llama a esta misma funcion).
function submitCurrentMessage() {
  const input = document.getElementById('message-input');
  sendCurrentMessage(input.value);
  input.value = '';
}
// Adjuntos múltiples (pedido del usuario, 2026-07-13): pickAttachment ahora devuelve un array
// (selección múltiple habilitada en main.js) -- se ACUMULAN sobre lo que ya estaba elegido, no
// se pisa. Cada adjunto es su propio chip removible, y Mentis recibe un tag "[archivo adjunto:
//...]" por archivo (ver mentis-chat.sh, que ahora despega varios tags en vez de matchear uno solo).
document.getElementById('btn-attach').addEventListener('click', async () => {
  const results = await window.mentisAPI.pickAttachment();
  if (results && results.length > 0) {
    pendingAttachments.push(...results);
    renderAttachChips();
  }
});

function renderAttachChips() {
  const row = document.getElementById('attach-preview-row');
  row.innerHTML = '';
  pendingAttachments.forEach((result, index) => {
    const chip = document.createElement('span');
    chip.className = 'attach-chip';
    if (result.isImage && result.previewUrl) {
      chip.classList.add('attach-chip--image');
      const thumb = document.createElement('img');
      thumb.src = result.previewUrl;
      thumb.className = 'attach-thumb';
      thumb.alt = result.fileName;
      chip.appendChild(thumb);
      const name = document.createElement('span');
      name.className = 'sr-only';
      name.textContent = result.fileName;
      chip.appendChild(name);
    } else {
      chip.appendChild(document.createTextNode(result.fileName));
    }

    const removeBtn = document.createElement('button');
    removeBtn.type = 'button';
    removeBtn.className = 'btn-remove-attachment';
    removeBtn.setAttribute('aria-label', `Quitar ${result.fileName}`);
    removeBtn.title = 'Quitar adjunto';
    removeBtn.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>';
    removeBtn.addEventListener('click', () => {
      pendingAttachments.splice(index, 1);
      renderAttachChips();
    });
    chip.appendChild(removeBtn);
    row.appendChild(chip);
  });
}

// ===== Conectores: popup de click-derecho (pedido del usuario, 2026-07-13, imagen 6) =====
// Sobre el toggle "Conectores" del composer: click derecho abre una lista chica con cada
// conector MCP configurado (mcp-servers.json) y un switch para activarlo/desactivarlo, sin
// pasar por el modal grande de Directorio para algo tan puntual.
const connectorsPopup = document.getElementById('connectors-popup');

function closeConnectorsPopup() {
  connectorsPopup.classList.add('hidden');
  connectorsPopup.innerHTML = '';
  document.removeEventListener('click', onConnectorsPopupOutsideClick, true);
  document.removeEventListener('keydown', onConnectorsPopupKeydown, true);
}

function onConnectorsPopupOutsideClick(e) {
  if (!connectorsPopup.contains(e.target)) closeConnectorsPopup();
}

function onConnectorsPopupKeydown(e) {
  if (e.key === 'Escape') closeConnectorsPopup();
}

function buildConnectorSwitch(connector) {
  const wrap = document.createElement('label');
  wrap.className = 'connector-switch';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.checked = connector.enabled;
  input.setAttribute('aria-label', `Activar/desactivar ${connector.name}`);
  input.addEventListener('change', async () => {
    input.disabled = true;
    try {
      if (connector.kind === 'mcp') {
        await window.mentisAPI.toggleMcpConnector(connector.name, input.checked);
      } else {
        await window.mentisAPI.toggleConnector(connector.id, input.checked);
      }
      connectorStatusCache = null;
      // Bug real encontrado en auditoria 2026-07-14: invalidar el cache no alcanza si el grid de
      // Directorio→Conectores ya esta pintado -- el punto de estado y el texto de detalle de ESA
      // misma fila seguian mostrando el valor viejo hasta cerrar/reabrir el modal. Repintar acá
      // toma el valor fresco de una (si el modal de Directorio no esta abierto, esto solo
      // redibuja contenido oculto, es barato e inofensivo).
      if (!directoryOverlay.classList.contains('hidden')) await renderDirectoryGrid();
    } finally {
      input.disabled = false;
    }
  });
  const track = document.createElement('span');
  track.className = 'connector-switch-track';
  wrap.appendChild(input);
  wrap.appendChild(track);
  return wrap;
}

async function openConnectorsPopup(x, y) {
  // Lista UNIFICADA (pedido del usuario, 2026-07-14): antes solo mostraba conectores MCP -- ahora
  // también Ideogram/Runway (API-key) y las capacidades locales, automático (una sola
  // fuente compartida con Directorio→Conectores, ver getUnifiedConnectors en main.js).
  const connectors = await window.mentisAPI.listAllConnectors();
  connectorsPopup.innerHTML = '';
  const title = document.createElement('div');
  title.className = 'connectors-popup-title';
  title.textContent = 'Conectores';
  connectorsPopup.appendChild(title);

  if (connectors.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'connectors-popup-empty';
    empty.textContent = 'Sin conectores configurados todavía.';
    connectorsPopup.appendChild(empty);
  } else {
    for (const connector of connectors) {
      const row = document.createElement('div');
      row.className = 'connectors-popup-row';
      const name = document.createElement('span');
      name.className = 'connectors-popup-row-name';
      const dot = document.createElement('span');
      dot.className = 'connectors-popup-dot' + (connector.connected === true ? ' on' : '');
      name.appendChild(dot);
      name.appendChild(document.createTextNode(connector.name));
      row.appendChild(name);
      // Switch real para todos salvo Git Bash (toggleable: false, ver connectorCard arriba).
      if (connector.toggleable) {
        row.appendChild(buildConnectorSwitch(connector));
      }
      connectorsPopup.appendChild(row);
    }
  }

  connectorsPopup.style.left = '0px';
  connectorsPopup.style.top = '0px';
  connectorsPopup.classList.remove('hidden');
  // Clampeo simple para que no se salga de la ventana (el popup puede ser mas angosto/ancho
  // segun cuantos conectores haya, así que se mide DESPUES de llenarlo, no antes).
  const rect = connectorsPopup.getBoundingClientRect();
  const clampedX = Math.min(x, window.innerWidth - rect.width - 8);
  const clampedY = Math.min(y, window.innerHeight - rect.height - 8);
  connectorsPopup.style.left = Math.max(8, clampedX) + 'px';
  connectorsPopup.style.top = Math.max(8, clampedY) + 'px';

  setTimeout(() => {
    document.addEventListener('click', onConnectorsPopupOutsideClick, true);
    document.addEventListener('keydown', onConnectorsPopupKeydown, true);
  }, 0);
}

document.getElementById('flag-t-label').addEventListener('contextmenu', (e) => {
  e.preventDefault();
  openConnectorsPopup(e.clientX, e.clientY);
});

// "Modo sin frenos": activarlo saca el bloqueo de comandos destructivos de nv-agent.sh (rm -rf,
// git push, format, etc.). Pide confirmacion explicita antes de dejarlo tildado (pedido de
// el usuario), y mientras este activo aparece "Frenar ya" en el header para cortar todo al instante.
function confirmModal(title, message, confirmLabel) {
  return new Promise((resolve) => {
    const { overlay, body, actions } = baseModal(title);
    const p = document.createElement('p');
    p.textContent = message;
    p.style.whiteSpace = 'pre-line';
    body.appendChild(p);
    const finish = (value) => {
      overlay.removeEventListener('keydown', onKeydown);
      closeModal();
      resolve(value);
    };
    const onKeydown = (e) => { if (e.key === 'Escape') finish(false); };
    overlay.addEventListener('keydown', onKeydown);
    addModalButton(actions, 'Cancelar', false, () => finish(false));
    addModalButton(actions, confirmLabel, true, () => finish(true));
  });
}

const flagXInput = document.getElementById('flag-x');
const flagCInput = document.getElementById('flag-computer-use');
const flagAInput = document.getElementById('flag-a');

// --- CÁMARA Y TELÉFONO EN EL GRUPO DE BOTONES (2026-07-31) --------------------------------------
// Los dos son conectores, no banderas sueltas: el botón escribe el MISMO interruptor que se ve en
// Directorio -> Conectores. Si fueran dos estados distintos, prender el botón y ver "Desactivado"
// en el directorio (o al revés) sería cuestión de tiempo.
const flagWebcamInput = document.getElementById('flag-webcam');
const flagTelefonoInput = document.getElementById('flag-telefono');

async function sincronizarBotonesDeConectores() {
  // Se lee el estado REAL guardado, no se asume: estos dos arrancan apagados y el botón tiene que
  // mostrar lo que de verdad está pasando.
  try {
    const lista = await window.mentisAPI.listAllConnectors();
    const buscar = (id) => (lista || []).find((c) => c.id === id);
    const cam = buscar('local:webcam');
    const tel = buscar('local:telefono');
    if (cam) flagWebcamInput.checked = !!cam.enabled;
    if (tel) flagTelefonoInput.checked = !!tel.enabled;
  } catch (e) {
    // Si no se pudo leer, quedan apagados: para lo invasivo, la duda se resuelve del lado seguro.
    flagWebcamInput.checked = false;
    flagTelefonoInput.checked = false;
  }
  // Estado inicial del freno: si la cámara ya venía prendida de la sesión anterior, el botón
  // tiene que estar a la vista desde el arranque y no recién cuando el usuario toque algún otro flag.
  updateEmergencyStopVisibility();
}

[[flagWebcamInput, 'local:webcam'], [flagTelefonoInput, 'local:telefono']].forEach(([input, id]) => {
  input.addEventListener('change', async () => {
    try {
      await window.mentisAPI.toggleConnector(id, input.checked);
      connectorStatusCache = null;   // el popup de conectores tiene que ver el cambio
      // Prender la cámara o el teléfono tiene que hacer aparecer el freno en el acto: si sólo se
      // recalculara al cambiar los otros flags, se podría estar con la cámara viva y sin botón.
      updateEmergencyStopVisibility();
    } catch (e) {
      input.checked = !input.checked;   // no se pudo guardar: que el botón no mienta
      showToast('No pude cambiar ese conector');
    }
  });
});
sincronizarBotonesDeConectores();
const emergencyStopBtn = document.getElementById('btn-emergency-stop');
const messageInputEl = document.getElementById('message-input');
const speechPauseBtn = document.getElementById('btn-speech-pause');

// "Frenar ya" queda visible mientras CUALQUIER capacidad de alto riesgo esté activa (sin
// frenos, control de mouse/teclado, y/o Arduino -- puede tocar una placa real conectada).
//
// LA CAMARA ENTRA A ESTA LISTA (2026-08-08). Faltaba, y se notó de la peor manera: Mentis se
// quedó en un bucle sacando fotos con la webcam, el usuario fue a frenarlo y el botón de frenar NO
// ESTABA EN PANTALLA -- porque la webcam no contaba como capacidad de riesgo. Tuvo que cerrar la
// aplicación entera para que dejara de sacar fotos.
// Es incoherente que el mismo código llame a la cámara "la herramienta más invasiva que tiene
// Mentis" (ver nv-agent.sh) y que no aparezca el freno cuando está prendida. El teléfono entra
// por lo mismo: acceso a mensajes y notificaciones de un dispositivo real.
function updateEmergencyStopVisibility() {
  // Se busca el botón acá adentro en vez de usar la constante de arriba: así esta función se
  // puede llamar desde cualquier punto del arranque, incluso antes de que esa constante exista,
  // sin explotar. Importa porque la sincronización inicial de conectores es asincrónica y puede
  // terminar antes o después según el día -- y de eso depende que el freno esté a la vista.
  const btn = document.getElementById('btn-emergency-stop');
  if (!btn) return;
  const prendido = (el) => !!(el && el.checked);
  const enRiesgo = prendido(flagXInput) || prendido(flagCInput) || prendido(flagAInput)
                || prendido(flagWebcamInput) || prendido(flagTelefonoInput);
  btn.classList.toggle('hidden', !enRiesgo);
}

flagXInput.addEventListener('change', async () => {
  if (flagXInput.checked) {
    const confirmed = await confirmModal(
      'Modo sin frenos',
      'Esto desactiva el bloqueo de comandos destructivos (rm -rf, git push, git reset --hard, format, etc.) para esta conversación. Mentis va a poder ejecutarlos sin que ningún filtro se lo impida.\n\nMientras esté activo vas a tener un botón "Frenar ya" arriba para cortar todo al instante si hace falta.\n\n¿Confirmás que querés activarlo?',
      'Sí, activar sin frenos'
    );
    if (!confirmed) {
      flagXInput.checked = false;
      return;
    }
  }
  updateEmergencyStopVisibility();
  if (activeConversationId && !turnInFlight) {
    openConversation(activeConversationId);
  }
});

// Computer-use (pedido del usuario, 2026-07-12; fusionado con "ver pantalla" el 2026-07-16): a
// diferencia de browse/mcp/gen (activos por defecto), esto queda apagado por defecto y pide
// confirmación explícita, mismo patrón que "modo sin frenos" -- es la capacidad de mayor riesgo
// de todas. Un solo checkbox ahora gobierna tanto ver la pantalla como controlar mouse/teclado.
flagCInput.addEventListener('change', async () => {
  if (flagCInput.checked) {
    const confirmed = await confirmModal(
      'Computer-use',
      'Esto le da a Mentis control REAL sobre tu mouse y teclado: puede mover el cursor, hacer clicks y escribir de verdad en la ventana que tengas activa, en cualquier aplicación de tu computadora (no solo el navegador). También ve tu pantalla real para saber qué está tocando.\n\nEs la capacidad de mayor riesgo de todas las que tiene Mentis. Vas a poder ver en vivo lo que va haciendo en el panel de Previsualización, y mientras esté activa vas a tener un botón "Frenar ya" arriba para cortar todo al instante si hace falta.\n\n¿Confirmás que querés activarla?',
      'Sí, activar computer-use'
    );
    if (!confirmed) {
      flagCInput.checked = false;
      return;
    }
  }
  updateEmergencyStopVisibility();
  if (activeConversationId && !turnInFlight) {
    openConversation(activeConversationId);
  }
});

// Arduino (pedido del usuario, 2026-07-14): mismo patrón que control -- apagado por defecto,
// pide confirmación explícita porque puede compilar/subir código real a una placa conectada.
flagAInput.addEventListener('change', async () => {
  if (flagAInput.checked) {
    const confirmed = await confirmModal(
      'Arduino activo',
      'Esto le da a Mentis acceso real a arduino-cli: puede compilar sketches, subir código a una placa Arduino conectada por USB (sobreescribe lo que tenía antes) y leer su monitor serie.\n\nMientras esté activo vas a tener un botón "Frenar ya" arriba para cortar todo al instante si hace falta.\n\n¿Confirmás que querés activarlo?',
      'Sí, activar Arduino'
    );
    if (!confirmed) {
      flagAInput.checked = false;
      return;
    }
  }
  updateEmergencyStopVisibility();
  if (activeConversationId && !turnInFlight) {
    openConversation(activeConversationId);
  }
});

emergencyStopBtn.addEventListener('click', async () => {
  const label = emergencyStopBtn.querySelector('span');
  emergencyStopBtn.disabled = true;
  label.textContent = 'Frenando...';
  const result = await window.mentisAPI.forceStop();
  emergencyStopBtn.disabled = false;
  label.textContent = result && result.ok ? 'Frenado' : 'No se frenó del todo';
  setTimeout(() => { label.textContent = 'Frenar ya'; }, 2500);
});

// ===== "Live" (pedido del usuario, 2026-07-12; nombre "conversación fluida" descartado): hablar
// en vez de escribir =====
// Grabación real (MediaRecorder + getUserMedia) -> transcripción local con Whisper (IPC a
// main.js, ver mentis-transcribe.sh) -> el texto vuelve al cuadro para revisar/editar, NO se
// manda solo (decisión del usuario: quiere poder corregir antes de mandar).
let mediaRecorder = null;
let audioChunks = [];
let voiceModeActive = false;

// --- dictado largo por TRAMOS (2026-07-30) ---
// El stream del micrófono vive durante todo el mensaje; lo que se abre y cierra es el grabador.
// Cada tramo cerrado es un webm COMPLETO y válido (por eso se corta el grabador entero en vez de
// mandar pedazos de uno solo: los pedazos posteriores de un webm no llevan encabezado y Whisper
// no los puede abrir).
let streamVoz = null;
let inicioTramo = 0;
let tramoCerradoAProposito = false;   // distingue "corté un tramo" de "terminó el mensaje"
let tramosPendientes = [];            // promesas de transcripción, en el orden en que se hablaron

const voicePanel = document.getElementById('voice-panel');
const micBtn = document.getElementById('btn-mic');
const voiceStatus = document.getElementById('voice-status');

function _mc_stopRecordingIfActive() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') mediaRecorder.stop();
}

// Manda a transcribir un tramo YA cerrado, sin esperarlo: guarda la promesa en su posición para
// poder rearmar el texto en orden al final.
function encolarTranscripcionDeTramo(chunks) {
  if (!chunks || !chunks.length) return;
  const posicion = tramosPendientes.length;
  const blob = new Blob(chunks, { type: 'audio/webm' });
  tramosPendientes[posicion] = blob.arrayBuffer()
.then((buf) => window.mentisAPI.transcribeAudio(buf))
.then((r) => (r && r.ok && r.text ? String(r.text).trim() : null))
.catch(() => null);
}

// Cierra el tramo actual y sigue grabando en el acto, sobre el MISMO stream.
function cerrarTramoYSeguir() {
  if (!mediaRecorder || mediaRecorder.state !== 'recording') return;
  tramoCerradoAProposito = true;
  mediaRecorder.stop();   // onstop arranca el tramo siguiente
}

// ===== EL CUERPO DIGITAL EN LA ZONA CENTRAL (rediseño 2026-07-27) =====
// Reemplaza al overlay a pantalla completa: el usuario pidió que el cuerpo entre en el cuadro de los
// mensajes y que el resto de la interfaz siga a la vista, porque hace falta para navegar.
// Un solo cuerpo que cambia de tamaño, no dos instancias: el encuadre se recalcula solo con el
// ResizeObserver, así que pasar de pantalla completa a un rincón de 132 px no requiere nada más.
const zonaCentral = document.getElementById('zona-central');
const cuerpoCanvas = document.getElementById('cuerpo-principal');
const vozEstado = document.getElementById('voz-estado');

function montarCuerpoPrincipal() {
  if (!cuerpoCanvas || !window.MentisCuerpo) return;
  if (window.MentisCuerpo.get('principal')) return;
  window.MentisCuerpo.montar('principal', cuerpoCanvas, { detalle: 'alto', estado: 'STANDBY' });
}

/** Sin conversación el cuerpo ocupa todo el cuadro; con una abierta, se queda con la columna
 *  izquierda y los mensajes toman la derecha (pedido del usuario, 2026-07-27). */
function acomodarCuerpo(hayMensajes) {
  if (!zonaCentral) return;
  // Una sola clase en el contenedor decide el reparto: las dos columnas son hermanas flex, así
  // que basta con cambiar cuánto ocupa una para que la otra se acomode sola.
  zonaCentral.classList.toggle('con-mensajes', !!hayMensajes);
}

// El módulo del cuerpo es diferido: cuando este script corre, todavía no existe. El evento lo
// avisa. Se intenta igual por si el módulo llegó primero (el orden no está garantizado).
window.addEventListener('mentis-cuerpo-listo', montarCuerpoPrincipal);
montarCuerpoPrincipal();

if (cuerpoCanvas) {
  // El núcleo ES el botón. En vez de duplicar la lógica de grabar/transcribir/mandar, se reenvía
  // el click al botón de micrófono que ya hace todo eso: una sola implementación, y cualquier
  // arreglo futuro vale para los dos lados.
  cuerpoCanvas.addEventListener('click', () => micBtn.click());
  cuerpoCanvas.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); micBtn.click(); }
  });
}

// El cartel espeja el estado del panel de voz en vez de llevar su propio texto. Los mensajes
// ("Escuchando...", "Transcribiendo...", "Escuché:...") ya se escriben en seis lugares del
// flujo; duplicarlos sería garantizar que algún día queden desincronizados.
if (voiceStatus && vozEstado && typeof MutationObserver !== 'undefined') {
  new MutationObserver(() => {
    vozEstado.textContent = (voiceStatus.textContent || '').toLowerCase();
    if (zonaCentral) zonaCentral.classList.toggle('escuchando', micBtn.classList.contains('recording'));
  }).observe(voiceStatus, { childList: true, characterData: true, subtree: true });
}

// ===== LA VOZ ES EL ÚNICO MODO (2026-07-27) =====
// Ya no es una casilla que se prende: Mentis arranca escuchando. El toggle sigue existiendo
// porque de él cuelga la lógica de voz (subtítulos, hablar la respuesta), pero queda encendido.
//
// Se declara ACÁ ARRIBA y no junto a su función: aplicarModoVoz() se ejecuta apenas se define,
// y leer una variable `let` declarada más abajo cae en su zona muerta temporal -- ReferenceError
// en la primera línea del arranque, con la app en blanco.
let tecladoDeEmergencia = false;

// El modo voz YA NO SE APAGA (pedido del usuario, 2026-07-31: "eliminar el boton del modo live, no
// sirve porque esta activado todo el tiempo"). Y era literal: la linea de abajo lo forzaba a
// encendido en cada arranque, asi que el boton no interrupteaba nada -- ocupaba lugar y sugeria
// una opcion que no existia. La funcion se conserva porque el teclado de emergencia (Ctrl+T)
// sigue necesitando reacomodar la pantalla.
function aplicarModoVoz() {
  voiceModeActive = true;
  messageInputEl.classList.toggle('hidden', voiceModeActive && !tecladoDeEmergencia);
  voicePanel.classList.toggle('hidden', !voiceModeActive);
  if (!voiceModeActive) {
    _mc_stopRecordingIfActive();
    limpiarSubtitulos(0);
  }
}
aplicarModoVoz();

// RED DE SEGURIDAD, no una segunda interfaz (el usuario: "asegurate de que no falle").
// Todo lo que depende de Mentis -- que la transcripción sea buena, que el audio no venga vacío,
// que el TTS responda -- se arregla en el código, y de eso se ocupa el resto de este archivo.
// Lo único que Mentis NO puede resolver por su cuenta es que Windows le niegue el micrófono al
// proceso. Para ese caso, y sólo ese, Ctrl+T devuelve el teclado.
function alternarTecladoDeEmergencia(forzar) {
  tecladoDeEmergencia = forzar === undefined ? !tecladoDeEmergencia : !!forzar;
  messageInputEl.classList.toggle('hidden', !tecladoDeEmergencia && voiceModeActive);
  if (tecladoDeEmergencia) messageInputEl.focus();
}
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && (e.key === 't' || e.key === 'T')) {
    e.preventDefault();
    alternarTecladoDeEmergencia();
  }
});

micBtn.addEventListener('click', async () => {
  if (mediaRecorder && mediaRecorder.state === 'recording') {
    mediaRecorder.stop();
    return;
  }
  // Si Mentis está hablando y tocás el micrófono, se calla: querés decirle algo, no escucharlo.
  interrumpirSiHabla();
  try {
    // El audio se pide con las condiciones que Whisper quiere, en vez de `audio: true` a secas
    // (2026-07-27, tras ver "quédia y soy por favor" donde el usuario dijo "qué día y hora es"):
    //   - 16 kHz mono es exactamente lo que el modelo consume. Pedirlo acá evita que el audio
    //     viaje en estéreo a 48 kHz para terminar remuestreado igual, con una conversión de más.
    //   - autoGainControl es el que más pesa con el micrófono de una notebook: sube la voz baja,
    //     que es justo cuando Whisper empieza a inventar palabras.
    //   - noiseSuppression y echoCancellation evitan que el ventilador y el propio parlante de
    //     Mentis entren en la grabación.
    // Son PEDIDOS, no garantías: si el micrófono no los soporta, el navegador entrega lo que
    // puede y la grabación sigue funcionando igual.
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        sampleRate: 16000,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    });
    audioChunks = [];
    streamVoz = stream;
    tramosPendientes = [];
    tramoCerradoAProposito = false;
    inicioTramo = Date.now();
    armarGrabadorDeTramo();

    function armarGrabadorDeTramo() {
      mediaRecorder = new MediaRecorder(streamVoz);
      mediaRecorder.ondataavailable = (e) => { if (e.data.size > 0) audioChunks.push(e.data); };
      mediaRecorder.onstop = onstopDelTramo;
      mediaRecorder.start();
      inicioTramo = Date.now();
    }

    async function onstopDelTramo() {
      const chunksDelTramo = audioChunks;
      audioChunks = [];

      // Si el corte fue mío (dictado largo), el mensaje NO terminó: se manda a transcribir lo
      // dicho hasta acá y se vuelve a grabar sin que el micrófono se apague un solo instante.
      if (tramoCerradoAProposito) {
        tramoCerradoAProposito = false;
        encolarTranscripcionDeTramo(chunksDelTramo);
        armarGrabadorDeTramo();
        return;
      }

      // Acá sí terminó el mensaje.
      if (tempMaxGrabacion) { clearTimeout(tempMaxGrabacion); tempMaxGrabacion = null; }
      streamVoz = null;
      stream.getTracks().forEach((t) => t.stop());
      const duroMs = Date.now() - inicioGrabacion;
      const nivelPico = nivelMaxGrabacion;
      frenarMedidorDeVoz();
      micBtn.classList.remove('recording');

      // FILTRO DE ENTRADA: si no se dijo nada, no se manda nada.
      // 0,015 de RMS pico es ruido de sala; una palabra dicha bajito ya pasa de 0,04. Y menos de
      // 400 ms no alcanza para una palabra entera -- es el doble toque de quien se arrepintió.
      // Sin esto, Whisper igual devuelve ALGO (inventa sobre el ruido), ese algo llega al
      // clasificador, y terminás con un error de agente sobre una frase que nunca dijiste.
      const NIVEL_MINIMO = 0.015;
      const DURACION_MINIMA_MS = 400;
      if (duroMs < DURACION_MINIMA_MS || nivelPico < NIVEL_MINIMO) {
        cuerpoSetEstado('STANDBY');
        voiceStatus.textContent = nivelPico < NIVEL_MINIMO
          ? 'No te escuché. ¿Está prendido el micrófono?'
          : 'Muy corto. Mantené apretado un momento más.';
        setTimeout(() => { if (voiceModeActive) voiceStatus.textContent = 'Tocá para hablar'; }, 3000);
        return;
      }

      // Dejó de escuchar y arranca a trabajar: el cuerpo pasa de frío a fuego.
      cuerpoSetEstado('PROCESSING');
      micBtn.disabled = true;
      voiceStatus.textContent = 'Transcribiendo...';

      // El último tramo se encola igual que los anteriores y después se esperan TODOS. En un
      // mensaje corto esto es exactamente lo de antes: un solo tramo, una sola transcripción.
      encolarTranscripcionDeTramo(chunksDelTramo);
      const partes = await Promise.all(tramosPendientes);
      tramosPendientes = [];
      const fallaron = partes.filter((p) => p === null).length;
      const texto = partes.filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
      const result = { ok: !!texto, text: texto };
      micBtn.disabled = false;
      if (fallaron > 0 && texto) {
        // Honestidad antes que prolijidad: si se perdió un pedazo del dictado, se avisa. Lo peor
        // que puede hacer acá es mandar medio mensaje como si estuviera entero.
        mostrarSubtitulo('mentis', 'Aviso: no pude transcribir ' + fallaron + ' tramo(s) del dictado.');
      }
      if (result.ok) {
        // EL CÍRCULO SE CIERRA ACÁ (arreglo del 2026-07-26).
        // Antes, este bloque APAGABA el modo voz (`voiceModeActive = false`) y dejaba el texto
        // en el cuadro para que el usuario apretara enviar. Pero hablar la respuesta depende de esa
        // misma variable, así que Mentis nunca llegaba a contestar hablando: el modo voz se
        // apagaba justo antes de que llegara la respuesta. Eran cuatro toques por vuelta y el
        // círculo quedaba abierto en el último paso.
        // Ahora el modo voz SIGUE encendido y el mensaje se manda solo. Vos hablás, Mentis
        // contesta hablando, y podés seguir hablando.
        voiceStatus.textContent = 'Escuché: "' + result.text.slice(0, 60) + '"';
        mostrarSubtitulo('usuario', result.text);
        messageInputEl.value = result.text;
        submitCurrentMessage();
        setTimeout(() => {
          if (voiceModeActive) voiceStatus.textContent = 'Tocá para hablar';
        }, 2500);
      } else {
        voiceStatus.textContent = 'No se pudo transcribir. Probá de nuevo.';
        setTimeout(() => { voiceStatus.textContent = 'Tocá para hablar'; }, 3000);
      }
    }
    // El quinto estado del cuerpo (Fase 4): mientras grabás, el núcleo se enfría y late con tu
    // voz. Va DESPUÉS de start() para que el cuerpo no se enfríe si la grabación falla al arrancar.
    cuerpoSetEstado('LISTENING');
    arrancarMedidorDeVoz(stream);
    micBtn.classList.add('recording');
    voiceStatus.textContent = 'Hablá, te escucho';

    // RED DE SEGURIDAD, y NADA MÁS QUE ESO: si el micrófono entrega niveles que nunca cruzan el
    // umbral (ganancia muy baja, micrófono silenciado por hardware), el VAD no dispara nunca y la
    // grabación quedaría abierta para siempre.
    // Antes esto valía 45 SEGUNDOS y funcionaba como límite de mensaje: cortaba dictados reales
    // por la mitad -- la mitad del bug que reportó el usuario el 2026-07-30 ("no aguanta mensajes
    // largos y se corta y envía"). Ahora son 15 minutos: sigue siendo una red contra el micrófono
    // roto, pero ya no le pone techo a lo que tenés para decir.
    if (tempMaxGrabacion) clearTimeout(tempMaxGrabacion);
    tempMaxGrabacion = setTimeout(() => {
      if (mediaRecorder && mediaRecorder.state === 'recording') {
        vadActivo = false;
        voiceStatus.textContent = 'Corté a los 15 minutos (¿el micrófono está mudo?).';
        _mc_stopRecordingIfActive();
      }
    }, MAX_GRABACION_MS);
  } catch (e) {
    frenarMedidorDeVoz();
    cuerpoSetEstado('STANDBY');
    voiceStatus.textContent = 'No pude acceder al micrófono (revisá permisos).';
  }
});

// ===== Respuesta hablada (TTS), pausa/reanudación NATIVA del navegador =====
// window.speechSynthesis.pause()/.resume() retoman desde el mismo punto donde se cortó -- no
// hace falta rearmar nada a mano (pedido explícito del usuario: "que no vuelva a empezar de cero").
let isPaused = false;

function pickSpanishVoice() {
  const voices = window.speechSynthesis.getVoices();
  return voices.find((v) => v.lang && v.lang.toLowerCase().startsWith('es')) || voices[0] || null;
}

function updatePauseIcon() {
  const label = isPaused ? 'Seguir escuchando' : 'Pausar la voz de Mentis';
  speechPauseBtn.title = label;
  speechPauseBtn.setAttribute('aria-label', label);
}

// Bug reportado por el usuario (voz real en Live no funcionaba). No pude reproducirlo con consola
// en vivo (Electron nativo, sin devtools remoto acá), así que esto ataca las DOS causas mejor
// documentadas de que speechSynthesis.speak() falle en silencio en Chromium, en vez de una
// adivinanza única:
// 1) getVoices() devuelve [] la primera vez (carga async) -- si se llama speak() con la lista
//    todavía vacía, Chromium a veces la traga sin hablar ni disparar onerror. Fix: esperar el
//    evento 'voiceschanged' antes del primer speak(), con un timeout de seguridad.
// 2) cancel() y speak() llamados pegados en el mismo tick a veces pierden el segundo. Fix: un
//    delay chico entre uno y otro.
// Si el usuario prueba esto y sigue sin sonar, el error real ahora sí va a quedar en la consola
// (antes onerror no logueaba nada -- imposible saber por qué fallaba).
// Voz de NVIDIA (2026-07-26): Mentis habla con magpie-tts-multilingual, voz la voz elegida --
// la eligió el usuario escuchando muestras reales contra Diego e Isabela Calm. speechSynthesis de
// Windows queda SOLO como red de seguridad: si no hay internet o la API falla, Mentis sigue
// hablando (peor, pero habla) en vez de quedarse muda.
let audioVoz = null;   // el <audio> en curso, para poder pausarlo/frenarlo

function detenerVozNvidia() {
  // Invalidar la cola de frases es lo PRIMERO: si sólo se pausara el audio actual, la frase
  // siguiente ya está generándose y arrancaría sola un segundo después. Interrumpir a Mentis
  // tiene que callarlo entero, no sólo la oración que está diciendo.
  vozGeneracion++;
  if (audioVoz) {
    try { audioVoz.pause(); } catch { /* ya estaba frenado */ }
    audioVoz = null;
  }
  hablando = false;
  frenarKaraoke();
}

/* Interrupción: si el usuario empieza a hablar mientras Mentis responde, Mentis se calla.
   Es lo que uno hace con una persona, y sin esto habría que esperar a que termine la frase
   entera para poder corregirlo. Con la voz vieja de Windows no se podía hacer bien; con el
   <audio> del TTS nuevo es directo. */
function interrumpirSiHabla() {
  if (!hablando && !audioVoz) return false;
  detenerVozNvidia();
  try { window.speechSynthesis.cancel(); } catch { /* no hay nada que cancelar */ }
  speechPauseBtn.classList.add('hidden');
  cuerpoSetEstado(turnInFlight ? 'PROCESSING' : 'STANDBY');
  return true;
}

// ===== HABLAR POR FRASES (2026-07-27) =====
// Antes Mentis generaba el audio de TODA la respuesta y recién ahí abría la boca: en una
// respuesta larga son varios segundos de silencio incómodo, y cuanto más tiene para decir, más
// tarda en empezar. Ahora corta el texto en frases, genera la primera, y mientras esa suena va
// preparando la siguiente. El tiempo hasta que EMPIEZA a hablar deja de depender del largo total.
// Es la idea de streaming del blueprint de voz de NVIDIA, hecha con lo que Mentis ya tiene: no
// hace falta gRPC en streaming para que deje de esperar a tener todo listo.
let vozGeneracion = 0;   // cambia en cada speakText; sirve para abortar una cola vieja

function partirEnFrases(texto) {
  const bruto = String(texto)
.replace(/\s+/g, ' ')
.split(/(?<=[.!?…])\s+(?=[¿¡"'(A-ZÁÉÍÓÚÑ0-9])/);
  // Se reagrupan las muy cortas: generar audio para "Sí." por separado suena entrecortado y
  // gasta una llamada entera. El tope evita el otro extremo -- una frase larguísima anula la
  // ventaja de empezar antes.
  const frases = [];
  for (const parte of bruto) {
    const t = parte.trim();
    if (!t) continue;
    const ultima = frases[frases.length - 1];
    if (ultima && (ultima.length < 60 || t.length < 25) && (ultima.length + t.length) < 320) {
      frases[frases.length - 1] = ultima + ' ' + t;
    } else {
      frases.push(t);
    }
  }
  return frases;
}

// ===== SALIDA DE AUDIO: saber POR DÓNDE está hablando (2026-07-28) =====
// El caso que lo motivó: el usuario estaba con los auriculares Bluetooth y no escuchó nada. Subir el
// volumen no servía de nada porque el sonido salía por otro lado. Mentis no puede saber si lo
// OYEN, pero sí puede decir por dónde está hablando y avisar cuando eso cambia -- que es la
// diferencia entre "no funciona" y "che, te lo estoy diciendo por los auriculares".
let salidaAudioConocida = null;

async function salidaDeAudioActual() {
  try {
    const devs = await navigator.mediaDevices.enumerateDevices();
    const salidas = devs.filter((d) => d.kind === 'audiooutput');
    if (!salidas.length) return null;
    const porDefecto = salidas.find((d) => d.deviceId === 'default') || salidas[0];
    // El label viene vacío si nunca se dio permiso de micrófono; con el permiso ya dado (modo
    // voz) trae el nombre real del dispositivo.
    return porDefecto.label || null;
  } catch { return null; }
}

function avisarProblemaDeSalida(msg) {
  console.warn('[Mentis][audio]', msg);
  if (voiceStatus) {
    voiceStatus.textContent = msg;
    setTimeout(() => {
      if (voiceStatus && voiceStatus.textContent === msg && !vadDiagnostico) {
        voiceStatus.textContent = voiceModeActive ? 'Tocá para hablar' : '';
      }
    }, 6000);
  }
}

// Se chequea al empezar a hablar, no en un bucle: es cuando importa y cuesta nada.
async function avisarSiCambioLaSalida() {
  const actual = await salidaDeAudioActual();
  if (!actual) return;
  if (salidaAudioConocida && actual !== salidaAudioConocida) {
    avisarProblemaDeSalida(`Ojo: ahora te hablo por "${actual}".`);
  }
  salidaAudioConocida = actual;
}

// Si el dispositivo se desconecta MIENTRAS habla (te sacás los auriculares, se apagan por
// batería), el audio sigue "reproduciéndose" contra la nada. Acá al menos queda dicho.
try {
  navigator.mediaDevices.addEventListener('devicechange', async () => {
    const actual = await salidaDeAudioActual();
    if (!actual) return;
    if (hablando && salidaAudioConocida && actual !== salidaAudioConocida) {
      avisarProblemaDeSalida(`Cambió la salida de audio a "${actual}" mientras hablaba.`);
    }
    salidaAudioConocida = actual;
  });
} catch { /* navegador sin devicechange: se sigue sin el aviso */ }

async function speakText(text) {
  if (!text) return;
  avisarSiCambioLaSalida();   // no se espera: no vale la pena demorar la voz por un aviso
  const frases = partirEnFrases(text);
  // Una sola frase no gana nada con la cola: se va por el camino de siempre.
  if (frases.length > 1) return hablarPorFrases(frases, text);
  return speakTextDeUnaVez(text);
}

async function hablarPorFrases(frases, textoCompleto) {
  detenerVozNvidia();
  const miGeneracion = ++vozGeneracion;
  const pedirAudio = (t) => window.mentisAPI.tts(t).catch(() => null);

  let siguiente = pedirAudio(frases[0]);
  for (let i = 0; i < frases.length; i++) {
    const r = await siguiente;
    if (miGeneracion !== vozGeneracion) return;          // llegó otra respuesta: esta cola muere
    // Se pide la próxima ANTES de reproducir la actual: mientras suena, la otra se va generando.
    siguiente = (i + 1 < frases.length) ? pedirAudio(frases[i + 1]) : null;

    if (!r || !r.ok || !r.path) {
      // Si una frase falla, se dice el resto con la voz de Windows en vez de quedarse mudo.
      if (i === 0) { speakTextWindows(textoCompleto); return; }
      continue;
    }
    const ok = await reproducirFrase(r.path, frases[i], i === 0, i === frases.length - 1, miGeneracion);
    // Si el usuario interrumpió, esta cola muere y ya está: él decidió que se calle.
    if (miGeneracion !== vozGeneracion) return;
    if (!ok) {
      // BUG REAL (2026-07-28): acá había un `return` seco. El fallback a la voz de Windows sólo
      // cubría que fallara la GENERACIÓN del audio; si el.wav se generaba bien pero el <audio>
      // no podía reproducirlo, Mentis se quedaba mudo en silencio -- sin error, sin fallback y
      // sin que nadie se enterara. Lo que falla acá es el parlante, no el modelo, así que la
      // respuesta correcta es decir lo que falta por el otro camino.
      const loQueFalta = frases.slice(i).join(' ');
      console.warn('[Mentis] no se pudo reproducir el audio; sigo con la voz de Windows');
      avisarProblemaDeSalida('No pude reproducir el audio. ¿Cambió la salida de sonido?');
      speakTextWindows(loQueFalta || textoCompleto);
      return;
    }
  }
}

function reproducirFrase(ruta, texto, esPrimera, esUltima, miGeneracion) {
  return new Promise((resolve) => {
    const audio = new Audio('file:///' + String(ruta).replace(/\\/g, '/').replace(/^\/+/, ''));
    audioVoz = audio;
    isPaused = false;
    audio.onplay = () => {
      if (esPrimera) {
        speechPauseBtn.classList.remove('hidden');
        updatePauseIcon();
        hablando = true;
        cuerpoSetEstado('SPEAKING');
      }
      subtitularMientrasHabla(texto, audio);
    };
    audio.onended = () => {
      frenarKaraoke();
      if (esUltima && miGeneracion === vozGeneracion) {
        speechPauseBtn.classList.add('hidden');
        audioVoz = null;
        hablando = false;
        mostrarSubtitulo('mentis', texto);
        limpiarSubtitulos(3500);
        cuerpoSetEstado(turnInFlight ? 'PROCESSING' : 'STANDBY');
      }
      resolve(true);
    };
    audio.onerror = () => { frenarKaraoke(); resolve(false); };
    audio.play().catch(() => resolve(false));
  });
}

async function speakTextDeUnaVez(text) {
  if (!text) return;
  detenerVozNvidia();
  vozGeneracion++;
  try {
    const r = await window.mentisAPI.tts(text);
    if (r && r.ok && r.path) {
      const audio = new Audio('file:///' + String(r.path).replace(/\\/g, '/').replace(/^\/+/, ''));
      audioVoz = audio;
      isPaused = false;
      audio.onplay = () => {
        speechPauseBtn.classList.remove('hidden');
        updatePauseIcon();
        hablando = true;
        cuerpoSetEstado('SPEAKING');   // el núcleo pulsa al ritmo de la voz
        subtitularMientrasHabla(text, audio);
      };
      audio.onended = () => {
        speechPauseBtn.classList.add('hidden');
        audioVoz = null;
        hablando = false;
        frenarKaraoke();
        mostrarSubtitulo('mentis', text);   // que quede la frase completa un momento
        limpiarSubtitulos(3500);
        cuerpoSetEstado(turnInFlight ? 'PROCESSING' : 'STANDBY');
      };
      audio.onerror = () => {
        // El wav existe pero el <audio> no pudo reproducirlo: se cae al camino de Windows.
        console.warn('[Mentis] no se pudo reproducir la voz de NVIDIA, uso la de Windows');
        audioVoz = null;
        speakTextWindows(text);
      };
      await audio.play();
      return;
    }
    console.warn('[Mentis] voz de NVIDIA no disponible:', r && r.error);
  } catch (e) {
    console.warn('[Mentis] fallo la voz de NVIDIA:', e && e.message);
  }
  speakTextWindows(text);
}

function speakTextWindows(text) {
  if (!('speechSynthesis' in window) || !text) return;
  const doSpeak = () => {
    window.speechSynthesis.cancel();
    setTimeout(() => {
      const utterance = new SpeechSynthesisUtterance(text);
      const voice = pickSpanishVoice();
      if (voice) utterance.voice = voice;
      utterance.lang = voice ? voice.lang : 'es-ES';
      isPaused = false;
      utterance.onstart = () => { speechPauseBtn.classList.remove('hidden'); updatePauseIcon(); };
      utterance.onend = () => { speechPauseBtn.classList.add('hidden'); };
      utterance.onerror = (e) => {
        console.error('[Mentis] speechSynthesis falló:', e.error);
        speechPauseBtn.classList.add('hidden');
      };
      window.speechSynthesis.speak(utterance);
    }, 50);
  };
  if (window.speechSynthesis.getVoices().length > 0) {
    doSpeak();
  } else {
    const onReady = () => {
      window.speechSynthesis.removeEventListener('voiceschanged', onReady);
      doSpeak();
    };
    window.speechSynthesis.addEventListener('voiceschanged', onReady);
    setTimeout(onReady, 500);
  }
}

speechPauseBtn.addEventListener('click', () => {
  // La pausa tiene que cubrir los DOS caminos: el <audio> de la voz de NVIDIA y, si se cayo a
  // la de Windows, speechSynthesis. Sin esto el boton no hacia nada cuando hablaba NVIDIA.
  if (audioVoz) {
    if (isPaused) { audioVoz.play().catch(() => {}); } else { audioVoz.pause(); }
    isPaused = !isPaused;
    updatePauseIcon();
    return;
  }
  if (!window.speechSynthesis.speaking) return;
  if (isPaused) {
    window.speechSynthesis.resume();
  } else {
    window.speechSynthesis.pause();
  }
  isPaused = !isPaused;
  updatePauseIcon();
});

// ===== Catálogo "/" (pedido del usuario, 2026-07-12): al escribir "/" al principio del mensaje,
// aparece el catálogo de skills/plugins filtrable; con click o flechas+Enter se autocompleta. =====
const slashMenu = document.getElementById('slash-menu');
let slashMenuItems = [];
let slashMenuIndex = -1;

// Un comando ocupa el mensaje ENTERO (mismo contrato que _mc_match_capability en
// mentis-chat.sh: "$msg" = "$p" o empieza con "$p "), así que solo mostramos el catálogo si
// "/" está al principio del cuadro, no en cualquier posición del texto.
function slashMenuFilterFrom(value) {
  const m = value.match(/^(\/\S*)$/);
  return m ? m[1] : null;
}

function closeSlashMenu() {
  slashMenu.classList.add('hidden');
  slashMenu.innerHTML = '';
  slashMenuItems = [];
  slashMenuIndex = -1;
}

function updateSlashMenuActive() {
  [...slashMenu.children].forEach((el, i) => el.classList.toggle('active', i === slashMenuIndex));
}

function applySlashSelection(i) {
  const item = slashMenuItems[i];
  if (!item) return;
  messageInputEl.value = item.prefix + ' ';
  closeSlashMenu();
  messageInputEl.focus();
  const len = messageInputEl.value.length;
  messageInputEl.setSelectionRange(len, len);
}

function renderSlashMenu(filterText) {
  const query = filterText.slice(1).toLowerCase();
  slashMenuItems = capabilityCatalog.filter((c) => c.prefix.slice(1).toLowerCase().startsWith(query));
  slashMenu.innerHTML = '';
  if (slashMenuItems.length === 0) {
    closeSlashMenu();
    return;
  }
  slashMenuItems.forEach((item, i) => {
    const row = document.createElement('div');
    row.className = 'slash-item';
    row.setAttribute('role', 'option');
    const prefix = document.createElement('span');
    prefix.className = 'slash-item-prefix';
    prefix.textContent = item.prefix;
    const desc = document.createElement('span');
    desc.className = 'slash-item-desc';
    desc.textContent = item.description;
    row.appendChild(prefix);
    row.appendChild(desc);
    // mousedown (no click) + preventDefault: evita que el textarea pierda foco antes de que
    // se procese la selección (si no, el blur cierra el menú primero y el click no llega).
    row.addEventListener('mousedown', (e) => {
      e.preventDefault();
      applySlashSelection(i);
    });
    slashMenu.appendChild(row);
  });
  slashMenuIndex = 0;
  updateSlashMenuActive();
  slashMenu.classList.remove('hidden');
}

messageInputEl.addEventListener('input', () => {
  const filter = slashMenuFilterFrom(messageInputEl.value);
  if (filter) renderSlashMenu(filter);
  else closeSlashMenu();
});

messageInputEl.addEventListener('keydown', (e) => {
  if (slashMenu.classList.contains('hidden')) return;
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    slashMenuIndex = (slashMenuIndex + 1) % slashMenuItems.length;
    updateSlashMenuActive();
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    slashMenuIndex = (slashMenuIndex - 1 + slashMenuItems.length) % slashMenuItems.length;
    updateSlashMenuActive();
  } else if (e.key === 'Enter' || e.key === 'Tab') {
    e.preventDefault();
    applySlashSelection(slashMenuIndex);
  } else if (e.key === 'Escape') {
    e.preventDefault();
    closeSlashMenu();
  }
});

// Enter para enviar (pedido del usuario, 2026-07-15): Shift+Enter sigue siendo salto de linea.
// Se registra DESPUES del listener del menu "/" de arriba y chequea e.defaultPrevented (no
// la visibilidad del menu) porque ese listener puede cerrar el menu DENTRO del mismo evento
// (al aplicar una seleccion con Enter) -- si este handler revisara la clase "hidden" en vez
// de defaultPrevented, mandaria el mensaje de encima en el mismo Enter que eligio el slash.
messageInputEl.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || e.shiftKey || e.defaultPrevented) return;
  e.preventDefault();
  submitCurrentMessage();
});

messageInputEl.addEventListener('blur', () => setTimeout(closeSlashMenu, 150));

// Botón Detener (pedido del usuario, 2026-07-16): "deshacer" el turno en curso -- se cancela la
// respuesta, el mensaje que ya se había mandado desaparece del chat (como si nunca se hubiera
// enviado) y el texto original vuelve al cuadro de escritura para editarlo/reenviarlo. Si el
// mensaje tenía adjuntos, el texto devuelto trae los mismos tags "[archivo adjunto:...]" que
// ya entiende mentis-chat.sh -- reenviarlo tal cual sigue funcionando, aunque no se reconstruye
// la fila de chips visuales (alcance mínimo de la primera versión).
document.getElementById('btn-stop-turn').addEventListener('click', async () => {
  const btn = document.getElementById('btn-stop-turn');
  const textoAlEnviar = lastSentText;
  btn.disabled = true;
  try {
    const result = await window.mentisAPI.stopTurn();
    if (result && result.ok) {
      hideThinkingIndicator();
      renderMessagesWithBranches(result.entries || []);
      setBusy(false);
      // El backend solo devuelve texto si ALCANZÓ a persistirse en disco antes del frenado (raro
      // -- normalmente el turno recién se escribe al terminar). lastSentText es la fuente
      // confiable: se guardó ACÁ en el momento de mandar el mensaje.
      messageInputEl.value = result.revertedText || textoAlEnviar || '';
      lastSentText = null;
      messageInputEl.focus();
    }
  } finally {
    btn.disabled = false;
  }
});

// ===== Onboarding (pedido del usuario, 2026-07-13): pantalla guiada SOLO la primera vez que se
// abre la app -- no es publicación en ninguna tienda, es un wizard local de 3 pasos. =====
const ONBOARDING_STEPS = [
  {
    title: 'Bienvenido a Mentis',
    body: '<p>Tu asistente personal, con permiso para leer, escribir y ejecutar de verdad en tu computadora.</p>'
  },
  {
    title: 'Qué puede hacer ya mismo',
    body: `<p>Estas capacidades vienen activas por defecto en cada conversación:</p>
      <ul>
        <li>Navegar la web y usar Google Workspace (Drive, Docs, Sheets, Calendar, Gmail)</li>
        <li>Generar imágenes, modelos 3D y documentos reales (Word/PDF/PowerPoint/Excel)</li>
        <li>Ver tu pantalla y abrir archivos en VS Code</li>
      </ul>
      <p>Control de mouse/teclado y "modo sin frenos" quedan apagados por defecto -- los activás vos cuando los necesites, con confirmación.</p>`
  },
  {
    title: 'Listo para arrancar',
    body: `<p>Organizá trabajo grande en <strong>Proyectos</strong>, agregá tus propias skills desde el <strong>Directorio</strong>, y configurá tus propios modelos desde <strong>Configuración</strong>.</p>
      <p>Escribí lo que necesites cuando quieras.</p>`
  }
];
let onboardingStepIndex = 0;

function renderOnboardingStep() {
  const step = ONBOARDING_STEPS[onboardingStepIndex];
  const content = document.getElementById('onboarding-step-content');
  content.innerHTML = `<h2>${step.title}</h2>${step.body}`;
  const dots = document.getElementById('onboarding-dots');
  dots.innerHTML = '';
  ONBOARDING_STEPS.forEach((_s, i) => {
    const dot = document.createElement('span');
    dot.className = 'onboarding-dot' + (i === onboardingStepIndex ? ' active' : '');
    dots.appendChild(dot);
  });
  const nextBtn = document.getElementById('btn-onboarding-next');
  nextBtn.textContent = onboardingStepIndex === ONBOARDING_STEPS.length - 1 ? 'Empezar' : 'Siguiente';
}

async function finishOnboarding() {
  await window.mentisAPI.markOnboardingDone();
  document.getElementById('onboarding-overlay').classList.add('hidden');
}

document.getElementById('btn-onboarding-next').addEventListener('click', () => {
  if (onboardingStepIndex < ONBOARDING_STEPS.length - 1) {
    onboardingStepIndex += 1;
    renderOnboardingStep();
  } else {
    finishOnboarding();
  }
});
document.getElementById('btn-onboarding-skip').addEventListener('click', finishOnboarding);

async function maybeShowOnboarding() {
  const status = await window.mentisAPI.onboardingStatus();
  if (!status.done) {
    onboardingStepIndex = 0;
    renderOnboardingStep();
    document.getElementById('onboarding-overlay').classList.remove('hidden');
  }
}

// ===== Splash de arranque: logo "hablando" + hora/clima, despues fade-out (pedido del usuario,
// 2026-07-15) =====
// Reemplaza el saludo textual que antes vivia en renderEmptyState() (logo + burbuja random) --
// ese "hola" ahora pasa UNA sola vez por arranque de la app, hablado, no repetido cada vez que
// se abre una conversacion vacia.
function pickSplashGreeting(weather) {
  const now = new Date();
  const hour = now.getHours();
  const saludo = hour < 12 ? 'Buenos días' : hour < 20 ? 'Buenas tardes' : 'Buenas noches';
  const hora = now.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' });
  let texto = `${saludo}, señor. Son las ${hora}`;
  if (weather && weather.city && typeof weather.tempC === 'number') {
    texto += ` y el clima hoy en ${weather.city} es de ${Math.round(weather.tempC)} grados${weather.description ? ', ' + weather.description : ''}`;
  }
  return texto + '.';
}

// Mismo patron robusto que speakText() (esperar 'voiceschanged', delay chico entre cancel() y
// speak()) pero con un callback de finalizacion en vez de togglear el boton de pausa del chat --
// este saludo no tiene control de pausa, y necesita disparar el fade-out cuando termina.
// El audio del saludo, guardado aparte para poder cortarlo. Antes, saltear el splash con un
// click sacaba la pantalla pero la voz seguía sonando sola sobre una interfaz ya visible:
// speechSynthesis.cancel() no toca un <audio>, que es lo que usa la voz de NVIDIA.
let audioSplash = null;
function detenerAudioSplash() {
  if (!audioSplash) return;
  try { audioSplash.pause(); audioSplash.currentTime = 0; } catch { /* ya terminó */ }
  audioSplash = null;
}

async function speakSplashGreeting(text, onDone) {
  if (!text) { onDone(); return; }
  let done = false;
  const finish = () => { if (done) return; done = true; onDone(); };

  // El saludo de arranque también usa la voz de NVIDIA (la voz elegida). Es lo primero que el usuario
  // escucha al abrir Mentis, así que es justo donde más se nota la diferencia con la voz de
  // Windows. Si falla, sigue el camino viejo sin dejar el splash trabado.
  try {
    const r = await window.mentisAPI.tts(text);
    if (r && r.ok && r.path) {
      const audio = new Audio('file:///' + String(r.path).replace(/\\/g, '/').replace(/^\/+/, ''));
      audioSplash = audio;
      audio.onended = () => { audioSplash = null; finish(); };
      audio.onerror = () => { audioSplash = null; hablarSplashConWindows(); };
      await audio.play();
      setTimeout(finish, 20000);   // red de seguridad
      return;
    }
  } catch { /* sin voz de NVIDIA: se usa la de Windows */ }
  hablarSplashConWindows();

  function hablarSplashConWindows() {
  if (!('speechSynthesis' in window) || !text) { finish(); return; }
  const doSpeak = () => {
    window.speechSynthesis.cancel();
    setTimeout(() => {
      const utterance = new SpeechSynthesisUtterance(text);
      const voice = pickSpanishVoice();
      if (voice) utterance.voice = voice;
      utterance.lang = voice ? voice.lang : 'es-ES';
      utterance.onend = finish;
      utterance.onerror = finish;
      window.speechSynthesis.speak(utterance);
    }, 50);
  };
  if (window.speechSynthesis.getVoices().length > 0) {
    doSpeak();
  } else {
    const onReady = () => {
      window.speechSynthesis.removeEventListener('voiceschanged', onReady);
      doSpeak();
    };
    window.speechSynthesis.addEventListener('voiceschanged', onReady);
    setTimeout(onReady, 500);
  }
  // Red de seguridad: si ni onend ni onerror disparan nunca (bug conocido de Chromium en
  // sistemas sin voces instaladas), no se deja el splash trabado para siempre.
  setTimeout(finish, 12000);
  }
}

function runStartupSplash() {
  const overlay = document.getElementById('splash-overlay');
  if (!overlay) { maybeShowOnboarding(); return; }

  // Fix 2026-07-15 (modo bandeja): esta funcion ahora puede correr mas de una vez en la misma
  // pagina (ver mentis:replay-greeting mas abajo) -- si quedaron las clases de la vez anterior
  // (fade-out/hidden), hay que sacarlas antes de arrancar de nuevo o el splash ni se ve.
  overlay.classList.remove('fade-out', 'hidden');
  // El logo dejo de ser una imagen con animaciones de CSS: ahora es el cuerpo digital, y
  // "hablar" es un ESTADO suyo, no una clase. Si el modulo todavia no cargo (es diferido),
  // esto no rompe nada -- el splash igual funciona, solo sin cuerpo.
  cuerpoSetEstado('STANDBY');

  // PISO DE DURACIÓN (pedido del usuario, 2026-07-27: "apenas lo logré ver").
  // El splash ya esperaba el saludo completo -- medido, 5,58 s para un audio de 3,58 s -- pero
  // el saludo mismo puede salir corto: si el clima no llega a tiempo, el texto pasa de "Buenos
  // días, señor. Son las 10:45 y el clima hoy en Buenos Aires es de 18 grados, despejado" a
  // "Buenos días, señor. Son las 10:45", que es la mitad de largo. Y si la voz falla del todo,
  // el splash se cerraba casi al instante.
  // Con este piso, el arranque dura SIEMPRE lo suficiente para ver el cuerpo, hable o no hable:
  // lo que termina el splash es el último de los dos -- la voz o el piso.
  const PISO_SPLASH_MS = 4000;
  const arrancoEn = Date.now();

  let finished = false;
  // `forzado` = lo cortó el usuario con un click. El piso NO se le aplica: si toca la pantalla es
  // porque quiere entrar ya, y hacerlo esperar sería exactamente lo contrario de lo que pidió.
  const finishSplash = (forzado) => {
    if (finished) return;
    const falta = PISO_SPLASH_MS - (Date.now() - arrancoEn);
    if (!forzado && falta > 0) { setTimeout(finishSplash, falta); return; }
    finished = true;
    cuerpoSetEstado('STANDBY');
    overlay.classList.add('fade-out');
    let revealed = false;
    const reveal = () => {
      if (revealed) return;
      revealed = true;
      overlay.classList.add('hidden');
      overlay.removeEventListener('transitionend', reveal);
      maybeShowOnboarding();
    };
    overlay.addEventListener('transitionend', reveal);
    setTimeout(reveal, 900); // red de seguridad si transitionend no llega a disparar
  };

  // Salida rapida: un click en el splash lo saltea entero, para no dejar al usuario atrapado
  // escuchando el saludo completo si tiene apuro.
  overlay.addEventListener('click', () => {
    window.speechSynthesis.cancel();
    detenerAudioSplash();
    finishSplash(true);
  }, { once: true });

  // El saludo NO espera al clima para empezar a sonar (2026-07-27). Antes, si mentis-location.sh
  // tardaba, el splash se quedaba mudo ese tiempo y después decía una frase corta; el arranque
  // parecía roto justo en el momento en que Mentis se presenta. Ahora habla enseguida con lo que
  // tiene -- la hora, que siempre está -- y el clima se suma sólo si llegó a tiempo.
  const CLIMA_MAX_MS = 1500;
  const climaConPaciencia = Promise.race([
    window.mentisAPI.getLocationWeather().catch(() => null),
    new Promise((r) => setTimeout(() => r(null), CLIMA_MAX_MS))
  ]);
  climaConPaciencia.then((weather) => {
    cuerpoSetEstado('SPEAKING');
    speakSplashGreeting(pickSplashGreeting(weather), finishSplash);
  });
}

// Bienvenida al abrir la app (pedido del usuario, 2026-07-13): antes solo aparecía al tocar
// "Nueva conversación" -- ahora se ve de entrada, sin esperar ningún click. No crea una
// conversación real todavía (eso sigue pasando recién al mandar el primer mensaje).
renderEmptyState();
loadCapabilityCatalog();
refreshConversationList();
// El splash tapa todo esto mientras carga -- para cuando se desvanezca, la interfaz ya está
// poblada y lista para usar. maybeShowOnboarding() se llama DESPUES del splash (ver arriba),
// no en paralelo, para no superponer dos pantallas de bienvenida a la vez.
runStartupSplash();

// Fix 2026-07-15 (modo bandeja, bug real reportado por el usuario): con la ventana quedando viva en
// segundo plano (ver createTray/showMainWindow en main.js), esta página nunca se recarga entre
// una apertura y la siguiente -- sin esto, el saludo animado solo pasaba la primerísima vez que
// arrancaba el proceso, nunca más. main.js avisa acá cada vez que la ventana pasa de oculta a
// visible (abrir Mentis de verdad, no solo cambiar el foco entre ventanas ya visibles).
window.mentisAPI.onReplayGreeting(() => {
  runStartupSplash();
});

// ===== Botones de la barra de título propia (2026-07-28) =====
// Con frame:false, la ventana ya no trae los controles del sistema: los damos nosotros. El
// doble clic en la barra maximiza/restaura, como cualquier ventana de Windows -- si no está,
// se siente rota aunque los botones funcionen.
(() => {
  const acciones = {
    'btn-win-min': 'minimizar',
    'btn-win-max': 'maximizar',
    'btn-win-close': 'cerrar'
  };
  for (const [id, accion] of Object.entries(acciones)) {
    const btn = document.getElementById(id);
    if (btn) btn.addEventListener('click', () => window.mentisAPI.ventana(accion));
  }
  const barra = document.getElementById('barra-titulo');
  if (barra) {
    barra.addEventListener('dblclick', (ev) => {
      // Sólo si el doble clic fue en la barra misma, no en los botones.
      if (ev.target.closest('#barra-titulo-botones')) return;
      window.mentisAPI.ventana('maximizar');
    });
  }
})();
