'use strict';
const fs = require('fs');
const path = require('path');
const convStore = require('./conversation-store');

// Edición de mensajes con ramas (pedido del usuario, 2026-07-14): editar un mensaje TUYO pasado no
// modifica la conversación original -- crea una conversación nueva ("rama") que comparte todo
// el historial ANTERIOR al mensaje editado, más el mensaje editado como si lo hubieras mandado
// de cero (una respuesta nueva de verdad, generada por el flujo normal de envío, no algo
// simulado). branches.json guarda solo la relación padre/índice de cada rama -- la conversación
// original nunca se toca ni se entera de que existe una rama.
function branchesPath(convDir) {
  return path.join(convDir, 'branches.json');
}

function loadBranches(convDir) {
  try {
    return JSON.parse(fs.readFileSync(branchesPath(convDir), 'utf-8'));
  } catch {
    return {};
  }
}

function saveBranches(convDir, data) {
  fs.writeFileSync(branchesPath(convDir), JSON.stringify(data, null, 2), 'utf-8');
}

// Crea la rama truncada (todo ANTES del mensaje editado, sin incluirlo) -- el mensaje editado en
// sí se manda por el flujo normal de "enviar mensaje" del lado del renderer, para reusar 100% el
// mecanismo ya probado de generar una respuesta real (no duplicar esa lógica acá).
function createBranch(convDir, parentConversationId, divergeAtIndex) {
  const parentPath = convStore.conversationPath(convDir, parentConversationId);
  const parentEntries = convStore.readJsonlEntries(parentPath);
  if (!Number.isInteger(divergeAtIndex) || divergeAtIndex < 0 || divergeAtIndex >= parentEntries.length) {
    throw new Error('índice de mensaje fuera de rango');
  }
  if (parentEntries[divergeAtIndex].role !== 'usuario') {
    throw new Error('solo se pueden editar tus propios mensajes, no las respuestas de Mentis');
  }
  const newId = convStore.newConversationId();
  const newPath = convStore.conversationPath(convDir, newId);
  const lines = parentEntries.slice(0, divergeAtIndex).map((e) => JSON.stringify(e));
  fs.writeFileSync(newPath, lines.length ? lines.join('\n') + '\n' : '', 'utf-8');
  const branches = loadBranches(convDir);
  branches[newId] = { parentId: parentConversationId, divergeAtIndex };
  saveBranches(convDir, branches);
  return newId;
}

// Para la conversación actualmente abierta, devuelve en qué índices de mensaje hay mas de una
// version navegable, y cuales son (en orden: el original primero, despues las ramas). El
// renderer usa esto para dibujar "‹ i/N ›" solo donde de verdad hay algo para navegar.
function getSiblingGroups(convDir, conversationId) {
  const branches = loadBranches(convDir);
  const groupsByIndex = new Map();

  const self = branches[conversationId];
  if (self) {
    const members = [self.parentId];
    for (const [id, b] of Object.entries(branches)) {
      if (b.parentId === self.parentId && b.divergeAtIndex === self.divergeAtIndex && !members.includes(id)) {
        members.push(id);
      }
    }
    groupsByIndex.set(self.divergeAtIndex, members);
  }

  for (const [id, b] of Object.entries(branches)) {
    if (b.parentId !== conversationId) continue;
    const existing = groupsByIndex.get(b.divergeAtIndex) || [conversationId];
    if (!existing.includes(id)) existing.push(id);
    groupsByIndex.set(b.divergeAtIndex, existing);
  }

  const result = {};
  for (const [idx, members] of groupsByIndex) {
    if (members.length > 1) result[idx] = members;
  }
  return result;
}

module.exports = { createBranch, getSiblingGroups, loadBranches };
