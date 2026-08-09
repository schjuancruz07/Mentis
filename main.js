'use strict';
const { app, BrowserWindow, ipcMain, dialog, session, Menu, shell, Notification, globalShortcut, Tray, nativeImage } = require('electron');
// Identidad propia de la app ante Windows (pedido del usuario, 2026-07-15: que Mentis se pueda
// controlar como una app real, no como un proceso generico de electron.exe) -- sin esto,
// Windows agrupa el proceso bajo un ID generico compartido por CUALQUIER app Electron, lo que
// rompe el agrupado del taskbar/notificaciones y hace que herramientas de automatizacion no
// puedan distinguir "Mentis" de otra app Electron cualquiera corriendo en la maquina.
// 2026-07-28: el ID cambia de '...mentis' a '...mentis.app'. La barra de tareas de Windows guarda
// una cache propia por AppUserModelID (nombre + icono), que NO se limpia borrando iconcache.db ni
// reiniciando el Explorador. La entrada vieja habia quedado asociada al electron.exe de la version
// sin empaquetar -- por eso el boton de la barra seguia mostrando el atomo de Electron y el nombre
// "Electron" aunque el.exe empaquetado ya tuviera el icono y los metadatos correctos. Un ID nuevo
// no tiene cache: Windows lo resuelve de cero contra el ejecutable actual. Cambiarlo es barato
// (sirve para agrupar ventanas y para las notificaciones), y la entrada vieja queda huerfana sin
// molestar a nadie.
// Y VOLVIO A PASAR EL 2026-07-31, por una razon que la nota de arriba no contemplaba: los TESTS.
// test/pagina-celular-arranca.test.js hace require() de este mismo archivo para probar el arranque
// real, pero corriendo desde electron.exe -- asi que cada corrida de la suite registraba a Electron
// bajo el identificador de Mentis y le devolvia el atomo a la barra de tareas. Con cuatro corridas
// en una tarde alcanzo.
//
// El arreglo de fondo NO es cambiar el id otra vez (eso limpia el cache pero deja la trampa
// armada): es que la app empaquetada y todo lo que corra sin empaquetar tengan identidades
// DISTINTAS. Asi los tests pueden correr las veces que haga falta sin tocar la identidad de la app
// del usuario. El sufijo '2' de la version empaquetada limpia el cache envenenado de esta vuelta.
app.setAppUserModelId(app.isPackaged
  ? 'com.juancruzschneider.mentis.app2'
  : 'com.juancruzschneider.mentis.dev');

// Instancia unica (hallazgo real 2026-07-15, probando el modo bandeja): sin esto, abrir el
// acceso directo de Mentis (o cualquier lanzador que corra electron.exe de nuevo) mientras ya
// hay una corriendo levanta una SEGUNDA app completa en paralelo -- dos ventanas, dos procesos
// de bash, dos iconos de bandeja superpuestos, y el historial/proceso de fondo desincronizado
// entre ambas. Si esta instancia pierde la carrera por el lock, se cierra sola de inmediato y
// avisa a la que ya estaba viva para que se muestre/enfoque -- efecto neto: "abrir Mentis" con
// la app ya corriendo simplemente la trae al frente, en vez de duplicarla.
const singleInstanceLock = app.requestSingleInstanceLock();
if (!singleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => showMainWindow());
}

const path = require('path');
const os = require('os');
const fsSync = require('fs');
const { execFile, spawn } = require('child_process');
const { MentisProcess } = require('./lib/mentis-process');
const store = require('./lib/conversation-store');
const folderStore = require('./lib/folder-store');
const projectStore = require('./lib/project-store');
const settingsStore = require('./lib/settings-store');
const statsStore = require('./lib/stats-store');
const backupStore = require('./lib/backup-store');
const usageLedger = require('./lib/usage-ledger');
const searchStore = require('./lib/search-store');
const scheduleStore = require('./lib/schedule-store');
const branchStore = require('./lib/branch-store');

// EMPAQUETADA vs SIN EMPAQUETAR (2026-07-28). Sin empaquetar, la app vive en Mentis/app/ y su
// carpeta madre ES la de Mentis. Empaquetada, __dirname pasa a ser...\resources\app dentro del
//.exe, asi que este path.join daba...\resources -- una carpeta sin mentis-chat.sh, sin engine,
// sin conversations y sin memoria. La app habria arrancado igual y fallado en el primer turno.
// La cascara empaquetada NO se lleva el motor adentro a proposito: los datos del usuario (sus
// conversaciones, su memoria, sus creaciones) tienen que seguir viviendo en su carpeta, no
// adentro de un paquete que se reemplaza entero en cada build.
const MENTIS_ENV_DIR = process.env.MENTIS_HOME
  || (app.isPackaged ? path.join(app.getPath('home'), 'Mentis') : path.join(__dirname, '..'));
const TOOLSDIR = path.join(MENTIS_ENV_DIR, '..');
const CHAT_SCRIPT = path.join(MENTIS_ENV_DIR, 'mentis-chat.sh');
const CONV_DIR = path.join(MENTIS_ENV_DIR, 'conversations');
const APP_WORKSPACE_ROOT = path.join(MENTIS_ENV_DIR, 'workspace-app');
const ATTACHMENTS_DIR = path.join(APP_WORKSPACE_ROOT, 'attachments');
const CAPABILITIES_DIR = path.join(MENTIS_ENV_DIR, 'capabilities');
const MC_RESERVED_PREFIXES = new Set(['/stats', 'salir', 'exit']);

// spawn('bash') depende de que 'bash.exe' este en el PATH del proceso. Eso es
// cierto dentro de una terminal Git Bash (que arma su propio PATH por sesion),
// pero NO cuando la app se abre por doble clic desde el Explorador de Windows
// (que hereda el PATH persistente del usuario/sistema) -- ese PATH solo trae
// "Git\cmd" (para git.exe), no "Git\bin" ni "Git\usr\bin" (donde vive
// bash.exe), asi que ahi spawn tira ENOENT. Resolvemos una ruta absoluta
// probando las ubicaciones estandar de Git for Windows antes de caer al PATH.
function resolveBashPath() {
  if (process.env.MENTIS_APP_BASH) return process.env.MENTIS_APP_BASH;
  const candidates = [
    'C:\\Program Files\\Git\\bin\\bash.exe',
    'C:\\Program Files\\Git\\usr\\bin\\bash.exe',
    'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
    'C:\\Program Files (x86)\\Git\\usr\\bin\\bash.exe'
  ];
  for (const candidate of candidates) {
    if (fsSync.existsSync(candidate)) return candidate;
  }
  return 'bash';
}
const BASH_PATH = resolveBashPath();
const TRANSCRIBE_SCRIPT = path.join(MENTIS_ENV_DIR, 'mentis-transcribe.sh');
const TTS_SCRIPT = path.join(MENTIS_ENV_DIR, 'mentis-tts.sh');

// El servidor de transcripción se enciende al arrancar la app, en segundo plano y sin bloquear
// nada. Carga el modelo de voz una sola vez (~8 s); si se dejara para el momento en que el usuario
// habla, esa espera se la comería él justo cuando quiere usarlo. Encendido acá, para cuando
// diga la primera palabra ya está listo.
function encenderServidorDeVoz() {
  const script = path.join(MENTIS_ENV_DIR, 'mentis-transcribe.sh');
  if (!fsSync.existsSync(script)) return;
  execFile(BASH_PATH, [script, '--encender'], { timeout: 120000 }, (err) => {
    if (err) {
      sendToRenderer('mentis:log', '[mentis-app] el servidor de voz no arrancó: ' + String(err.message).slice(0, 120));
    }
  });

  // El servidor de SALIDA de voz también se precalienta acá (2026-07-27). Medido: la primera
  // síntesis con todo frío cuesta 3,9 s y las siguientes 1,5 s -- esos 2,4 s de diferencia son
  // autenticación y conexión gRPC, y no hay razón para que los pague el usuario justo cuando Mentis
  // tiene que contestarle por primera vez. Se hace diciendo algo mínimo a un archivo descartable.
  if (fsSync.existsSync(TTS_SCRIPT)) {
    const descartable = path.join(os.tmpdir(), 'mentis-tts-precalentado.wav');
    execFile(BASH_PATH, [TTS_SCRIPT, 'Listo.', descartable], { timeout: 120000 }, () => {
      // Falle o no, no se avisa nada: es una optimización, no una función. Si no anduvo, la
      // primera frase real simplemente tarda lo de siempre.
      fsSync.unlink(descartable, () => {});
    });
  }
}

// La página para hablarle a Mentis desde el celular se enciende con la app (pedido del usuario,
// 2026-07-30: "el servidor arranca solo"). Es idempotente: si ya estaba prendida, mentis-web.sh
// lo dice y no levanta una segunda.
//
// Vive mientras viva Mentis, no mientras esté la ventana abierta: cerrar con la X manda la app a
// la bandeja, y ahí es justamente cuando más sentido tiene poder escribirle desde el teléfono. Se
// apaga en el cierre de verdad (Salir desde la bandeja) -- un servicio escuchando en la red de
// casa después de que cerraste el programa es exactamente lo que nadie espera.
const WEB_SCRIPT = path.join(MENTIS_ENV_DIR, 'mentis-web.sh');
function encenderPaginaDelCelular() {
  if (!fsSync.existsSync(WEB_SCRIPT)) return;
  execFile(BASH_PATH, [WEB_SCRIPT, 'prender'], { timeout: 60000 }, (err, stdout) => {
    if (err) {
      sendToRenderer('mentis:log', '[mentis-app] la página del celular no arrancó: ' + String(err.message).slice(0, 120));
      return;
    }
    // La dirección lleva el token, así que se muestra en el log de la app (donde ya mira el usuario) y
    // no hay que ir a buscarla a la consola.
    const url = String(stdout || '').split('\n').map((l) => l.trim()).find((l) => l.startsWith('http'));
    if (url) sendToRenderer('mentis:log', '[mentis-app] página del celular lista: ' + url);
  });
}
function apagarPaginaDelCelular() {
  return new Promise((resolve) => {
    if (!fsSync.existsSync(WEB_SCRIPT)) return resolve();
    execFile(BASH_PATH, [WEB_SCRIPT, 'apagar'], { timeout: 20000 }, () => resolve());
  });
}

// Red de seguridad global (hallazgo real de investigacion 2026-07-14: no habia ningun
// process.on('uncaughtException'/'unhandledRejection') ni app.on('render-process-gone') en toda
// la app) -- esto NO reemplaza arreglar la causa de cada bug puntual (varios ya se arreglaron en
// su origen, ej. conversation-store.js), es la ultima linea de defensa para que un error NO
// contemplado no haga desaparecer la app en silencio sin dejar rastro, que es exactamente el
// sintoma que el usuario reporto encontrar mas de una vez.
const CRASH_LOG = path.join(MENTIS_ENV_DIR, 'mentis-app-crash.log');
function logCrash(label, err) {
  try {
    const line = `[${new Date().toISOString()}] ${label}: ${err && err.stack ? err.stack : String(err)}\n`;
    fsSync.appendFileSync(CRASH_LOG, line, 'utf-8');
  } catch { /* si ni loguear se puede, no hay mas nada que hacer aca */ }
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('mentis:log', `[mentis-app] ${label} (ver mentis-app-crash.log): ${err && err.message ? err.message : err}`);
  }
}
process.on('uncaughtException', (err) => logCrash('excepcion no capturada', err));
process.on('unhandledRejection', (reason) => logCrash('promesa rechazada sin manejar', reason));

let mainWindow = null;
let tray = null;
let isQuitting = false;
let quitCleanupDone = false;
let currentProcess = null;
// Ultimo proceso arrancado, se conserve o no como el actual: currentProcess se pone en null
// apenas el proceso muere, y sin esta referencia no queda a quien preguntarle por los nietos
// huerfanos que hayan sobrevivido (ver sweepOrphans en mentis-process.js).
let lastKnownProcess = null;
let currentConversationId = null;
let currentProcessFlags = [];
let turnInFlight = false;
// Botón Detener (pedido del usuario, 2026-07-16): distingue un forceKill INTENCIONAL (el usuario
// tocó "Detener") de un crash real, para que 'exit' no le muestre el toast de "se cortó
// inesperadamente" cuando en realidad el usuario lo frenó a propósito.
let stoppingTurn = false;

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

async function stopCurrentProcess() {
  if (currentProcess) {
    await currentProcess.stop();
    currentProcess = null;
  }
}

// Proyectos (pedido del usuario, 2026-07-13): si esta conversación es la de un proyecto, su ROOT
// pasa a ser la carpeta "Archivos" de ESE proyecto (no la compartida de siempre) -- así Mentis
// lee/escribe ahí, sin perder ninguna otra capacidad (browse/mcp/gen siguen igual).
function rootForConversation(id) {
  const project = projectStore.getProjectByConversation(CONV_DIR, id);
  return project ? project.workRoot : APP_WORKSPACE_ROOT;
}

// Notificaciones nativas (pedido del usuario, 2026-07-14): Mentis puede tardar minutos generando un
// video/imagen/3D -- si la ventana no tiene foco (el usuario esta haciendo otra cosa), un toast nativo
// de Windows avisa sin que tenga que estar mirando la app. Un click en la notificacion trae la
// ventana al frente. No molesta si la ventana ya esta enfocada (ahi ya se ve el resultado solo).
function notifyIfUnfocused(title, body) {
  if (!Notification.isSupported()) return;
  if (!mainWindow || mainWindow.isDestroyed() || mainWindow.isFocused()) return;
  const n = new Notification({ title, body: body.slice(0, 300), icon: path.join(__dirname, 'renderer', 'assets', 'mentis-cuerpo-256.png') });
  n.on('click', () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });
  n.show();
}

// Canal de aprobaciones: una carpeta compartida con el motor. Se limpia al arrancar para que un
// pedido viejo de una sesión que se cerró de golpe no aparezca como pregunta pendiente.
const APROBACION_DIR = path.join(os.tmpdir(), 'mentis-aprobaciones');
try {
  fsSync.rmSync(APROBACION_DIR, { recursive: true, force: true });
  fsSync.mkdirSync(APROBACION_DIR, { recursive: true });
  // Va por el entorno del proceso de la app: MentisProcess arranca bash con `...process.env`, así
  // que cada conversación lo hereda sin tener que pasarlo por parámetro en cada lugar. Si esta
  // variable NO está, el motor no tiene a quién preguntarle y rechaza igual que antes -- que es
  // justo lo que debe pasar cuando el motor corre desde una consola, sin app.
  process.env.MENTIS_APROBACION_DIR = APROBACION_DIR;
} catch { /* si no se puede crear, el motor simplemente rechaza como antes */ }

// Le pregunta al usuario por UNA acción concreta y le contesta al motor, que está esperando.
// El default de la ventana es "No" a propósito: si cierra el diálogo con Escape o con la X, la
// respuesta es que no. Un permiso arrancado por cansancio no es un permiso.
function atenderPedidoDeAprobacion(id, accion, detalle) {
  const respuesta = (valor) => {
    try { fsSync.writeFileSync(path.join(APROBACION_DIR, `${id}.respuesta`), valor, 'utf-8'); }
    catch { /* si no se puede escribir, al motor se le vence el tiempo y no ejecuta */ }
  };
  const opciones = {
    type: 'warning',
    buttons: ['No, cancelar', 'Sí, dale'],
    defaultId: 0,
    cancelId: 0,
    title: 'Mentis pide permiso',
    message: `Mentis quiere ${accion}.`,
    detail: `${detalle}\n\nEsto se aprueba una sola vez, para esta acción.`,
    noLink: true
  };
  const mostrar = mainWindow && !mainWindow.isDestroyed()
    ? dialog.showMessageBox(mainWindow, opciones)
    : dialog.showMessageBox(opciones);
  mostrar.then((r) => respuesta(r.response === 1 ? 'si' : 'no')).catch(() => respuesta('no'));
}

function startProcessForConversation(id, flags) {
  const histPath = store.conversationPath(CONV_DIR, id);
  const args = [...flags, '-d', rootForConversation(id), '-H', histPath];
  const proc = new MentisProcess({ bashPath: BASH_PATH, scriptPath: CHAT_SCRIPT, args });
  // Computer-use en vivo (pedido del usuario, 2026-07-16): 'screen'/'control' en nv-agent.sh
  // imprimen "... -> <ruta_de_la_captura>" en stderr cuando sacan una captura. Se detecta ese
  // marker, se manda la ruta aparte por un canal dedicado (para la ventanita en vivo) y se
  // manda la línea SIN la ruta al log normal (que ya se ve en el panel de progreso).
  // 'webcam <accion>' se sumó el 2026-07-30 (pedido del usuario: "que aparezca un recuadro que muestre
  // lo que está viendo por la webcam"). Hasta entonces la cámara sacaba la foto, un modelo la
  // describía y la foto se borraba: no había forma de contrastar la descripción con la realidad.
  const LIVE_PREVIEW_MARKER = /^(\[nv-agent\] iter \d+: (?:screen ver|control \S+|webcam \S+)) -> (.+)$/;
  // Aprobación por acción (2026-07-28): el motor pide permiso para UN comando concreto y se queda
  // esperando. Ver _pedir_aprobacion en nv-agent.sh.
  const APROBACION_MARKER = /^\[nv-agent\] APROBACION (\S+) :: (.+?) :: ([\s\S]*)$/;
  proc.on('log', (line) => {
    const ap = APROBACION_MARKER.exec(line);
    if (ap) {
      atenderPedidoDeAprobacion(ap[1], ap[2], ap[3]);
      sendToRenderer('mentis:log', `[mentis] Mentis pide permiso para ${ap[2]}`);
      return;
    }
    const m = LIVE_PREVIEW_MARKER.exec(line);
    if (m) {
      sendToRenderer('mentis:log', m[1]);
      sendToRenderer('mentis:live-preview', m[2]);
    } else {
      sendToRenderer('mentis:log', line);
    }
  });
  proc.on('turn-complete', () => {
    turnInFlight = false;
    const entries = store.readJsonlEntries(histPath);
    sendToRenderer('mentis:history-updated', entries);
    sendToRenderer('mentis:turn-complete', null);
    const last = entries[entries.length - 1];
    if (last && last.role === 'mentis') {
      const hasArtifacts = Array.isArray(last.artifacts) && last.artifacts.length > 0;
      const body = hasArtifacts
        ? `Termino de generar: ${last.artifacts.map((a) => path.basename(a)).join(', ')}`
        : (last.text || 'Mentis respondio.');
      notifyIfUnfocused('Mentis', body);
    }
  });
  proc.on('exit', (code) => {
    // Guard de identidad (bug real encontrado diseñando el botón Detener): forceKill() resuelve
    // en cuanto taskkill termina, pero el evento 'exit' de ESTE proceso puede llegar un instante
    // despues -- si para entonces mentis:stop-turn ya arrancó un proceso NUEVO para la misma
    // conversación, este handler (del proceso viejo) pisaría currentProcess con null de forma
    // tardía. Si ya no somos el proceso actual, no tocar nada del estado global.
    if (currentProcess !== proc) return;
    const wasInFlight = turnInFlight;
    turnInFlight = false;
    currentProcess = null;
    sendToRenderer('mentis:log', `[mentis-app] proceso terminado (code ${code})`);
    // Bug real reportado por el usuario (computer-use, 2026-07-18): cuando el proceso moria a mitad
    // de un turno, la UI se destrababa (input activo, botón Detener oculto) pero los NIETOS
    // seguian vivos gastando API -- nv-verify.sh lanzado con '&', el curl a NVIDIA en curso,
    // el daemon de navegador. `taskkill /T` no los alcanza (ERR-034) y nadie mas los limpiaba.
    // Se barren aca tambien, no solo en forceKill: un crash deja los mismos huerfanos.
    proc.sweepOrphans().then((r) => {
      if (r && r.killed > 0) {
        sendToRenderer('mentis:log', `[mentis-app] se cerraron ${r.killed} proceso(s) que habian quedado corriendo`);
      }
      fsSync.unlink(proc.pidFile, () => {});   // ya barrido: el registro no sirve mas
    }).catch(() => {});
    // Si fue un forceKill intencional (botón Detener), el handler de 'mentis:stop-turn' ya se
    // encarga de todo el resto (pop del historial, reinicio del proceso, aviso a la UI) -- acá
    // no hay que mostrar el toast de crash ni tocar nada más.
    if (wasInFlight && !stoppingTurn) {
      sendToRenderer('mentis:turn-error', { code });
      notifyIfUnfocused('Mentis', `El turno se cortó inesperadamente (code ${code}).`);
    }
  });
  proc.start();
  currentProcess = proc;
  lastKnownProcess = proc;
  currentConversationId = id;
  currentProcessFlags = flags;
}

ipcMain.handle('mentis:list-conversations', () => {
  store.ensureDir(CONV_DIR);
  return store.listConversations(CONV_DIR);
});

// Bug real encontrado en auditoria 2026-07-14: sin este flag, dos invocaciones concurrentes de
// este handler (ej. doble click rapido entre conversaciones) podian pisarse -- cada una hacia su
// propio `await stopCurrentProcess()` de forma independiente, y la segunda podia capturar
// `currentProcess` como null ANTES de que la primera terminara de arrancar el suyo, dejando el
// proceso de la primera huerfano (mentis-chat.sh real sigue vivo, con su cwd en la carpeta de un
// proyecto). Eso volvia ciego al chequeo de seguridad de `mentis:delete-project` (mas abajo, que
// solo mira `currentProcess`/`currentConversationId` actuales) ante ESE proceso huerfano
// especifico. El flag se setea de forma sincrona antes del primer `await`, asi que no hay ventana
// para que una segunda invocacion se cuele entre el chequeo y el seteo (JS de un solo hilo).
let switchingConversation = false;
ipcMain.handle('mentis:open-conversation', async (_event, { id, flags }) => {
  if (turnInFlight) throw new Error('hay un turno en curso, esperá a que termine');
  if (switchingConversation) throw new Error('ya se está cambiando de conversación, esperá un segundo');
  switchingConversation = true;
  try {
    await stopCurrentProcess();
    store.ensureDir(CONV_DIR);
    const finalId = id || store.newConversationId();
    startProcessForConversation(finalId, flags || []);
    const histPath = store.conversationPath(CONV_DIR, finalId);
    return { id: finalId, entries: store.readJsonlEntries(histPath) };
  } finally {
    switchingConversation = false;
  }
});

// Protocolo de pérdida de contexto (pedido del usuario, 2026-07-13): cuando una conversación se
// pone larga, mentis-chat.sh solo manda las ÚLTIMAS 20 entradas del historial como contexto
// (_mc_tail_history 20) -- lo de antes se pierde en silencio. Esto resume TODA la conversación
// con el prompt exacto que pidió el usuario, y arranca una conversación nueva con ese resumen ya
// puesto como primer mensaje de Mentis, para retomar sin perder el hilo.
const HANDOFF_PROMPT_HEADER = `Resumí todo lo que hemos hablado en este chat, incluye:
El objetivo principal
Las decisiones importantes que hemos tomado
el texto y/o código que creamos
los próximos pasos pendientes

Máximo 1000 palabras en formato estructurado. Incluí solo el contexto necesario en cada uno de estos campos para que en otra sesión no empieces con conocimiento.`;

function runAskNvidiaOneShot(role, prompt) {
  return new Promise((resolve, reject) => {
    const askScript = path.join(TOOLSDIR, 'ask-nvidia.sh');
    const proc = execFile(BASH_PATH, [askScript, '-r', role], { maxBuffer: 20 * 1024 * 1024, timeout: 120000 }, (err, stdout, stderr) => {
      if (err) return reject(new Error(String(stderr || err.message || err)));
      resolve(String(stdout || '').trim());
    });
    proc.stdin.write(prompt);
    proc.stdin.end();
  });
}

ipcMain.handle('mentis:summarize-and-handoff', async (_event, conversationId) => {
  if (!conversationId) throw new Error('no hay conversación activa para resumir');
  const histPath = store.conversationPath(CONV_DIR, conversationId);
  const entries = store.readJsonlEntries(histPath);
  if (entries.length === 0) throw new Error('esta conversación todavía no tiene mensajes para resumir');

  const transcript = entries.map((e) => `${e.role === 'usuario' ? 'el usuario' : 'Mentis'}: ${e.text}`).join('\n\n');
  const prompt = `${HANDOFF_PROMPT_HEADER}\n\nTRANSCRIPCIÓN COMPLETA DE LA CONVERSACIÓN A RESUMIR:\n\n${transcript}`;

  const summary = await runAskNvidiaOneShot('reason', prompt);

  const newId = store.newConversationId();
  const newHistPath = store.conversationPath(CONV_DIR, newId);
  const handoffText = `Retomamos desde acá — esto es lo que pasó en la conversación anterior:\n\n${summary}`;
  store.ensureDir(CONV_DIR);
  fsSync.appendFileSync(newHistPath, JSON.stringify({ role: 'mentis', text: handoffText, ts: new Date().toISOString() }) + '\n', 'utf-8');
  return { newConversationId: newId };
});

ipcMain.handle('mentis:send-message', (_event, message) => {
  if (!currentProcess) throw new Error('no hay una conversacion abierta');
  if (turnInFlight) throw new Error('hay un turno en curso, esperá a que termine');
  turnInFlight = true;
  currentProcess.send(message);
  return true;
});

// Botón Detener (pedido del usuario, 2026-07-16): a diferencia de "Frenar ya" (frenado de
// emergencia, solo visible con capacidades riesgosas activas, no revierte nada), esto es un
// "deshacer" -- cancela el turno en curso, saca el mensaje del usuario del historial persistido
// (mentis-chat.sh lo escribe ANTES de llamar al modelo, ver conversation-store.popLastJuanEntry)
// para que quede como si nunca se hubiera mandado, y reabre un proceso fresco para la MISMA
// conversación (mismos flags con los que se abrió) para que el usuario pueda seguir chateando sin
// tener que reabrirla él mismo. El texto original se devuelve para que la UI lo reponga en el
// cuadro de escritura.
ipcMain.handle('mentis:stop-turn', async () => {
  if (!currentProcess || !turnInFlight) return { ok: false };
  const id = currentConversationId;
  const flags = currentProcessFlags;
  const histPath = store.conversationPath(CONV_DIR, id);
  stoppingTurn = true;
  try {
    await currentProcess.forceKill();
    // Mismo motivo que en 'mentis:force-stop': una vez que arranca el proceso nuevo, el handler
    // 'exit' del viejo ya no toca turnInFlight (guard de identidad), y quedaba trabado en true.
    turnInFlight = false;
    const revertedText = store.popLastJuanEntry(histPath);
    startProcessForConversation(id, flags);
    const entries = store.readJsonlEntries(histPath);
    return { ok: true, revertedText, entries };
  } finally {
    stoppingTurn = false;
  }
});

// "Live": el renderer graba con MediaRecorder (webm/opus) y manda los bytes
// crudos acá. Se guardan a un archivo temporal y se transcriben con Whisper local
// (mentis-transcribe.sh, offline, sin llamar a ningun modelo de apoyo).
// Voz de Mentis (2026-07-26): antes hablaba con speechSynthesis de Windows (voz "Helena",
// robotica y de una sola entonacion). Ahora la genera magpie-tts-multilingual de NVIDIA, con la
// voz que eligio el usuario escuchando muestras reales: la voz elegida.
// Devuelve la ruta de un.wav temporal; el renderer lo reproduce con un <audio>. Si esto falla
// (sin internet, API caida), el renderer vuelve solo a speechSynthesis -- Mentis nunca se queda
// muda por un problema de red.
ipcMain.handle('mentis:tts', async (_event, texto) => {
  if (!texto || !fsSync.existsSync(TTS_SCRIPT)) return { ok: false, error: 'sin script de voz' };
  return await new Promise((resolve) => {
    execFile(BASH_PATH, [TTS_SCRIPT, String(texto)], { timeout: 60000, maxBuffer: 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, error: String(stderr || err.message).slice(0, 200) });
        const ruta = String(stdout).trim().split('\n').pop();
        if (!ruta || !fsSync.existsSync(ruta)) {
          return resolve({ ok: false, error: 'el script no dejo ningun archivo de audio' });
        }
        resolve({ ok: true, path: ruta });
      });
  });
});

ipcMain.handle('mentis:transcribe-audio', async (_event, audioBuffer) => {
  const tmpFile = path.join(os.tmpdir(), `mentis-voice-${Date.now()}.webm`);
  try {
    fsSync.writeFileSync(tmpFile, Buffer.from(audioBuffer));
    return await new Promise((resolve) => {
      execFile(BASH_PATH, [TRANSCRIBE_SCRIPT, tmpFile], { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
        if (err) {
          resolve({ ok: false, error: String(stderr || err.message || err) });
        } else {
          resolve({ ok: true, text: stdout.trim() });
        }
      });
    });
  } finally {
    fsSync.unlink(tmpFile, () => {});
  }
});

// Frenado de emergencia del "modo sin frenos" (ver mentis-process.js forceKill): mata el
// proceso YA, sin esperar a que termine el turno. proc.on('exit',...) ya definido arriba
// hace la limpieza de estado (turnInFlight, currentProcess) cuando el proceso efectivamente muere.
ipcMain.handle('mentis:force-stop', async () => {
  // Segundo bug real del mismo reporte: "Frenar ya" mataba el proceso y NO abria uno nuevo
  // (a diferencia del botón Detener, que si lo hace). El renderer recibia 'turn-error', volvia
  // a habilitar el input... y el siguiente mensaje moria con "no hay una conversacion abierta",
  // porque currentProcess habia quedado en null. Ahora se reabre un proceso fresco para la
  // MISMA conversacion. No se toca el historial: "Frenar ya" corta, no deshace (eso es Detener).
  if (!currentProcess) {
    // Sin proceso vivo todavia pueden quedar nietos huerfanos de un frenado anterior.
    const swept = lastKnownProcess ? await lastKnownProcess.sweepOrphans() : { killed: 0 };
    return { ok: true, method: 'no-process', orphansKilled: swept.killed || 0 };
  }
  const id = currentConversationId;
  const flags = currentProcessFlags;
  const result = await currentProcess.forceKill();
  // OJO con el orden: apenas arranque el proceso nuevo, el handler 'exit' del viejo se corta solo
  // por el guard de identidad (currentProcess !== proc) y ya no baja turnInFlight -- si no se
  // baja acá, queda trabado en true y todo mensaje posterior muere con "hay un turno en curso".
  turnInFlight = false;
  if (id) {
    try {
      startProcessForConversation(id, flags || []);
    } catch (err) {
      sendToRenderer('mentis:log', `[mentis-app] no se pudo reabrir la conversacion tras frenar: ${err && err.message ? err.message : err}`);
    }
  }
  return result;
});

// Proyectos (pedido del usuario, 2026-07-13): "botón Proyectos" -> mosaico de proyectos, cada uno
// con su propia carpeta real (Documents/Mentis/Proyectos/<nombre>/) y su propia conversación
// con TODAS las funciones normales del chat -- crearlo arma la carpeta Y la conversación juntas.
ipcMain.handle('mentis:list-projects', () => projectStore.listProjects(CONV_DIR));

ipcMain.handle('mentis:create-project', (_event, name) => {
  store.ensureDir(CONV_DIR);
  const conversationId = store.newConversationId();
  return projectStore.createProject(CONV_DIR, name, conversationId);
});

// Borrar proyecto (pedido del usuario, 2026-07-14, "botón para borrar el proyecto" en el mosaico):
// antes deleteProject SOLO sacaba el proyecto de projects.json, pero dejaba la carpeta real en
// Documents/Mentis/Proyectos huérfana en disco -- "borrar" a medias hubiera confundido más que
// ayudado (el usuario cree que borró algo y sigue estando ahí). Ahora borra AMBOS: el índice y la
// carpeta real, con el mismo chequeo de "adentro de la raíz de proyectos" que ya usa
// open-artifact para no borrar nada fuera de donde corresponde.
ipcMain.handle('mentis:delete-project', (_event, projectId) => {
  const project = projectStore.getProject(CONV_DIR, projectId);
  // Defensa en profundidad (2026-07-14): el renderer ya bloquea esto, pero si por lo que sea
  // llega igual acá, no se borra la carpeta debajo del proceso de mentis-chat.sh en curso.
  if (project && currentProcess && (project.conversationIds || []).includes(currentConversationId)) {
    return { ok: false, folderDeleted: false, error: 'hay una conversación de este proyecto activa en este momento' };
  }
  const removed = projectStore.deleteProject(CONV_DIR, projectId);
  if (removed && project && project.dir && _isWithin(projectStore.projectsRootDir(), project.dir)) {
    try {
      fsSync.rmSync(project.dir, { recursive: true, force: true });
    } catch (err) {
      return { ok: removed, folderDeleted: false, error: String(err && err.message ? err.message : err) };
    }
    return { ok: removed, folderDeleted: true };
  }
  return { ok: removed, folderDeleted: false };
});

// Historial scopeado por proyecto (pedido del usuario, 2026-07-13): un proyecto puede tener VARIAS
// conversaciones propias -- antes el mosaico de Proyectos abría directo la única conversación
// fija del proyecto; ahora hay una vista de detalle con la lista de SUS conversaciones nomás.
ipcMain.handle('mentis:list-project-conversations', (_event, projectId) => {
  const project = projectStore.getProject(CONV_DIR, projectId);
  if (!project) return [];
  // Bug real encontrado con verificación en vivo (2026-07-13): una conversación de proyecto
  // recién creada no tiene.jsonl en disco hasta el primer mensaje -- listConversations() (que
  // lee archivos) no la ve, así que desaparecía de la vista de detalle del proyecto justo
  // después de crearlo. Fix: recorrer conversationIds directo y sintetizar una entrada "vacía"
  // para las que todavía no tienen archivo, en vez de filtrar sobre lo que YA existe en disco.
  const byId = new Map(store.listConversations(CONV_DIR).map((c) => [c.id, c]));
  return (project.conversationIds || [])
.map((id) => byId.get(id) || { id, title: '(conversación vacía)', updatedAt: project.createdAt, entryCount: 0 })
.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
});

ipcMain.handle('mentis:create-project-conversation', (_event, projectId) => {
  const conversationId = store.newConversationId();
  const project = projectStore.addConversationToProject(CONV_DIR, projectId, conversationId);
  return { conversationId, project };
});

ipcMain.handle('mentis:project-for-conversation', (_event, conversationId) =>
  projectStore.getProjectByConversation(CONV_DIR, conversationId));

// Onboarding (pedido del usuario, 2026-07-13): pantalla guiada SOLO la primera vez que se abre la
// app -- no publicación real en ninguna tienda, es un wizard local. Un archivo marcador simple
// (no JSON complejo, no hace falta) alcanza para "ya la vi, no la muestres de nuevo".
const ONBOARDING_MARKER = path.join(MENTIS_ENV_DIR, '.onboarding-done');
ipcMain.handle('mentis:onboarding-status', () => ({ done: fsSync.existsSync(ONBOARDING_MARKER) }));
ipcMain.handle('mentis:mark-onboarding-done', () => {
  fsSync.writeFileSync(ONBOARDING_MARKER, new Date().toISOString(), 'utf-8');
  return { done: true };
});

// Configuración (pedido del usuario, 2026-07-13): modelos personalizados por rol + tema visual.
// Botones de la barra propia (2026-07-28). Con frame:false, minimizar/maximizar/cerrar dejan de
// existir como control del sistema y hay que darlos nosotros. 'cerrar' respeta lo de siempre:
// esconde la ventana en vez de matar la app, que sigue viva en la bandeja.
ipcMain.handle('mentis:ventana', (_event, accion) => {
  if (!mainWindow || mainWindow.isDestroyed()) return { ok: false };
  switch (accion) {
    case 'minimizar': mainWindow.minimize(); break;
    case 'maximizar':
      if (mainWindow.isMaximized()) mainWindow.unmaximize(); else mainWindow.maximize();
      break;
    case 'cerrar': mainWindow.close(); break;
    default: return { ok: false, error: 'accion desconocida' };
  }
  return { ok: true, maximizada: mainWindow.isMaximized() };
});

ipcMain.handle('mentis:get-settings', () => settingsStore.getPublicSettings(MENTIS_ENV_DIR));
ipcMain.handle('mentis:save-custom-model', (_event, { role, provider, baseUrl, model, apiKey }) => {
  settingsStore.saveCustomModel(MENTIS_ENV_DIR, role, { provider, baseUrl, model, apiKey });
  return settingsStore.getPublicSettings(MENTIS_ENV_DIR);
});
ipcMain.handle('mentis:remove-custom-model', (_event, role) => {
  settingsStore.removeCustomModel(MENTIS_ENV_DIR, role);
  return settingsStore.getPublicSettings(MENTIS_ENV_DIR);
});
ipcMain.handle('mentis:get-ideogram-status', () => settingsStore.getIdeogramStatus(MENTIS_ENV_DIR));
ipcMain.handle('mentis:save-ideogram-key', (_event, apiKey) => {
  settingsStore.saveIdeogramKey(MENTIS_ENV_DIR, apiKey);
  return settingsStore.getIdeogramStatus(MENTIS_ENV_DIR);
});
ipcMain.handle('mentis:remove-ideogram-key', () => {
  settingsStore.removeIdeogramKey(MENTIS_ENV_DIR);
  return settingsStore.getIdeogramStatus(MENTIS_ENV_DIR);
});

ipcMain.handle('mentis:get-runway-status', () => settingsStore.getRunwayStatus(MENTIS_ENV_DIR));
ipcMain.handle('mentis:save-runway-key', (_event, apiKey) => {
  settingsStore.saveRunwayKey(MENTIS_ENV_DIR, apiKey);
  return settingsStore.getRunwayStatus(MENTIS_ENV_DIR);
});
ipcMain.handle('mentis:remove-runway-key', () => {
  settingsStore.removeRunwayKey(MENTIS_ENV_DIR);
  return settingsStore.getRunwayStatus(MENTIS_ENV_DIR);
});
// Perfil + memoria adaptativa (pedido del usuario, 2026-07-13).
ipcMain.handle('mentis:save-voz', (_event, fields) => settingsStore.saveVoz(MENTIS_ENV_DIR, fields));
ipcMain.handle('mentis:save-profile', (_event, fields) => settingsStore.saveProfile(MENTIS_ENV_DIR, fields));
ipcMain.handle('mentis:save-user-memory', (_event, text) => settingsStore.saveUserMemory(MENTIS_ENV_DIR, text, 'usuario'));
ipcMain.handle('mentis:save-self-memory', (_event, text) => settingsStore.saveSelfMemory(MENTIS_ENV_DIR, text, 'usuario'));

const AVATAR_DIR = path.join(MENTIS_ENV_DIR, 'avatar');
ipcMain.handle('mentis:pick-avatar', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    filters: [{ name: 'Imágenes', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'] }]
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  const sourcePath = result.filePaths[0];
  fsSync.mkdirSync(AVATAR_DIR, { recursive: true });
  const destPath = path.join(AVATAR_DIR, 'avatar' + path.extname(sourcePath).toLowerCase());
  fsSync.copyFileSync(sourcePath, destPath);
  const profile = settingsStore.saveProfile(MENTIS_ENV_DIR, { avatarPath: destPath });
  return {...profile, avatarUrl: 'file://' + destPath.replace(/\\/g, '/') + '?t=' + Date.now() };
});

// Panel de estadísticas (pedido del usuario, 2026-07-13): calculado de verdad sobre
// conversations/*.jsonl, no valores de ejemplo -- ver lib/stats-store.js para qué se mide y qué
// se dejó deliberadamente afuera (tokens totales, sin fuente real de ese dato hoy).
ipcMain.handle('mentis:get-usage-stats', () => {
  store.ensureDir(CONV_DIR);
  return statsStore.computeStats(CONV_DIR);
});

ipcMain.handle('mentis:get-usage-costs', () => {
  return usageLedger.computeUsageCosts(path.join(MENTIS_ENV_DIR, 'usage-ledger.jsonl'));
});

// Búsqueda full-text sobre el historial de chats (pedido del usuario, 2026-07-14) -- une los
// resultados crudos (texto/snippet) con el titulo que ya usa el sidebar (listConversations),
// para no duplicar esa lógica de "titulo = primer mensaje de usuario".
ipcMain.handle('mentis:search-conversations', (_event, query) => {
  store.ensureDir(CONV_DIR);
  const results = searchStore.searchConversations(CONV_DIR, query);
  if (results.length === 0) return results;
  const titleById = new Map(store.listConversations(CONV_DIR).map((c) => [c.id, c.title]));
  return results.map((r) => ({...r, title: titleById.get(r.conversationId) || '(conversación)' }));
});

// Tareas programadas tipo cron (pedido del usuario, 2026-07-14): un scheduler simple que corre cada
// minuto, chequea con scheduleStore.computeDueTasks (logica pura, ya testeada) cuales hay que
// disparar, y las ejecuta UNA a la vez con un MentisProcess propio e independiente de
// currentProcess/turnInFlight (esas variables son del chat que el usuario tiene abierto en la UI, no
// de esto). Cada tarea tiene su propia conversacion dedicada (creada la primera vez que corre),
// agrupada en una carpeta fija "Tareas programadas" para que el usuario la encuentre facil en el
// sidebar y pueda revisar que paso.
const SCHEDULED_FOLDER_NAME = 'Tareas programadas';
const SCHEDULE_CHECK_INTERVAL_MS = 60000;
let scheduledTaskRunning = false;

function ensureScheduledFolder() {
  const { folders } = folderStore.loadFolders(CONV_DIR);
  const existing = folders.find((f) => f.name === SCHEDULED_FOLDER_NAME);
  if (existing) return existing.id;
  return folderStore.createFolder(CONV_DIR, SCHEDULED_FOLDER_NAME).id;
}

async function runScheduledTask(task) {
  try {
    store.ensureDir(CONV_DIR);
    let conversationId = task.conversationId;
    if (!conversationId) {
      conversationId = store.newConversationId();
      folderStore.assignConversation(CONV_DIR, conversationId, ensureScheduledFolder());
    }
    const histPath = store.conversationPath(CONV_DIR, conversationId);
    const proc = new MentisProcess({ bashPath: BASH_PATH, scriptPath: CHAT_SCRIPT, args: ['-d', APP_WORKSPACE_ROOT, '-H', histPath] });
    const done = new Promise((resolve) => proc.once('turn-complete', resolve));
    proc.start();
    proc.send(task.prompt);
    await done;
    await proc.stop();
    const entries = store.readJsonlEntries(histPath);
    const last = entries[entries.length - 1];
    const resultText = last && last.role === 'mentis' ? (last.text || '(sin respuesta)') : '(sin respuesta)';
    scheduleStore.updateTask(MENTIS_ENV_DIR, task.id, { conversationId, lastRunAt: new Date().toISOString(), lastResult: resultText.slice(0, 500) });
    notifyIfUnfocused('Mentis · ' + task.name, resultText.slice(0, 300));
  } catch (err) {
    const message = String(err && err.message ? err.message : err);
    scheduleStore.updateTask(MENTIS_ENV_DIR, task.id, { lastRunAt: new Date().toISOString(), lastResult: `ERROR: ${message}` });
    notifyIfUnfocused('Mentis · ' + task.name, `La tarea falló: ${message}`);
  } finally {
    sendToRenderer('mentis:scheduled-task-ran', { taskId: task.id });
  }
}

async function checkScheduledTasks() {
  if (scheduledTaskRunning) return; // una tarea a la vez, nunca en paralelo con otra programada
  const tasks = scheduleStore.loadTasks(MENTIS_ENV_DIR);
  const due = scheduleStore.computeDueTasks(tasks, new Date());
  if (due.length === 0) return;
  scheduledTaskRunning = true;
  try {
    for (const task of due) {
      await runScheduledTask(task);
    }
  } finally {
    scheduledTaskRunning = false;
  }
}

setInterval(() => { checkScheduledTasks().catch(() => {}); }, SCHEDULE_CHECK_INTERVAL_MS);

ipcMain.handle('mentis:list-scheduled-tasks', () => {
  return scheduleStore.loadTasks(MENTIS_ENV_DIR).map((t) => ({...t, scheduleLabel: scheduleStore.describeSchedule(t.schedule) }));
});
ipcMain.handle('mentis:create-scheduled-task', (_event, payload) => {
  try {
    return { ok: true, task: scheduleStore.createTask(MENTIS_ENV_DIR, payload) };
  } catch (err) {
    return { ok: false, error: String(err && err.message ? err.message : err) };
  }
});
ipcMain.handle('mentis:update-scheduled-task', (_event, { id, patch }) => {
  try {
    return { ok: true, task: scheduleStore.updateTask(MENTIS_ENV_DIR, id, patch) };
  } catch (err) {
    return { ok: false, error: String(err && err.message ? err.message : err) };
  }
});
ipcMain.handle('mentis:delete-scheduled-task', (_event, id) => {
  scheduleStore.deleteTask(MENTIS_ENV_DIR, id);
  return { ok: true };
});

// Edición de mensajes con ramas (pedido del usuario, 2026-07-14): crea la rama truncada (todo ANTES
// del mensaje editado) y espeja la asignación de carpeta/proyecto del original -- sin esto, la
// rama de una conversación de Proyecto aparecería suelta en el sidebar, perdiendo el contexto de
// a qué proyecto pertenecía. El mensaje editado en sí lo manda el renderer por el flujo normal
// de "enviar mensaje" (mentis:send-message), reusando la generación real de respuesta.
ipcMain.handle('mentis:create-branch', (_event, { conversationId, index }) => {
  try {
    store.ensureDir(CONV_DIR);
    const newId = branchStore.createBranch(CONV_DIR, conversationId, index);
    const project = projectStore.getProjectByConversation(CONV_DIR, conversationId);
    if (project) projectStore.addConversationToProject(CONV_DIR, project.id, newId);
    const { assignments } = folderStore.loadFolders(CONV_DIR);
    if (assignments[conversationId]) folderStore.assignConversation(CONV_DIR, newId, assignments[conversationId]);
    return { ok: true, conversationId: newId };
  } catch (err) {
    return { ok: false, error: String(err && err.message ? err.message : err) };
  }
});

ipcMain.handle('mentis:get-branch-siblings', (_event, conversationId) => {
  store.ensureDir(CONV_DIR);
  return branchStore.getSiblingGroups(CONV_DIR, conversationId);
});

ipcMain.handle('mentis:list-folders', () => folderStore.loadFolders(CONV_DIR));
ipcMain.handle('mentis:create-folder', (_event, name) => folderStore.createFolder(CONV_DIR, name));
ipcMain.handle('mentis:rename-folder', (_event, { id, name }) => folderStore.renameFolder(CONV_DIR, id, name));
ipcMain.handle('mentis:delete-folder', (_event, id) => folderStore.deleteFolder(CONV_DIR, id));
ipcMain.handle('mentis:assign-folder', (_event, { convId, folderId }) => {
  folderStore.assignConversation(CONV_DIR, convId, folderId);
});

// Backup/exportación completa (pedido del usuario, 2026-07-14): un ZIP con todo lo que el usuario no puede
// regenerar -- conversaciones, proyectos, memoria/perfil, skills. Deja afuera a propósito: las
// API keys (.custom-models-secrets.env, mcp-bridge/.secrets.env), archivos de estado transitorios,
// y las creaciones de IA (Imagenes/Videos/Documentos/Modelos-3D en Documents/Mentis) porque son
// regenerables y pueden pesar mucho -- si el usuario las quiere igual, ya están en esa carpeta aparte.
// La lógica en sí vive en lib/backup-store.js (testeable sin Electron); acá solo se arma la
// lista de fuentes y se maneja el diálogo nativo de guardado.
const MENTIS_DOCS_DIR = path.join(os.homedir(), 'Documents', 'Mentis');

ipcMain.handle('mentis:export-backup', async () => {
  const defaultName = `mentis-backup-${new Date().toISOString().slice(0, 10)}.zip`;
  const result = await dialog.showSaveDialog(mainWindow, {
    title: 'Exportar todos mis datos',
    defaultPath: path.join(os.homedir(), 'Desktop', defaultName),
    filters: [{ name: 'Archivo ZIP', extensions: ['zip'] }]
  });
  if (result.canceled || !result.filePath) return { ok: false, canceled: true };

  const sources = [
    { src: CONV_DIR, destName: 'conversaciones' },
    { src: path.join(MENTIS_ENV_DIR, 'mentis-settings.json'), destName: 'mentis-settings.json' },
    { src: CAPABILITIES_DIR, destName: 'capabilities' },
    { src: path.join(MENTIS_DOCS_DIR, 'Proyectos'), destName: 'Proyectos' },
    { src: path.join(MENTIS_DOCS_DIR, 'Vault'), destName: 'Vault' }
  ];
  try {
    return await backupStore.exportBackup(sources, result.filePath);
  } catch (err) {
    return { ok: false, error: String(err && err.message ? err.message : err) };
  }
});

const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp']);

// Adjuntos múltiples (pedido del usuario, 2026-07-13): antes solo dejaba elegir 1 archivo
// (properties: ['openFile']) y el renderer pisaba el adjunto anterior con cada nuevo click.
// Ahora el picker permite selección múltiple y siempre devuelve un array (aunque sea de 1),
// para que el renderer lo trate de forma uniforme.
function copyAttachment(sourcePath) {
  const fileName = path.basename(sourcePath);
  fsSync.mkdirSync(ATTACHMENTS_DIR, { recursive: true });
  let destPath = path.join(ATTACHMENTS_DIR, fileName);
  if (fsSync.existsSync(destPath) && fsSync.realpathSync(sourcePath) !== fsSync.realpathSync(destPath)) {
    const ext = path.extname(fileName);
    const base = path.basename(fileName, ext);
    destPath = path.join(ATTACHMENTS_DIR, `${base}-${Date.now()}${ext}`);
  }
  fsSync.copyFileSync(sourcePath, destPath);
  const finalName = path.basename(destPath);
  const isImage = IMAGE_EXTENSIONS.has(path.extname(finalName).toLowerCase());
  return {
    fileName: finalName,
    relativePath: path.join('attachments', finalName),
    isImage,
    previewUrl: isImage ? 'file://' + destPath.replace(/\\/g, '/') : null
  };
}

// Para que el renderer pueda mostrar una miniatura real de los adjuntos ya persistidos en el
// historial (hoy solo guarda la ruta relativa "attachments/<archivo>" en el tag del mensaje) --
// pedido del usuario, 2026-07-14: que la imagen se vea bien también DESPUÉS de mandarla, no solo
// en la previsualización del composer.
ipcMain.handle('mentis:get-workspace-root', () => APP_WORKSPACE_ROOT);

ipcMain.handle('mentis:pick-attachment', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: 'Imágenes', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp'] },
      { name: 'Todos los archivos', extensions: ['*'] }
    ]
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  return result.filePaths.map(copyAttachment);
});

function parseCapabilityHeader(firstLine) {
  const match = (firstLine || '').match(/^#\s*CAPABILITY:\s*(\S+)\s*\|\s*(.*)$/);
  if (!match) return null;
  return { prefix: match[1], description: match[2].trim() };
}

function listExistingCapabilityPrefixes() {
  const prefixes = new Set();
  if (!fsSync.existsSync(CAPABILITIES_DIR)) return prefixes;
  for (const fileName of fsSync.readdirSync(CAPABILITIES_DIR)) {
    if (!fileName.endsWith('.sh')) continue;
    const firstLine = fsSync.readFileSync(path.join(CAPABILITIES_DIR, fileName), 'utf-8').split('\n')[0];
    const parsed = parseCapabilityHeader(firstLine);
    if (parsed) prefixes.add(parsed.prefix);
  }
  return prefixes;
}

// Catálogo de skills/plugins para el autocomplete "/" del composer (pedido del usuario,
// 2026-07-12): mismo contrato que ya valida _mc_load_capabilities en mentis-chat.sh (header
// "# CAPABILITY: /prefijo | descripcion"), mas los comandos nucleo que no viven como archivo
// en capabilities/ (ver MC_RESERVED_PREFIXES en mentis-chat.sh).
const CORE_COMMANDS = [
  { prefix: '/stats', description: 'Ver contadores de la sesión actual (turnos, escrituras, ejecuciones)' }
];

function listCapabilityCatalog() {
  const items = [...CORE_COMMANDS];
  if (fsSync.existsSync(CAPABILITIES_DIR)) {
    for (const fileName of fsSync.readdirSync(CAPABILITIES_DIR)) {
      if (!fileName.endsWith('.sh')) continue;
      const firstLine = fsSync.readFileSync(path.join(CAPABILITIES_DIR, fileName), 'utf-8').split('\n')[0];
      const parsed = parseCapabilityHeader(firstLine);
      if (parsed) items.push(parsed);
    }
  }
  return items.sort((a, b) => a.prefix.localeCompare(b.prefix));
}

ipcMain.handle('mentis:list-capabilities', () => listCapabilityCatalog());

// Estado real de los conectores externos de Mentis, para la pestaña "Conectores" del
// Directorio (pedido del usuario, 2026-07-13: VS Code, Git Bash, Terminal, además de Google que ya
// existía). Chequeos reales (no supuestos): corre los binarios de verdad y ve si responden.
// OJO (bug real encontrado 2026-07-13): en Windows, "code" es un script.cmd, no un.exe --
// execFile SIN shell:true falla con ENOENT aunque el comando exista y funcione perfecto desde
// una terminal real (confirmado: "code --version" a mano funciona, pero execFile('code',...)
// sin shell tira "spawn code ENOENT"). bash.exe sí es un.exe real y no necesita esto -- por
// eso el flag es por-llamada, no global.
// Fix 2026-07-15 (freeze de ~1 min al abrir el panel de conectores): en Windows,
// execFile con shell:true arranca un cmd.exe que a su vez lanza el binario real
// (arduino-cli.exe, code.cmd); el "timeout" de execFile solo mata ese cmd.exe
// intermedio, no el proceso real -- si el binario cuelga (ej. arduino-cli
// intentando pegarle a la red para actualizar el indice de placas), el callback
// nunca dispara hasta que el proceso huerfano termina solo, ignorando el timeout
// declarado. Acá manejamos el timeout a mano y matamos el ÁRBOL de proceso
// completo con taskkill /T /F en vez de confiar en el timeout nativo de Node.
function execWithHardTimeout(bin, args, timeoutMs, useShell) {
  return new Promise((resolve) => {
    let settled = false;
    let child;
    try {
      child = spawn(bin, args, { shell: !!useShell, windowsHide: true });
    } catch {
      return resolve(null);
    }
    let stdout = '';
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      if (process.platform === 'win32' && child.pid) {
        execFile('taskkill', ['/pid', String(child.pid), '/t', '/f'], () => {});
      } else {
        try { child.kill('SIGKILL'); } catch {}
      }
      finish(null);
    }, timeoutMs);
    if (child.stdout) child.stdout.on('data', (c) => { stdout += c; });
    child.on('error', () => finish(null));
    child.on('close', (code) => {
      if (code !== 0) return finish(null);
      finish(stdout);
    });
  });
}

function execVersion(bin, args, useShell) {
  return execWithHardTimeout(bin, args, 5000, useShell)
.then((out) => (out ? String(out).trim().split('\n')[0] : null));
}

// Google Workspace (pedido del usuario, 2026-07-14): sacado de acá -- ahora vive en
// mcp-servers.json como cualquier otro conector MCP (ver getMcpConnectorsWithLiveStatus), así
// que mostrarlo también acá era un duplicado. Esto queda solo para capacidades LOCALES del
// entorno (no "aplicaciones externas conectadas" en el sentido que pidió el usuario).
// Arduino (pedido del usuario, 2026-07-14): igual que vscode, chequeo real corriendo el binario,
// no un "asumo que está" -- ademas de la version, mira si hay una placa REAL reconocida
// conectada (no solo un puerto serie generico tipo Bluetooth, ver mentis-arduino.sh boards).
function getArduinoBoardDetail() {
  return execWithHardTimeout('arduino-cli', ['board', 'list', '--format', 'json'], 8000, true)
.then((stdout) => {
      if (!stdout) return null;
      try {
        const data = JSON.parse(stdout);
        const ports = data.detected_ports || [];
        const matched = [];
        for (const p of ports) {
          for (const b of (p.matched_boards || [])) matched.push(b.name);
        }
        if (matched.length > 0) return `Placa conectada: ${matched.join(', ')}`;
        return ports.length > 0 ? 'Sin placa Arduino reconocida en los puertos serie actuales' : 'Sin puertos serie detectados';
      } catch {
        return null;
      }
    });
}

// Datos externos (pedido del usuario, 2026-07-15): chequeo real de si el CLI de Overture Maps
// esta instalado -- es la unica fuente de mentis-datos.sh que necesita algo mas que curl (pip
// install overturemaps). Las demas (Overpass, Georef, OpenSky, NASA, Internet Archive, DOAJ,
// Wikipedia) no necesitan chequeo: son solo HTTP, siempre "listas" si hay internet.
function getOvertureVersion() {
  return execWithHardTimeout('overturemaps', ['--version'], 5000, true).then((out) => {
    if (out) return out.trim().split('\n')[0];
    const winCli = path.join(os.homedir(), 'AppData', 'Roaming', 'Python', 'Python314', 'Scripts', 'overturemaps.exe');
    if (!fsSync.existsSync(winCli)) return null;
    return execWithHardTimeout(winCli, ['--version'], 5000, false).then((out2) => out2 ? out2.trim().split('\n')[0] : null);
  });
}

async function getConnectorStatus() {
  // Fix 2026-07-15: getArduinoBoardDetail ya NO se encadena después de saber si
  // arduino-cli existe (eso sumaba 5s+8s=13s de espera máxima en serie) -- corre
  // en paralelo con el resto; si arduino-cli no existe, su propio spawn falla
  // rápido y devuelve null sin costo extra real.
  const [vscodeVersion, bashVersion, arduinoVersion, arduinoBoardDetailRaw, overtureVersion] = await Promise.all([
    execVersion('code', ['--version'], true),
    execVersion(BASH_PATH, ['--version'], false),
    execVersion('arduino-cli', ['version'], true),
    getArduinoBoardDetail(),
    getOvertureVersion()
  ]);
  const vscodeEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:vscode');
  const terminalEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:terminal');
  const arduinoEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:arduino-cli');
  const datosEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:datos-externos');
  // La cámara arranca APAGADA (getConnectorEnabled devuelve false si nunca se tocó): es la única
  // herramienta que puede ver la habitación del usuario, así que se enciende a mano y a conciencia,
  // no por venir en el paquete.
  const webcamEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:webcam');
  const telefonoEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'local:telefono');
  // ¿Hay un teléfono vinculado ahora mismo? Se pregunta de verdad (KDE Connect) en vez de asumir:
  // el conector puede estar prendido y el teléfono apagado o en otra red, y eso hay que verlo.
  let telefonoDetalle = 'Sin vincular';
  try {
    const r = require('child_process').execFileSync(BASH_PATH, [path.join(MENTIS_ENV_DIR, 'mentis-telefono.sh'), 'estado'],
      { timeout: 15000, encoding: 'utf-8' });
    telefonoDetalle = String(r || '').trim().split(/\r?\n/)[0] || 'Sin vincular';
  } catch (e) {
    telefonoDetalle = 'Sin vincular o fuera de alcance';
  }
  const arduinoBoardDetail = arduinoVersion ? arduinoBoardDetailRaw : null;
  return [
    {
      // id con prefijo "local:" -- tiene que ser EXACTAMENTE la misma clave que lee
      // _connector_enabled() en nv-agent.sh (bug real encontrado en auditoria 2026-07-14: antes
      // el id expuesto al renderer era 'vscode' sin prefijo, el switch togglaba esa clave sin
      // prefijo, pero nv-agent.sh preguntaba por 'local:vscode' -- el switch no gateaba nada de
      // verdad y encima volvia a mostrarse "encendido" la proxima vez que se abria Directorio).
      id: 'local:vscode', name: 'VS Code', connected: !!vscodeVersion, enabled: vscodeEnabled, toggleable: true,
      detail: !vscodeEnabled ? 'Desactivado' : (vscodeVersion ? `Versión ${vscodeVersion}` : 'CLI "code" no encontrado en el PATH')
    },
    {
      id: 'local:gitbash', name: 'Git Bash', connected: !!bashVersion, enabled: true, toggleable: false,
      detail: bashVersion || 'No se encontró bash.exe'
    },
    {
      id: 'local:telefono', name: 'Teléfono', connected: /^conectado/.test(telefonoDetalle),
      enabled: telefonoEnabled, toggleable: true,
      detail: !telefonoEnabled
        ? 'Desactivado'
        : `${telefonoDetalle} — Mentis puede hacerlo sonar, avisarte en la pantalla, mandarte un archivo o un texto y leer tus notificaciones. No manda SMS ni le escribe a nadie por vos.`
    },
    {
      id: 'local:webcam', name: 'Cámara', connected: true, enabled: webcamEnabled, toggleable: true,
      detail: !webcamEnabled
        ? 'Desactivada'
        : 'Mentis puede sacar UNA foto cuando se lo pedís (mirar / leer / ver si estás). Se prende y se apaga en el acto, y la luz de la cámara se enciende siempre que la use.'
    },
    {
      id: 'local:terminal', name: 'Terminal', connected: true, enabled: terminalEnabled, toggleable: true,
      detail: !terminalEnabled ? 'Desactivado' : 'Ejecución real de comandos habilitada (tool exec, dentro de tu carpeta de trabajo)'
    },
    {
      // El id se mantiene en 'local:arduino-cli' aunque el conector ahora cubra mucho más que
      // Arduino: cambiarlo le borraría al usuario el estado guardado del interruptor. El nombre
      // visible sí cambia, porque es lo que él lee.
      id: 'local:arduino-cli', name: 'Hardware (Arduino, FPGA, impresora 3D)', connected: !!arduinoVersion, enabled: arduinoEnabled, toggleable: true,
      detail: !arduinoEnabled ? 'Desactivado' : (arduinoVersion ? `${arduinoVersion}${arduinoBoardDetail ? ' -- ' + arduinoBoardDetail : ''}` : 'arduino-cli no encontrado en el PATH')
    },
    {
      id: 'local:datos-externos', name: 'Datos externos', connected: true, enabled: datosEnabled, toggleable: true,
      detail: !datosEnabled
        ? 'Desactivado'
        : `Overpass/Georef/Nominatim/OpenSky/NASA/Archive/DOAJ/Wikipedia listos -- Overture Maps: ${overtureVersion ? overtureVersion : 'CLI no instalado (pip install overturemaps)'}`
    },
    {
      id: '', name: 'Carbohidratos', connected: true, enabled: carbsEnabled, toggleable: true,
      detail: !carbsEnabled ? 'Desactivado' : 'Estimación de carbohidratos vía NVIDIA NIM, sin API key -- nunca calcula dosis de '
    }
  ];
}

ipcMain.handle('mentis:connector-status', () => getConnectorStatus());

// Ubicación + clima (pedido del usuario, 2026-07-15, saludo animado de arranque): clima real,
// cacheado ~1h para no pegarle a la red en cada arranque si la app se reinicia seguido.
//
// 2026-07-25: la ubicación deja de estar HARDCODEADA. Estuvo fija en Villa Lugano desde el
// 2026-07-16 porque el geo-IP de entonces ubicaba mal (daba Lanús, ~10 km de error: el geo-IP
// resuelve la central del ISP, no la casa). el usuario pidió que Mentis sepa dónde está de verdad,
// así que ahora la mide `mentis-location.sh` con la API nativa de Windows (triangulación WiFi,
// ~150 m, sin API key ni costo) y la traduce a calle/barrio con OpenStreetMap.
// FALLBACK_LOCATION se conserva SOLO para el caso en que la medición falle (permiso revocado,
// servicio de ubicación apagado): sin él, el saludo se quedaría sin clima.
const LOCATION_CACHE_MS = 60 * 60 * 1000; // 1 hora
const FALLBACK_LOCATION = { city: 'Villa Lugano', lat: -34.6766149, lon: -58.4771849 };
const LOCATION_SCRIPT = path.join(MENTIS_ENV_DIR, 'mentis-location.sh');

// Devuelve { city, lat, lon } medidos de verdad, o el fallback si no se pudo medir.
function measureLocation() {
  return new Promise((resolve) => {
    if (!fsSync.existsSync(LOCATION_SCRIPT)) return resolve(FALLBACK_LOCATION);
    execFile(BASH_PATH, [LOCATION_SCRIPT], { timeout: 25000 }, (err, stdout) => {
      if (err) return resolve(FALLBACK_LOCATION);
      try {
        const d = JSON.parse(stdout);
        if (!d || !d.ok || typeof d.lat !== 'number') return resolve(FALLBACK_LOCATION);
        // Para el saludo hablado se prefiere el barrio ("Villa Lugano") sobre la ciudad
        // ("Buenos Aires"): es lo que el usuario diría si le preguntaran dónde está.
        return resolve({ city: d.barrio || d.ciudad || FALLBACK_LOCATION.city, lat: d.lat, lon: d.lon });
      } catch {
        return resolve(FALLBACK_LOCATION);
      }
    });
  });
}

function httpsGetJson(url) {
  return new Promise((resolve) => {
    const https = require('https');
    const req = https.get(url, { timeout: 6000 }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

const WEATHER_CODE_ES = {
  0: 'despejado', 1: 'mayormente despejado', 2: 'parcialmente nublado', 3: 'nublado',
  45: 'con niebla', 48: 'con niebla', 51: 'con llovizna', 53: 'con llovizna', 55: 'con llovizna',
  56: 'con llovizna helada', 57: 'con llovizna helada',
  61: 'con lluvia débil', 63: 'con lluvia', 65: 'con lluvia fuerte',
  66: 'con lluvia helada', 67: 'con lluvia helada',
  71: 'con nieve débil', 73: 'con nieve', 75: 'con nieve fuerte', 77: 'con nieve granulada',
  80: 'con chubascos débiles', 81: 'con chubascos', 82: 'con chubascos fuertes',
  85: 'con chubascos de nieve', 86: 'con chubascos de nieve fuertes',
  95: 'con tormenta', 96: 'con tormenta y granizo', 99: 'con tormenta fuerte y granizo'
};

async function fetchLocationWeather() {
  const loc = await measureLocation();
  const weather = await httpsGetJson(
    `https://api.open-meteo.com/v1/forecast?latitude=${loc.lat}&longitude=${loc.lon}&current=temperature_2m,weather_code`
  );
  if (!weather || !weather.current) return { city: loc.city, tempC: null, description: '' };
  return {
    city: loc.city,
    tempC: typeof weather.current.temperature_2m === 'number' ? weather.current.temperature_2m : null,
    description: WEATHER_CODE_ES[weather.current.weather_code] || ''
  };
}

async function getLocationWeather() {
  const cached = settingsStore.getLocationCache(MENTIS_ENV_DIR);
  if (cached && cached.cachedAt && (Date.now() - cached.cachedAt) < LOCATION_CACHE_MS) {
    return cached.data;
  }
  const fresh = await fetchLocationWeather();
  if (fresh) {
    settingsStore.setLocationCache(MENTIS_ENV_DIR, { data: fresh, cachedAt: Date.now() });
    return fresh;
  }
  return cached ? cached.data : null;
}

ipcMain.handle('mentis:get-location-weather', () => getLocationWeather());

// Conectores MCP (pedido del usuario, 2026-07-13): renombrado consistente a "Conectores" +
// click-derecho para ver cuáles están activos y desactivarlos. Distinto de getConnectorStatus
// de arriba (esa es solo un health-check de 4 integraciones locales fijas, de solo lectura) --
// esto lee/escribe mcp-servers.json de verdad, y si el puente MCP ya está levantado en esta
// sesión, le pega /reload para que el cambio aplique sin reiniciar la conversación.
const MCP_SERVERS_CONFIG = path.join(MENTIS_ENV_DIR, 'mcp-bridge', 'mcp-servers.json');
const MCP_BRIDGE_STATE = path.join(MENTIS_ENV_DIR, 'mcp-bridge-state.json');

function readMcpServersConfig() {
  try {
    return JSON.parse(fsSync.readFileSync(MCP_SERVERS_CONFIG, 'utf-8'));
  } catch {
    return [];
  }
}

function httpJson(port, urlPath, method, token) {
  return new Promise((resolve) => {
    const http = require('http');
    const headers = token ? { 'X-Mentis-Token': token } : {};
    const req = http.request(
      { host: '127.0.0.1', port, path: urlPath, method: method || 'GET', timeout: 4000, headers },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(null); } });
      }
    );
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
}

async function reloadMcpBridgeIfAlive() {
  if (!fsSync.existsSync(MCP_BRIDGE_STATE)) return null;
  try {
    const { port, token } = JSON.parse(fsSync.readFileSync(MCP_BRIDGE_STATE, 'utf-8'));
    if (!port) return null;
    return await httpJson(port, '/reload', 'POST', token);
  } catch {
    return null;
  }
}

ipcMain.handle('mentis:list-mcp-connectors', () =>
  readMcpServersConfig().map((s) => ({ name: s.name, type: s.type || 'stdio', enabled: s.enabled !== false })));

ipcMain.handle('mentis:toggle-mcp-connector', async (_event, { name, enabled }) => {
  const config = readMcpServersConfig();
  const entry = config.find((s) => s.name === name);
  if (!entry) throw new Error(`conector desconocido: ${name}`);
  entry.enabled = !!enabled;
  fsSync.writeFileSync(MCP_SERVERS_CONFIG, JSON.stringify(config, null, 2), 'utf-8');
  await reloadMcpBridgeIfAlive();
  return config.map((s) => ({ name: s.name, type: s.type || 'stdio', enabled: s.enabled !== false }));
});

// Conectores UNIFICADOS (pedido del usuario, 2026-07-14): "que aparezca Ideogram y todas las
// aplicaciones externas conectadas, automático" -- antes Directorio→Conectores (locales +
// health-checks) y el popup del composer (solo MCP) leían de DOS listas separadas, y cualquier
// integración nueva basada en API key (Ideogram) no aparecía en ninguna de las dos. Ahora hay
// UNA sola fuente (getUnifiedConnectors) que usan ambos lugares -- agregar un conector MCP nuevo
// via mcp-servers.json, o una key nueva acá abajo, alcanza para que aparezca en los dos.
function getApiKeyConnectors() {
  const ideogram = settingsStore.getIdeogramStatus(MENTIS_ENV_DIR);
  const ideogramEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'api:ideogram');
  const items = [
    {
      id: 'api:ideogram', name: 'Ideogram', kind: 'api-key', enabled: ideogramEnabled, toggleable: true,
      connected: ideogram.hasKey,
      detail: !ideogramEnabled ? 'Desactivado' : (ideogram.hasKey ? 'API key configurada' : 'Sin API key todavía (Configuración → Ideogram)')
    }
  ];
  const runway = settingsStore.getRunwayStatus(MENTIS_ENV_DIR);
  const runwayEnabled = settingsStore.getConnectorEnabled(MENTIS_ENV_DIR, 'api:runway');
  items.push({
    id: 'api:runway', name: 'Runway (video)', kind: 'api-key', enabled: runwayEnabled, toggleable: true,
    connected: runway.hasKey,
    detail: !runwayEnabled ? 'Desactivado' : (runway.hasKey ? 'API key configurada' : 'Sin API key todavía (Configuración → Video)')
  });
  return items;
}

// Estado EN VIVO de cada conector MCP: si el puente ya está corriendo en esta sesión, le
// pregunta de verdad (no asume); si no está corriendo todavía, connected queda en null
// ("se conecta recién cuando arranca una conversación", no es lo mismo que "roto").
async function getMcpConnectorsWithLiveStatus() {
  const config = readMcpServersConfig();
  let liveByName = null;
  if (fsSync.existsSync(MCP_BRIDGE_STATE)) {
    try {
      const { port, token } = JSON.parse(fsSync.readFileSync(MCP_BRIDGE_STATE, 'utf-8'));
      if (port) {
        const result = await httpJson(port, '/connectors', 'GET', token);
        if (result && Array.isArray(result.connectors)) {
          liveByName = new Map(result.connectors.map((c) => [c.name, c]));
        }
      }
    } catch { /* puente no disponible -- se sigue sin estado en vivo */ }
  }
  return config.map((s) => {
    const enabled = s.enabled !== false;
    const live = liveByName ? liveByName.get(s.name) : null;
    let connected = null; let detail = 'Se conecta cuando arranca una conversación';
    if (!enabled) { connected = false; detail = 'Desactivado'; }
    else if (live) {
      connected = live.connected;
      detail = live.connected ? `${live.toolCount} tool${live.toolCount === 1 ? '' : 's'}` : (live.error || 'no se pudo conectar');
    }
    return { id: 'mcp:' + s.name, name: s.name, kind: 'mcp', enabled, connected, detail };
  });
}

async function getUnifiedConnectors() {
  const [local, mcp] = await Promise.all([getConnectorStatus(), getMcpConnectorsWithLiveStatus()]);
  const localMapped = local.map((c) => ({...c, kind: 'local' }));
  return [...localMapped,...mcp.map((c) => ({...c, toggleable: true })),...getApiKeyConnectors()];
}

ipcMain.handle('mentis:list-all-connectors', () => getUnifiedConnectors());

// Switch real para TODAS las filas (pedido del usuario, 2026-07-14) -- antes solo los MCP
// (mentis:toggle-mcp-connector) podian togglearse de verdad; esto persiste el flag para
// locales/api-key en mentis-settings.json y nv-agent.sh lo lee para gatear exec/vscode/gen.
ipcMain.handle('mentis:toggle-connector', (_event, { id, enabled }) => {
  settingsStore.setConnectorEnabled(MENTIS_ENV_DIR, id, enabled);
  return getUnifiedConnectors();
});

// Agregar plugin/skill propio de Mentis: el archivo elegido tiene que declarar
// "# CAPABILITY: /prefijo | descripcion" en su primera linea (mismo contrato
// que ya valida _mc_load_capabilities en mentis-chat.sh) -- se replica la
// validacion aca para dar feedback inmediato en la UI, en vez de copiar un
// archivo invalido y recien enterarse cuando mentis-chat.sh falle al cargar
// TODAS las capabilities la proxima vez que arranque.
ipcMain.handle('mentis:pick-capability', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    filters: [
      { name: 'Scripts', extensions: ['sh'] },
      { name: 'Todos los archivos', extensions: ['*'] }
    ]
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  const sourcePath = result.filePaths[0];
  let firstLine;
  try {
    firstLine = fsSync.readFileSync(sourcePath, 'utf-8').split('\n')[0];
  } catch {
    return { ok: false, error: 'No se pudo leer el archivo elegido.' };
  }
  const parsed = parseCapabilityHeader(firstLine);
  if (!parsed) {
    return { ok: false, error: 'El archivo no tiene el formato esperado. La primera línea debe ser: # CAPABILITY: /prefijo | descripción' };
  }
  if (MC_RESERVED_PREFIXES.has(parsed.prefix)) {
    return { ok: false, error: `"${parsed.prefix}" es un prefijo reservado del núcleo de Mentis, no se puede usar.` };
  }
  if (listExistingCapabilityPrefixes().has(parsed.prefix)) {
    return { ok: false, error: `Ya existe una capability con el prefijo "${parsed.prefix}". Elegí otro archivo o cambiá el prefijo.` };
  }
  fsSync.mkdirSync(CAPABILITIES_DIR, { recursive: true });
  const destName = parsed.prefix.replace(/^\//, '') + '.sh';
  const destPath = path.join(CAPABILITIES_DIR, destName);
  fsSync.copyFileSync(sourcePath, destPath);
  return { ok: true, prefix: parsed.prefix, description: parsed.description, fileName: destName };
});

// Crear una skill nueva DESDE la UI (pedido del usuario, 2026-07-13): hasta ahora solo se podía
// "importar" un.sh ya escrito a mano con el header correcto -- esto genera ese.sh por vos, con
// la misma validación que pick-capability (prefijo no reservado, no duplicado).
ipcMain.handle('mentis:create-capability', (_event, { prefix, description, body }) => {
  const cleanPrefix = (prefix || '').trim();
  const cleanDesc = (description || '').trim();
  const cleanBody = (body || '').trim();
  if (!/^\/[a-z0-9-]+$/.test(cleanPrefix)) {
    return { ok: false, error: 'El prefijo tiene que empezar con "/" y usar solo minúsculas, números y guiones (ej. /traducir).' };
  }
  if (!cleanDesc) return { ok: false, error: 'Falta la descripción.' };
  if (!cleanBody) return { ok: false, error: 'Falta el cuerpo de la skill (qué hace cuando se invoca).' };
  if (MC_RESERVED_PREFIXES.has(cleanPrefix)) {
    return { ok: false, error: `"${cleanPrefix}" es un prefijo reservado del núcleo de Mentis, no se puede usar.` };
  }
  if (listExistingCapabilityPrefixes().has(cleanPrefix)) {
    return { ok: false, error: `Ya existe una capability con el prefijo "${cleanPrefix}". Elegí otro.` };
  }
  fsSync.mkdirSync(CAPABILITIES_DIR, { recursive: true });
  const destName = cleanPrefix.replace(/^\//, '') + '.sh';
  const destPath = path.join(CAPABILITIES_DIR, destName);
  // OJO (bug real encontrado con verificación en vivo, 2026-07-13): el header "# CAPABILITY:"
  // tiene que ser la línea 1 exacta -- tanto listCapabilityCatalog() acá como
  // _mc_load_capabilities en mentis-chat.sh leen SOLO la primera línea del archivo. Un shebang
  // antes lo rompía en silencio: el archivo se creaba bien pero quedaba invisible en el
  // catálogo Y no cargaba como capability real (mismo bug que tuvo capabilities/conectar.sh).
  const content = `# CAPABILITY: ${cleanPrefix} | ${cleanDesc}\n${cleanBody}\n`;
  fsSync.writeFileSync(destPath, content, 'utf-8');
  return { ok: true, prefix: cleanPrefix, description: cleanDesc, fileName: destName };
});

ipcMain.handle('mentis:read-workspace-file', (_event, relPath) => {
  try {
    const root = path.resolve(APP_WORKSPACE_ROOT) + path.sep;
    const abs = path.resolve(APP_WORKSPACE_ROOT, relPath);
    if (!(abs + path.sep).startsWith(root) && abs !== path.resolve(APP_WORKSPACE_ROOT)) return null;
    const stat = fsSync.statSync(abs);
    if (!stat.isFile()) return null;
    const content = fsSync.readFileSync(abs, 'utf-8');
    return content.length > 4000 ? content.slice(0, 4000) + '\n… (truncado)' : content;
  } catch {
    return null;
  }
});

// Boton "abrir archivo" para artefactos que Mentis creo/genero en el turno (write, gen
// image/3d/doc, o un link de Google Drive/Docs/Sheets devuelto por una llamada MCP).
// Un artefacto es o bien una ruta relativa a APP_WORKSPACE_ROOT, o bien una URL http(s)
// completa (Google) -- se distinguen por el prefijo, no hace falta que el caller lo declare.
// Misma carpeta fija que MENTIS_CREATIONS_DIR en nv-agent.sh -- "gen" ahora manda la ruta
// COMPLETA (no relativa al workspace) porque los archivos generados viven ahi, no en ROOT.
const MENTIS_CREATIONS_DIR = path.join(os.homedir(), 'Documents', 'Mentis');

function _isWithin(parent, target) {
  const parentWithSep = path.resolve(parent) + path.sep;
  const resolved = path.resolve(target);
  return resolved === path.resolve(parent) || (resolved + path.sep).startsWith(parentWithSep);
}

ipcMain.handle('mentis:open-artifact', async (_event, artifact) => {
  if (typeof artifact !== 'string' || !artifact.trim()) return { ok: false, error: 'artefacto invalido' };
  if (/^https?:\/\//i.test(artifact)) {
    await shell.openExternal(artifact);
    return { ok: true };
  }
  let abs;
  if (path.isAbsolute(artifact)) {
    if (!_isWithin(MENTIS_CREATIONS_DIR, artifact)) {
      return { ok: false, error: 'ruta fuera de la carpeta de creaciones de Mentis' };
    }
    abs = path.resolve(artifact);
  } else {
    abs = path.resolve(APP_WORKSPACE_ROOT, artifact);
    if (!_isWithin(APP_WORKSPACE_ROOT, abs)) {
      return { ok: false, error: 'ruta fuera del workspace' };
    }
  }
  if (!fsSync.existsSync(abs)) {
    return { ok: false, error: 'el archivo ya no existe' };
  }
  const result = await shell.openPath(abs);
  if (result) return { ok: false, error: result };
  return { ok: true };
});

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 720,
    backgroundColor: '#0a0a0b',
    // Marco propio (pedido del usuario, 2026-07-28: "cambiar de color la barra esa azul a negro").
    // Esa barra azul es el marco NATIVO de Windows y su color lo decide el sistema, no la app:
    // no hay forma de pintarla desde acá. La única manera de tenerla negra es no usarla y dibujar
    // la nuestra. Se va con ella el menú File/Edit/View/Window, que el usuario confirmó que no usa.
    frame: false,
    // El ícono es el cuerpo digital renderizado de verdad. Se usa el.ICO y no el PNG de 256
    // (2026-07-28): Windows pide el ícono en varios tamaños -- 16 para la barra de título, 32
    // para la barra de tareas, 24 para la bandeja -- y si sólo se le da uno grande, lo reescala
    // él y queda embarrado. El.ico trae cada tamaño reducido por separado. Además tiene fondo
    // transparente: el PNG anterior era una captura con su fondo negro, y ese cuadrado oscuro
    // alrededor era justamente lo que se veía mal.
    icon: path.join(__dirname, 'renderer', 'assets', 'mentis-cuerpo.ico'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });
  // setIcon() explícito además del `icon:` de arriba (2026-07-28). Corriendo sin empaquetar,
  // Windows tiende a mostrar el ícono de electron.exe en la barra de tareas y a ignorar el que
  // se declaró al crear la ventana; setIcon manda un WM_SETICON de verdad, que es lo que la
  // barra de tareas y la barra de título miran. No reemplaza empaquetar la app, pero es lo que
  // hace que se vea el ícono correcto mientras tanto.
  try {
    mainWindow.setIcon(nativeImage.createFromPath(
      path.join(__dirname, 'renderer', 'assets', 'mentis-cuerpo.ico')));
  } catch { /* si falla, queda el de `icon:`; no vale romper el arranque por un ícono */ }

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  // Mismo hallazgo que la red de seguridad global de arriba: si el renderer crashea (OOM, killed
  // por el SO, GPU crash) no habia ningun log ni intento de recuperacion -- la ventana quedaba en
  // blanco sin ninguna pista de qué paso. Se loguea y se recarga la pagina automaticamente salvo
  // que haya sido un cierre limpio ('clean-exit').
  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    if (details.reason === 'clean-exit') return;
    logCrash(`renderer crasheo (reason: ${details.reason}, exitCode: ${details.exitCode})`, new Error(details.reason));
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.reload();
  });

  mainWindow.webContents.on('context-menu', (_event, params) => {
    if (!params.misspelledWord) return;
    const template = params.dictionarySuggestions.map((suggestion) => ({
      label: suggestion,
      click: () => mainWindow.webContents.replaceMisspelling(suggestion)
    }));
    if (template.length === 0) {
      template.push({ label: 'Sin sugerencias', enabled: false });
    }
    template.push({ type: 'separator' });
    template.push({
      label: 'Agregar al diccionario',
      click: () => session.defaultSession.addWordToSpellCheckerDictionary(params.misspelledWord)
    });
    Menu.buildFromTemplate(template).popup();
  });

  // Modo bandeja (pedido del usuario, 2026-07-15): para que el atajo global de "inicio rapido"
  // sirva de verdad como lanzador (no solo para reenfocar una ventana ya abierta), Mentis tiene
  // que seguir viva en segundo plano aunque cierres la ventana con la X -- si no, no hay ningun
  // proceso corriendo que pueda escuchar el atajo. Cerrar con la X ahora oculta la ventana en
  // vez de destruirla; la unica forma de salir de verdad es "Salir" desde el icono de la bandeja
  // (o Alt+F4/cerrar desde el Administrador de tareas, que sigue funcionando como siempre).
  mainWindow.on('close', (event) => {
    if (isQuitting) return;
    event.preventDefault();
    mainWindow.hide();
  });
}

function showMainWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  // Fix 2026-07-15 (bug real reportado por el usuario): el saludo animado de arranque vive en
  // renderer.js y corre UNA vez cuando la pagina carga -- eso funcionaba bien cuando cerrar la
  // ventana mataba el proceso entero (cada apertura era una pagina nueva). Con el modo bandeja
  // (la ventana se OCULTA, no se destruye) la pagina nunca se recarga, asi que el saludo no
  // volvia a pasar nunca mas despues de la primera vez. Se detecta la transicion oculta->visible
  // (eso SI corresponde a "el usuario volvio a abrir Mentis", a diferencia de solo cambiar de foco
  // entre ventanas ya visibles) y se le avisa al renderer que repita el saludo.
  const wasHidden = !mainWindow.isVisible();
  if (mainWindow.isMinimized()) mainWindow.restore();
  if (!mainWindow.isVisible()) mainWindow.show();
  mainWindow.focus();
  if (wasHidden) {
    mainWindow.webContents.send('mentis:replay-greeting');
  }
}

function createTray() {
  // Fix 2026-07-15: el.ico multi-resolucion (7 tamaños embebidos) confundia a Windows para el
  // icono de bandeja -- new Tray(ruta) no tiraba error y el objeto quedaba vivo, pero el icono
  // nunca aparecia realmente en la bandeja (ni visible ni en el desplegable de ocultos). Forzar
  // un nativeImage de 16x16 explicito (tamaño real de bandeja en Windows) en vez de dejar que
  // Electron elija una resolucion del.ico resuelve la ambiguedad.
  // Para la bandeja se usa el PNG de 16 ya generado a ese tamaño, sin reescalar acá: cada tamaño
  // se redujo por separado desde el render grande, que es lo que hace que el núcleo se siga
  // distinguiendo. Reescalar en caliente desde uno más grande era lo que lo convertía en una
  // mancha (y el fondo negro del PNG viejo agregaba el recuadro que se veía mal).
  const icon = nativeImage.createFromPath(path.join(__dirname, 'renderer', 'assets', 'mentis-cuerpo-16.png'));
  tray = new Tray(icon);
  tray.setToolTip('Mentis');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Abrir Mentis', click: showMainWindow },
    { type: 'separator' },
    {
      label: 'Salir',
      click: () => {
        isQuitting = true;
        app.quit();
      }
    }
  ]));
  // Un solo click (no solo el menu contextual) tambien muestra la ventana -- comportamiento
  // esperable de cualquier icono de bandeja en Windows.
  tray.on('click', showMainWindow);
}

// Kai Vault: escaneo continuo (pedido del usuario, 2026-07-14, "que escanee constantemente para
// actualizarse solo") -- reindexa automáticamente cuando detecta cambios reales en el
// ecosistema, sin que el usuario tenga que acordarse de correr /boveda reindexar a mano. El corpus es
// chico (~600 chunks) y un reindexado completo tarda ~30s, así que no hace falta un motor
// incremental de verdad: debounce de 60s tras el último cambio + reusa boveda.sh reindexar.
const KAI_WATCH_DEBOUNCE_MS = 60000;
const KAI_WATCH_IGNORE_DIRS = new Set([
  'node_modules', '.git', 'conversations', 'workspace-app', 'workspace', 'avatar', 'logs', 'index'
]);
const KAI_WATCH_IGNORE_FILES = new Set([
  'state.json', 'mcp-bridge-state.json', 'browser-daemon-state.json',
  'calls.log', 'server.log', 'server.log.err', 'kai-vault-watch.log'
]);
const KAI_WATCH_LOG = path.join(MENTIS_ENV_DIR, 'kai-vault-watch.log');
let kaiReindexTimer = null;
let kaiReindexRunning = false;
let kaiReindexPending = false;

function kaiWatchLog(line) {
  try { fsSync.appendFileSync(KAI_WATCH_LOG, `[${new Date().toISOString()}] ${line}\n`, 'utf-8'); } catch { /* no bloquea nada si falla el log */ }
}

function runKaiReindex() {
  kaiReindexTimer = null;
  if (kaiReindexRunning) { kaiReindexPending = true; return; }
  kaiReindexRunning = true;
  const boveda = path.join(CAPABILITIES_DIR, 'boveda.sh');
  execFile(BASH_PATH, [boveda, 'reindexar'], { maxBuffer: 5 * 1024 * 1024, timeout: 10 * 60 * 1000 }, (err, stdout, stderr) => {
    kaiReindexRunning = false;
    kaiWatchLog(err ? `ERROR: ${String(stderr || err.message).slice(0, 300)}` : `OK: ${String(stdout).trim().split('\n').pop()}`);
    if (kaiReindexPending) { kaiReindexPending = false; scheduleKaiReindex(); }
  });
}

function scheduleKaiReindex() {
  if (kaiReindexTimer) clearTimeout(kaiReindexTimer);
  kaiReindexTimer = setTimeout(runKaiReindex, KAI_WATCH_DEBOUNCE_MS);
}

function startKaiVaultWatcher() {
  try {
    const watcher = fsSync.watch(MENTIS_ENV_DIR, { recursive: true }, (_eventType, filename) => {
      if (!filename) return;
      const parts = String(filename).split(path.sep);
      if (parts.some((p) => KAI_WATCH_IGNORE_DIRS.has(p))) return;
      const base = parts[parts.length - 1];
      if (KAI_WATCH_IGNORE_FILES.has(base) || base.endsWith('.log') || base.startsWith('.') && base.endsWith('.env')) return;
      scheduleKaiReindex();
    });
    // Bug real encontrado en investigacion 2026-07-14: fs.watch() devuelve un FSWatcher que
    // puede emitir 'error' (ej. en Windows, borrar/renombrar una subcarpeta mientras un watcher
    // RECURSIVO la vigila puede dejarla bloqueada con EPERM -- ver github.com/paulmillr/
    // chokidar/issues/643, mismo mecanismo nativo de Windows que usa fs.watch). SIN un listener
    // de 'error', el comportamiento por defecto de EventEmitter es TIRAR la excepcion -- crashea
    // el proceso Electron main entero. Ahora se loguea y se reintenta levantar el watcher en vez
    // de morir.
    watcher.on('error', (err) => {
      kaiWatchLog(`ERROR del watcher (se reintenta en 5s): ${err.message}`);
      setTimeout(startKaiVaultWatcher, 5000);
    });
    kaiWatchLog(`watcher activo sobre ${MENTIS_ENV_DIR}`);
  } catch (err) {
    kaiWatchLog(`no se pudo iniciar el watcher: ${err.message}`);
  }
}

app.whenReady().then(() => {
  // Que la cáscara no encuentre el motor es un error de instalación, no un bug para descubrir en
  // el primer mensaje: si falta mentis-chat.sh, la app arrancaría linda y muda. Se dice acá,
  // con la ruta que buscó, que es el único dato que hace falta para arreglarlo.
  if (!fsSync.existsSync(CHAT_SCRIPT)) {
    // También por stderr: el diálogo lo ve el usuario, pero un modal bloqueante es invisible para
    // cualquier prueba automática del arranque -- y el arranque de la versión empaquetada es
    // justo lo que hay que poder verificar sin un humano mirando la pantalla.
    console.error('[mentis] ERROR DE ARRANQUE: no encuentro el motor en ' + MENTIS_ENV_DIR);
    dialog.showErrorBox('Mentis no encuentra su motor',
      `Busqué el motor en:\n${MENTIS_ENV_DIR}\n\nNo está mentis-chat.sh ahí. Si moviste la carpeta ` +
      `de Mentis, abrí la app con la variable MENTIS_HOME apuntando a la carpeta nueva.`);
    app.exit(1);
    return;
  }
  session.defaultSession.setSpellCheckerLanguages(['es-AR', 'es']);
  // "Live" necesita el microfono (getUserMedia) para grabar la voz del usuario.
  // Electron bloquea permisos de media por defecto -- sin esto, el navegador (Chromium) ni
  // siquiera muestra el prompt nativo, getUserMedia falla directo.
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(permission === 'media');
  });
  createWindow();
  createTray();
  startKaiVaultWatcher();
  encenderServidorDeVoz();
  encenderPaginaDelCelular();

  // Atajo global de inicio rápido (pedido del usuario, 2026-07-15): mostrar/enfocar Mentis desde
  // cualquier lado sin importar qué ventana esté activa. el usuario lo pidió como "Shift+M" a secas,
  // pero eso NO es seguro como atajo GLOBAL: Windows lo intercepta ANTES que cualquier campo de
  // texto, así que cada vez que escribiera una M mayúscula (Shift+M) en CUALQUIER programa, en
  // vez de tipear "M" se abriría Mentis -- rompería el tipeo normal en todo el sistema.
  // Fix 2026-07-15 (bug real reportado por el usuario): Ctrl+Shift+M TAMPOCO es seguro -- es el atajo
  // global que Microsoft Teams (y Zoom) usan para mutear/desmutear el micrófono. Si Teams está
  // corriendo (aunque sea en bandeja), se queda con el registro y el de Mentis falla en
  // silencio -- Electron no tira excepción, solo devuelve `false`, y antes eso solo se logueaba
  // en la consola del proceso principal (invisible para el usuario en uso normal). Ahora se usa un
  // combo de 3 modificadores (mucho menos común que nada más registre) y, si falla igual, se
  // avisa con una notificación real en vez de un log que nadie ve.
  const shortcutRegistered = globalShortcut.register('CommandOrControl+Alt+Shift+M', showMainWindow);
  if (!shortcutRegistered) {
    console.error('[mentis-app] no se pudo registrar el atajo global Ctrl+Alt+Shift+M (¿ya está en uso por otra app?)');
    notifyIfUnfocused(
      'Mentis',
      'No pude activar el atajo de inicio rápido (Ctrl+Alt+Shift+M) -- parece que otra app ya lo está usando.'
    );
  }
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

// Cierre real (pedido del usuario, 2026-07-15, modo bandeja): cerrar la ventana con la X ahora solo
// la oculta (ver createWindow, evento 'close') -- la única forma de salir de verdad es "Salir"
// desde la bandeja, que pone isQuitting=true y llama a app.quit(). Ese primer app.quit() dispara
// este handler; se previene el cierre inmediato para poder esperar stopCurrentProcess() (matar
// el proceso de bash/nv-agent en curso) ANTES de cerrar de verdad. quitCleanupDone evita loopear:
// la segunda vuelta de app.quit() (ya con el cleanup hecho) entra acá, ve que ya se limpió, y no
// hace nada más -- Electron sigue con el cierre real.
app.on('before-quit', (event) => {
  if (!isQuitting || quitCleanupDone) return;
  event.preventDefault();
  quitCleanupDone = true;
  stopCurrentProcess()
.finally(() => apagarPaginaDelCelular())
.finally(() => app.quit());
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    isQuitting = true;
    app.quit();
  }
});
