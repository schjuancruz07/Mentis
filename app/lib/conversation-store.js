'use strict';
const fs = require('fs');
const path = require('path');

function ensureDir(convDir) {
  fs.mkdirSync(convDir, { recursive: true });
}

function newConversationId() {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const rand = Math.random().toString(36).slice(2, 8);
  return `${ts}-${rand}`;
}

function conversationPath(convDir, id) {
  return path.join(convDir, `${id}.jsonl`);
}

function readJsonlEntries(filePath) {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, 'utf-8');
  const entries = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    // Linea corrupta/truncada (ej. "Frenar ya" mata el proceso a mitad de una escritura) se
    // ignora en vez de tirar -- bug real encontrado en auditoria 2026-07-14: esto se llama de
    // forma sincrona dentro de un listener de 'turn-complete' en main.js, sin ningun try/catch
    // alrededor ni handler global de excepciones, asi que un JSON.parse roto acá crasheaba el
    // proceso Electron entero, no solo esa conversacion (mismo patron que ya usa stats-store.js
    // para el mismo tipo de archivo).
    try { entries.push(JSON.parse(trimmed)); } catch { /* linea corrupta, se ignora */ }
  }
  return entries;
}

// Botón Detener (pedido del usuario, 2026-07-16): mentis-chat.sh persiste el mensaje del usuario en
// el.jsonl ANTES de llamar al modelo (para que aparezca de inmediato en el chat aunque la
// respuesta tarde) -- así que frenar un turno a mitad de camino (forceKill) deja ese último
// mensaje "usuario" persistido SIN su respuesta. Esto lo saca del archivo real para que la
// conversación quede como si nunca se hubiera mandado, y devuelve su texto para que la UI lo
// pueda volver a poner en el cuadro de escritura.
function popLastJuanEntry(filePath) {
  const entries = readJsonlEntries(filePath);
  if (entries.length === 0) return null;
  const last = entries[entries.length - 1];
  if (last.role !== 'usuario') return null;
  const remaining = entries.slice(0, -1);
  const lines = remaining.map((e) => JSON.stringify(e)).join('\n');
  fs.writeFileSync(filePath, lines.length > 0 ? lines + '\n' : '', 'utf-8');
  return last.text;
}

function listConversations(convDir) {
  ensureDir(convDir);
  const files = fs.readdirSync(convDir).filter((f) => f.endsWith('.jsonl'));
  const items = files.map((f) => {
    const id = f.replace(/\.jsonl$/, '');
    const filePath = path.join(convDir, f);
    const entries = readJsonlEntries(filePath);
    const firstJuan = entries.find((e) => e.role === 'usuario');
    const title = firstJuan ? firstJuan.text.slice(0, 60) : '(conversación vacía)';
    const stat = fs.statSync(filePath);
    // EL MODO DE LA CONVERSACIÓN (2026-08-12): el de la primera entrada que lo tenga, o sea aquel
    // en el que arrancó. Las conversaciones anteriores a esta fecha no traen el campo y quedan
    // con modo null: la app las junta en "Antes de los modos" en vez de meterlas en uno cualquiera.
    // Inventarles un modo sería peor que no tenerlo -- aparecerían mezcladas en un modo donde
    // nunca estuvieron.
    const conModo = entries.find((e) => e.modo);
    return { id, title, updatedAt: stat.mtime.toISOString(), entryCount: entries.length,
             modo: conModo ? conModo.modo : null };
  });
  items.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
  return items;
}

module.exports = { ensureDir, newConversationId, conversationPath, readJsonlEntries, listConversations, popLastJuanEntry };
