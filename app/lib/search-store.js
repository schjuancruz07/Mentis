'use strict';
const fs = require('fs');
const path = require('path');

// Búsqueda full-text sobre el historial de chats (pedido del usuario, 2026-07-14) -- distinto del
// Kai Vault (que indexa archivos del entorno/notas con embeddings): esto es sobre las
// conversaciones mismas, texto plano, sin embeddings -- alcanza para "¿qué charlamos sobre X hace
// dos meses?" sin depender de un modelo de apoyo ni de que el vault esté indexado.
const SNIPPET_CONTEXT = 40;

function buildSnippet(text, matchIndex, queryLen) {
  const start = Math.max(0, matchIndex - SNIPPET_CONTEXT);
  const end = Math.min(text.length, matchIndex + queryLen + SNIPPET_CONTEXT);
  let snippet = text.slice(start, end);
  if (start > 0) snippet = '…' + snippet;
  if (end < text.length) snippet += '…';
  return snippet;
}

function searchConversations(convDir, query, opts = {}) {
  const limit = opts.limit || 50;
  const q = (query || '').trim().toLowerCase();
  if (!q || !fs.existsSync(convDir)) return [];

  const files = fs.readdirSync(convDir).filter((f) => f.endsWith('.jsonl'));
  const results = [];
  for (const file of files) {
    const conversationId = file.slice(0, -'.jsonl'.length);
    const raw = fs.readFileSync(path.join(convDir, file), 'utf-8');
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let entry;
      try { entry = JSON.parse(trimmed); } catch { continue; }
      const text = typeof entry.text === 'string' ? entry.text : '';
      if (!text) continue;
      const idx = text.toLowerCase().indexOf(q);
      if (idx === -1) continue;
      results.push({
        conversationId,
        role: entry.role || '',
        ts: entry.ts || '',
        snippet: buildSnippet(text, idx, q.length)
      });
    }
  }
  results.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
  return results.slice(0, limit);
}

module.exports = { searchConversations };
