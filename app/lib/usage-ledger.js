'use strict';
const fs = require('fs');

// Tracking de costo/gasto real (pedido del usuario, 2026-07-14): lee usage-ledger.jsonl, que
// mentis-usage-log.sh va llenando cada vez que una generación paga (Ideogram/Runway) termina con
// éxito de verdad. NVIDIA NIM no aparece acá porque es gratis (ver ask-nvidia.sh) -- no hay costo
// real que trackear ahí, y agregar un número inventado sería mentirle al usuario (mismo principio que
// ya aplica stats-store.js con "tokens totales").
const PROVIDER_LABELS = {
  ideogram: 'Ideogram (imágenes)',
  runway: 'Runway (video)'
};

function readLedger(ledgerPath) {
  if (!fs.existsSync(ledgerPath)) return [];
  const raw = fs.readFileSync(ledgerPath, 'utf-8');
  const rows = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try { rows.push(JSON.parse(trimmed)); } catch { /* linea corrupta, se ignora */ }
  }
  return rows;
}

function computeUsageCosts(ledgerPath) {
  const rows = readLedger(ledgerPath);
  const byProvider = new Map();
  let totalUsd = 0;
  for (const row of rows) {
    if (!row || typeof row.provider !== 'string') continue;
    const cost = typeof row.costUsd === 'number' && Number.isFinite(row.costUsd) ? row.costUsd : 0;
    const qty = typeof row.quantity === 'number' && Number.isFinite(row.quantity) ? row.quantity : 1;
    const entry = byProvider.get(row.provider) || { provider: row.provider, calls: 0, quantity: 0, costUsd: 0 };
    entry.calls += 1;
    entry.quantity += qty;
    entry.costUsd += cost;
    byProvider.set(row.provider, entry);
    totalUsd += cost;
  }
  const providers = [...byProvider.values()]
.map((e) => ({...e, label: PROVIDER_LABELS[e.provider] || e.provider, costUsd: Math.round(e.costUsd * 100) / 100 }))
.sort((a, b) => b.costUsd - a.costUsd);
  return { providers, totalUsd: Math.round(totalUsd * 100) / 100 };
}

module.exports = { computeUsageCosts };
