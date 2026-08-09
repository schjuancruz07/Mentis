'use strict';
const fs = require('fs');
const path = require('path');

// Panel de estadísticas de uso (pedido del usuario, 2026-07-13, imagen 4). Todo lo de acá sale de
// leer conversations/*.jsonl de verdad -- nada inventado. "Tokens totales" NO se calcula: no
// existe hoy ningún punto del pipeline (ask-nvidia.sh no parsea "usage" de la respuesta de la
// API) que lo registre, y fabricar un número sería mentirle al usuario un dato que no tenemos.
// "Modelo favorito" solo cuenta turnos nuevos que ya traen el campo "model" (agregado en
// mentis-chat.sh en esta misma sesión) -- el historial viejo no lo tiene.

const ROLE_LABELS = {
  code: 'Código', reason: 'Razonamiento', deep: 'Razonamiento profundo', general: 'General',
  extract: 'Extracción', multimodal: 'Multimodal', ultra: 'Ultra', text: 'Texto'
};

function readAllEntries(convDir) {
  if (!fs.existsSync(convDir)) return [];
  const files = fs.readdirSync(convDir).filter((f) => f.endsWith('.jsonl'));
  const entries = [];
  for (const f of files) {
    const raw = fs.readFileSync(path.join(convDir, f), 'utf-8');
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try { entries.push(JSON.parse(trimmed)); } catch { /* linea corrupta, se ignora */ }
    }
  }
  return { entries, sessionCount: files.length };
}

function dateKey(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toISOString().slice(0, 10); // YYYY-MM-DD, en UTC (simple y consistente)
}

function computeStreaks(daySet) {
  const days = [...daySet].sort();
  if (days.length === 0) return { current: 0, longest: 0 };
  const dayMs = 24 * 60 * 60 * 1000;
  let longest = 1;
  let run = 1;
  for (let i = 1; i < days.length; i++) {
    const prev = new Date(days[i - 1] + 'T00:00:00Z').getTime();
    const cur = new Date(days[i] + 'T00:00:00Z').getTime();
    if (cur - prev === dayMs) { run += 1; } else { run = 1; }
    if (run > longest) longest = run;
  }
  // Racha actual: desde el ultimo dia con actividad hacia atras, contando consecutivos, pero
  // solo si el ultimo dia es hoy o ayer (si no, la racha ya se corto y es 0).
  const todayKey = new Date().toISOString().slice(0, 10);
  const yestKey = new Date(Date.now() - dayMs).toISOString().slice(0, 10);
  const lastDay = days[days.length - 1];
  if (lastDay !== todayKey && lastDay !== yestKey) return { current: 0, longest };
  let current = 1;
  for (let i = days.length - 1; i > 0; i--) {
    const prev = new Date(days[i - 1] + 'T00:00:00Z').getTime();
    const cur = new Date(days[i] + 'T00:00:00Z').getTime();
    if (cur - prev === dayMs) current += 1; else break;
  }
  return { current, longest };
}

// Heatmap de los ultimos N dias (default 70, ~10 semanas -- suficiente para un grid tipo
// GitHub sin sobrecargar la UI), cada celda con la cuenta de mensajes del usuario ese dia.
function buildHeatmap(daysCount, dayCounts) {
  const cells = [];
  const dayMs = 24 * 60 * 60 * 1000;
  const todayUtc = new Date().toISOString().slice(0, 10);
  const todayMs = new Date(todayUtc + 'T00:00:00Z').getTime();
  for (let i = daysCount - 1; i >= 0; i--) {
    const key = new Date(todayMs - i * dayMs).toISOString().slice(0, 10);
    cells.push({ date: key, count: dayCounts.get(key) || 0 });
  }
  return cells;
}

function computeStats(convDir, opts = {}) {
  const heatmapDays = opts.heatmapDays || 70;
  const { entries, sessionCount } = readAllEntries(convDir);

  const juanEntries = entries.filter((e) => e.role === 'usuario');
  const mentisEntries = entries.filter((e) => e.role !== 'usuario');

  const daySet = new Set();
  const dayCounts = new Map();
  const hourCounts = new Array(24).fill(0);
  for (const e of juanEntries) {
    const key = dateKey(e.ts);
    if (!key) continue;
    daySet.add(key);
    dayCounts.set(key, (dayCounts.get(key) || 0) + 1);
    const hour = new Date(e.ts).getUTCHours();
    if (!Number.isNaN(hour)) hourCounts[hour] += 1;
  }

  let peakHour = null;
  let peakHourCount = -1;
  hourCounts.forEach((count, hour) => { if (count > peakHourCount) { peakHourCount = count; peakHour = hour; } });
  if (peakHourCount <= 0) peakHour = null;

  const modelCounts = new Map();
  for (const e of mentisEntries) {
    if (!e.model) continue;
    modelCounts.set(e.model, (modelCounts.get(e.model) || 0) + 1);
  }
  let favoriteModel = null;
  let favoriteModelCount = 0;
  for (const [model, count] of modelCounts) {
    if (count > favoriteModelCount) { favoriteModelCount = count; favoriteModel = model; }
  }

  const streaks = computeStreaks(daySet);

  return {
    sessions: sessionCount,
    messages: juanEntries.length,
    daysActive: daySet.size,
    currentStreak: streaks.current,
    longestStreak: streaks.longest,
    peakHour,
    favoriteModel: favoriteModel ? (ROLE_LABELS[favoriteModel] || favoriteModel) : null,
    favoriteModelSampleSize: favoriteModelCount,
    modelDataAvailable: modelCounts.size > 0,
    heatmap: buildHeatmap(heatmapDays, dayCounts),
    // Deliberadamente NO incluido: "tokens totales" -- no hay ninguna fuente real de ese dato
    // hoy en el pipeline (ver comentario arriba). No se fabrica un numero para no mentir.
    tokensTracked: false
  };
}

module.exports = { computeStats };
