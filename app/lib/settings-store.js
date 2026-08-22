'use strict';
const fs = require('fs');
const path = require('path');

// Configuración de Mentis (pedido del usuario, 2026-07-13): modelos personalizados por rol +
// tema visual. Las API keys NUNCA van en mentis-settings.json -- viven aparte en
//.custom-models-secrets.env (mismo patrón que mcp-bridge/.secrets.env con Google), para que
// el archivo de config se pueda compartir/pegar sin exponer credenciales.
const ROLES = ['code', 'reason', 'deep', 'general', 'extract', 'multimodal', 'ultra'];
const PROVIDERS = ['openai-compatible', 'anthropic', 'gemini'];

function settingsPath(mentisEnvDir) {
  return path.join(mentisEnvDir, 'mentis-settings.json');
}

function secretsPath(mentisEnvDir) {
  return path.join(mentisEnvDir, '.custom-models-secrets.env');
}

// --- MODO ADMINISTRADOR (2026-08-07) ----------------------------------------------------------
// El switch que activa el modo administrador es COMODIDAD, no seguridad. Esta app es la MISMA que
// corre en las maquinas de las otras personas: el switch esta en el codigo de todas, y cualquiera
// con DevTools puede activarlo. Esconderlo mejor no cambiaria nada.
//
// Lo que de verdad impide que otro publique una actualizacion es la FIRMA (ver
// engine/nv-firma-lib.sh): sin la clave privada, lo que se publique lo rechazan las demas Mentis.
//
// Por eso el modo se muestra solo donde EXISTE la clave privada. No es para ocultarlo: es que sin
// la clave no hay nada que administrar, y un panel lleno de botones que no funcionan seria peor
// que no tenerlo. Se mira si el archivo existe -- nunca se lee su contenido ni se manda a ningun
// lado.
function esAdministrador(mentisEnvDir) {
  try {
    return fs.existsSync(path.join(mentisEnvDir, '.firma', 'mentis-firma-privada.pem'));
  } catch (e) {
    return false;
  }
}

// Que version esta publicada hoy y cual tiene esta maquina. Sirve para que el panel diga algo util
// antes de que el usuario apriete nada.
function getEstadoPublicacion(mentisEnvDir) {
  const leer = (p, d) => { try { return fs.readFileSync(p, 'utf-8').trim(); } catch (e) { return d; } };
  const version = leer(path.join(mentisEnvDir, 'VERSION'), '0.0.0');
  let publicada = null;
  try {
    publicada = JSON.parse(fs.readFileSync(
      path.join(mentisEnvDir, 'actualizaciones', 'manifiesto.json'), 'utf-8'));
  } catch (e) { /* todavia no publico nada */ }
  return {
    version,
    publicada: publicada ? {
      version: publicada.version, fecha: publicada.fecha,
      notas: publicada.notas, archivos: publicada.archivos,
    } : null,
    // Si la que tiene es mayor que la publicada, hay algo listo para publicar.
    hayPendiente: !publicada || version !== publicada.version,
  };
}

function loadSettings(mentisEnvDir) {
  try {
    return JSON.parse(fs.readFileSync(settingsPath(mentisEnvDir), 'utf-8'));
  } catch {
    return { customModels: {}, profile: {} };
  }
}

function saveSettings(mentisEnvDir, data) {
  fs.writeFileSync(settingsPath(mentisEnvDir), JSON.stringify(data, null, 2), 'utf-8');
}

function loadSecrets(mentisEnvDir) {
  const p = secretsPath(mentisEnvDir);
  const map = {};
  if (!fs.existsSync(p)) return map;
  for (const line of fs.readFileSync(p, 'utf-8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    map[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
  }
  return map;
}

function saveSecrets(mentisEnvDir, map) {
  const lines = ['# Claves reales de modelos personalizados -- NO se versiona.'];
  for (const [key, value] of Object.entries(map)) {
    lines.push(`${key}=${value}`);
  }
  fs.writeFileSync(secretsPath(mentisEnvDir), lines.join('\n') + '\n', 'utf-8');
}

// Devuelve la config SIN las keys reales (para mandar al renderer sin exponer secretos --
// solo dice si cada rol tiene una key guardada, no cuál).
function getPublicSettings(mentisEnvDir) {
  const data = loadSettings(mentisEnvDir);
  const secrets = loadSecrets(mentisEnvDir);
  const customModels = {};
  for (const role of ROLES) {
    const cm = data.customModels && data.customModels[role];
    if (cm) {
      customModels[role] = {
        provider: cm.provider, baseUrl: cm.baseUrl, model: cm.model,
        hasKey: !!secrets[`CUSTOM_MODEL_KEY_${role}`]
      };
    }
  }
  return {
    customModels,
    // `theme` NO se devuelve mas (2026-08-20). Era una clave muerta: viajaba hasta el
    // renderer y nadie la leia -- la apariencia la gobierna `apariencia.paleta` desde el
    // 2026-08-06. Se comprobo con grep en renderer.js, main.js, preload.js y temas.js: cero
    // usos. Si esta en el mentis-settings.json de alguien queda ahi, inofensiva; lo que se
    // corta es seguir propagando una configuracion que no configura nada.
    apariencia: getApariencia(mentisEnvDir, data),
    profile: getProfile(mentisEnvDir, data),
    voz: getVoz(mentisEnvDir, data)
  };
}

// APARIENCIA: paleta y nombre (2026-08-06, pedido del usuario). Mentis pasa a usarlo mas gente y cada
// uno tiene que poder ponerlo a su gusto -- el naranja sobre negro y el nombre "Mentis" son la
// identidad que eligio el usuario, no necesariamente la que quiere su familia.
//
// Va aparte de `theme`, que es una clave vieja con otro significado (el estilo de la bitacora) y
// que se deja intacta para no romper nada que la lea.
const NOMBRE_POR_DEFECTO = 'Mentis';
// OJO: este valor esta DUPLICADO a proposito de app/renderer/temas.js, porque este archivo es
// CommonJS del proceso principal y temas.js es un modulo ES del renderer -- no se pueden importar
// entre si sin mover uno de los dos. La copia se paga con un riesgo: que se separen. Ya paso --
// cuando la identidad cambio a terracota (2026-08-10) este seguia en 'mentis-clasico', un tema que
// ya no existia, y no fallaba nada: aplicarTema() cae en silencio al de por defecto, asi que el
// color salia bien por accidente. Hay un test (tests/temas_casos.mjs) que compara los dos y falla
// si se separan. Si cambias uno, cambia el otro.
const TEMA_POR_DEFECTO = 'mentis-oscuro';

function getApariencia(mentisEnvDir, preloaded) {
  const data = preloaded || loadSettings(mentisEnvDir);
  const a = data.apariencia || {};
  const nombre = String(a.nombre || '').trim();
  return {
    paleta: a.paleta || TEMA_POR_DEFECTO,
    // Si alguien deja el campo vacio, vuelve "Mentis": una IA sin nombre no puede presentarse.
    nombre: nombre || NOMBRE_POR_DEFECTO,
  };
}

function saveApariencia(mentisEnvDir, fields) {
  const data = loadSettings(mentisEnvDir);
  data.apariencia = {...(data.apariencia || {}) };
  if (fields && typeof fields.paleta === 'string') data.apariencia.paleta = fields.paleta;
  if (fields && typeof fields.nombre === 'string') {
    // Se recorta a 24 caracteres: el nombre entra en el prompt del sistema y en el titulo de la
    // ventana, y uno larguisimo rompe el diseño y ensucia cada turno.
    data.apariencia.nombre = fields.nombre.trim().slice(0, 24);
  }
  saveSettings(mentisEnvDir, data);
  return getApariencia(mentisEnvDir, data);
}

// Perfil + memoria adaptativa (pedido del usuario, 2026-07-13): avatar, nombre, apodo, descripción
// de trabajo e instrucciones persistentes, más un cuadro de "memoria sobre vos" que Mentis
// puede reescribir con el tiempo (ver mentis-chat.sh: bloque ```mentis-memory-update```). Sin
// secretos acá -- todo esto viaja tal cual al renderer.
function getProfile(mentisEnvDir, preloaded) {
  const data = preloaded || loadSettings(mentisEnvDir);
  const p = data.profile || {};
  return {
    avatarPath: p.avatarPath || '',
    fullName: p.fullName || '',
    nickname: p.nickname || '',
    role: p.role || '',
    customRole: p.customRole || '',
    instructions: p.instructions || '',
    userMemory: p.userMemory || '',
    userMemoryUpdatedAt: p.userMemoryUpdatedAt || null,
    userMemoryUpdatedBy: p.userMemoryUpdatedBy || null,
    selfMemory: p.selfMemory || '',
    selfMemoryUpdatedAt: p.selfMemoryUpdatedAt || null,
    selfMemoryUpdatedBy: p.selfMemoryUpdatedBy || null
  };
}

function saveProfile(mentisEnvDir, fields) {
  const data = loadSettings(mentisEnvDir);
  data.profile = {...(data.profile || {}),...fields };
  saveSettings(mentisEnvDir, data);
  return getProfile(mentisEnvDir, data);
}

function saveUserMemory(mentisEnvDir, text, updatedBy) {
  const data = loadSettings(mentisEnvDir);
  data.profile = data.profile || {};
  data.profile.userMemory = text || '';
  data.profile.userMemoryUpdatedAt = new Date().toISOString();
  data.profile.userMemoryUpdatedBy = updatedBy || 'usuario';
  saveSettings(mentisEnvDir, data);
  return getProfile(mentisEnvDir, data);
}

// Memoria sobre Mentis misma (pedido del usuario, 2026-07-14): autoconocimiento, mismo mecanismo
// que saveUserMemory pero campo distinto (ver mentis-chat.sh: bloque ```mentis-self-memory-update```).
function saveSelfMemory(mentisEnvDir, text, updatedBy) {
  const data = loadSettings(mentisEnvDir);
  data.profile = data.profile || {};
  data.profile.selfMemory = text || '';
  data.profile.selfMemoryUpdatedAt = new Date().toISOString();
  data.profile.selfMemoryUpdatedBy = updatedBy || 'usuario';
  saveSettings(mentisEnvDir, data);
  return getProfile(mentisEnvDir, data);
}

function saveCustomModel(mentisEnvDir, role, { provider, baseUrl, model, apiKey }) {
  if (!ROLES.includes(role)) throw new Error(`rol inválido: ${role}`);
  if (!PROVIDERS.includes(provider)) throw new Error(`proveedor inválido: ${provider}`);
  if (!baseUrl || !model) throw new Error('faltan baseUrl o model');
  const data = loadSettings(mentisEnvDir);
  data.customModels = data.customModels || {};
  data.customModels[role] = { provider, baseUrl, model, keyRef: role };
  saveSettings(mentisEnvDir, data);
  if (apiKey) {
    const secrets = loadSecrets(mentisEnvDir);
    secrets[`CUSTOM_MODEL_KEY_${role}`] = apiKey;
    saveSecrets(mentisEnvDir, secrets);
  }
}

function removeCustomModel(mentisEnvDir, role) {
  const data = loadSettings(mentisEnvDir);
  if (data.customModels) delete data.customModels[role];
  saveSettings(mentisEnvDir, data);
  const secrets = loadSecrets(mentisEnvDir);
  delete secrets[`CUSTOM_MODEL_KEY_${role}`];
  saveSecrets(mentisEnvDir, secrets);
}

// Ideogram (pedido del usuario, 2026-07-13): imágenes con texto/logos/tipografía legible, mejor
// que el generador general (Pollinations) para ese caso puntual. Misma separación config/
// secreto que todo lo demás.
function getIdeogramStatus(mentisEnvDir) {
  const secrets = loadSecrets(mentisEnvDir);
  return { hasKey: !!secrets.IDEOGRAM_API_KEY };
}

function saveIdeogramKey(mentisEnvDir, apiKey) {
  if (!apiKey) throw new Error('falta la API key');
  const secrets = loadSecrets(mentisEnvDir);
  secrets.IDEOGRAM_API_KEY = apiKey;
  saveSecrets(mentisEnvDir, secrets);
}

function removeIdeogramKey(mentisEnvDir) {
  const secrets = loadSecrets(mentisEnvDir);
  delete secrets.IDEOGRAM_API_KEY;
  saveSecrets(mentisEnvDir, secrets);
}

// Runway (pedido del usuario, 2026-07-14): video real via /v1/image_to_video -- reemplaza a
// Replicate/LTX-Video (esa key nunca se configuro y no habia forma gratis de probarla).
// Mismo patrón que Ideogram.
function getRunwayStatus(mentisEnvDir) {
  const secrets = loadSecrets(mentisEnvDir);
  return { hasKey: !!secrets.RUNWAY_API_KEY };
}

function saveRunwayKey(mentisEnvDir, apiKey) {
  if (!apiKey) throw new Error('falta la API key');
  const secrets = loadSecrets(mentisEnvDir);
  secrets.RUNWAY_API_KEY = apiKey;
  saveSecrets(mentisEnvDir, secrets);
}

function removeRunwayKey(mentisEnvDir) {
  const secrets = loadSecrets(mentisEnvDir);
  delete secrets.RUNWAY_API_KEY;
  saveSecrets(mentisEnvDir, secrets);
}

// Switch real para conectores locales/api-key (pedido del usuario, 2026-07-14): "que todos tengan
// switch y sea funcional" -- antes main.js forzaba enabled:true en estos, ahora se persiste acá
// (default true si nunca se tocó) y nv-agent.sh/mentis-chat.sh leen el mismo mentis-settings.json
// para gatear la tool real (exec/vscode/gen) segun el flag. Git Bash queda afuera a propósito:
// es el sustrato donde corre el propio agente, no hay una acción separada que apagar.
// Conectores que arrancan APAGADOS y hay que encender a mano. El default general es "encendido
// si nunca se tocó", que está bien para lo inofensivo -- pero la cámara y el teléfono no lo son, y
// hasta el 2026-07-30 la cámara caía en ese default: los comentarios decían "arranca apagada" y
// en los hechos estaba habilitada porque su clave nunca se había escrito en el archivo.
const CONECTORES_APAGADOS_POR_DEFECTO = ['local:webcam', 'local:telefono'];

function getConnectorEnabled(mentisEnvDir, id) {
  const data = loadSettings(mentisEnvDir);
  const map = data.connectorsEnabled || {};
  if (CONECTORES_APAGADOS_POR_DEFECTO.includes(id)) return map[id] === true;
  return map[id] !== false;
}

function setConnectorEnabled(mentisEnvDir, id, enabled) {
  const data = loadSettings(mentisEnvDir);
  data.connectorsEnabled = data.connectorsEnabled || {};
  data.connectorsEnabled[id] = !!enabled;
  saveSettings(mentisEnvDir, data);
  return getConnectorEnabled(mentisEnvDir, id);
}

// Ubicación/clima cacheados (pedido del usuario, 2026-07-15, saludo animado de arranque): geo-IP +
// clima son datos externos que no hace falta pedir de nuevo en cada arranque de la app -- se
// cachean con un timestamp y se refrescan solo si están viejos (ver main.js, getLocationWeather).
function getLocationCache(mentisEnvDir) {
  const data = loadSettings(mentisEnvDir);
  return (data.profile && data.profile.locationCache) || null;
}

function setLocationCache(mentisEnvDir, cache) {
  const data = loadSettings(mentisEnvDir);
  data.profile = data.profile || {};
  data.profile.locationCache = cache;
  saveSettings(mentisEnvDir, data);
}

// Voz / fin de frase (2026-07-28). El UMBRAL de voz no se guarda a propósito: se calibra solo
// contra el ruido real de la sala en cada grabación (ver renderer.js), y un valor fijo guardado
// en disco sería justamente el problema que se vino a resolver. Lo que sí es preferencia personal
// -- y nadie puede medir por el usuario -- es cuánto silencio tiene que pasar antes de que Mentis dé la
// frase por terminada: quien piensa en voz alta necesita más que quien habla de corrido.
const VOZ_DEFAULT = { silencioMs: 1100, factorSensibilidad: 3.5 };

function getVoz(mentisEnvDir, preloaded) {
  const data = preloaded || loadSettings(mentisEnvDir);
  const v = data.voz || {};
  const silencioMs = Number(v.silencioMs);
  const factor = Number(v.factorSensibilidad);
  return {
    // Acotados a rangos que tienen sentido: por debajo de 400 ms corta en medio de una pausa
    // natural, por encima de 4 s ya se siente que se colgó.
    silencioMs: Number.isFinite(silencioMs) ? Math.min(4000, Math.max(400, silencioMs)) : VOZ_DEFAULT.silencioMs,
    factorSensibilidad: Number.isFinite(factor) ? Math.min(8, Math.max(1.5, factor)) : VOZ_DEFAULT.factorSensibilidad
  };
}

function saveVoz(mentisEnvDir, fields) {
  const data = loadSettings(mentisEnvDir);
  const actual = getVoz(mentisEnvDir, data);
  // Se valida al ESCRIBIR, no solo al leer. Guardar un NaN parece inofensivo porque getVoz lo
  // acota igual, pero JSON.stringify(NaN) escribe `null` en el archivo, y un null SÍ pasa por
  // Number.isFinite(Number(null)) === true -> se acotaba a 400 ms y el default quedaba perdido
  // para siempre. Lo encontró el test de "basura no numérica".
  const num = (v, porDefecto) => (Number.isFinite(Number(v)) ? Number(v) : porDefecto);
  data.voz = {
    silencioMs: fields && fields.silencioMs !== undefined ? num(fields.silencioMs, actual.silencioMs) : actual.silencioMs,
    factorSensibilidad: fields && fields.factorSensibilidad !== undefined ? num(fields.factorSensibilidad, actual.factorSensibilidad) : actual.factorSensibilidad
  };
  saveSettings(mentisEnvDir, data);
  return getVoz(mentisEnvDir);
}


// --- IDIOMAS (2026-08-13) ---------------------------------------------------------------------
// Dos preferencias separadas: 'lectura' (en que idioma escribe) y 'habla' (voz y transcripcion).
// La lista de idiomas NO vive aca sino en engine/idiomas.json, que es lo que leen tambien el
// motor, el TTS y el reconocimiento de voz. Duplicarla en el settings-store la desincronizaria
// el primer dia que se agregue un idioma.
function idiomasDisponibles(mentisEnvDir) {
  try {
    const p = path.join(mentisEnvDir, 'engine', 'idiomas.json');
    const t = JSON.parse(fs.readFileSync(p, 'utf8'));
    return Object.entries(t.idiomas || {}).map(([codigo, d]) => ({ codigo, nombre: d.nombre }));
  } catch {
    // Sin la tabla queda el espaniol: es mejor un selector con una opcion que un selector vacio
    // que parece roto.
    return [{ codigo: 'es', nombre: 'Espanol' }];
  }
}

function getIdioma(mentisEnvDir, data) {
  const d = data || loadSettings(mentisEnvDir);
  const codigos = idiomasDisponibles(mentisEnvDir).map((x) => x.codigo);
  const val = (v) => (codigos.includes(v) ? v : 'es');
  const g = d.idioma || {};
  return { lectura: val(g.lectura), habla: val(g.habla) };
}

// Se valida al ESCRIBIR y no solo al leer: guardar un codigo que no existe deja a Mentis pidiendo
// una voz inexistente al TTS, que falla en el momento de hablar y no al guardar -- o sea lejos de
// donde se puede entender que paso.
function saveIdioma(mentisEnvDir, fields) {
  const data = loadSettings(mentisEnvDir);
  const actual = getIdioma(mentisEnvDir, data);
  const codigos = idiomasDisponibles(mentisEnvDir).map((x) => x.codigo);
  const val = (v, porDefecto) => (codigos.includes(v) ? v : porDefecto);
  data.idioma = {
    lectura: fields && fields.lectura !== undefined ? val(fields.lectura, actual.lectura) : actual.lectura,
    habla: fields && fields.habla !== undefined ? val(fields.habla, actual.habla) : actual.habla,
  };
  saveSettings(mentisEnvDir, data);
  return data.idioma;
}

module.exports = {
  idiomasDisponibles, getIdioma, saveIdioma,
  ROLES, PROVIDERS, getPublicSettings, saveCustomModel, removeCustomModel,
  getVoz, saveVoz, VOZ_DEFAULT,
  getIdeogramStatus, saveIdeogramKey, removeIdeogramKey,
  getRunwayStatus, saveRunwayKey, removeRunwayKey,
  getConnectorEnabled, setConnectorEnabled,
  getProfile, saveProfile, saveUserMemory, saveSelfMemory,
  getApariencia, saveApariencia,
  esAdministrador, getEstadoPublicacion,
  getLocationCache, setLocationCache
};
