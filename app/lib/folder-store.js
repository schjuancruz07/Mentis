'use strict';
const fs = require('fs');
const path = require('path');

function filePath(convDir) {
  return path.join(convDir, 'folders.json');
}

function loadFolders(convDir) {
  const p = filePath(convDir);
  if (!fs.existsSync(p)) return { folders: [], assignments: {} };
  return JSON.parse(fs.readFileSync(p, 'utf-8'));
}

function save(convDir, data) {
  fs.mkdirSync(convDir, { recursive: true });
  fs.writeFileSync(filePath(convDir), JSON.stringify(data, null, 2));
}

function newFolderId() {
  return 'f-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
}

function createFolder(convDir, name) {
  const data = loadFolders(convDir);
  const folder = { id: newFolderId(), name };
  data.folders.push(folder);
  save(convDir, data);
  return folder;
}

function renameFolder(convDir, id, name) {
  const data = loadFolders(convDir);
  const folder = data.folders.find((f) => f.id === id);
  if (!folder) return false;
  folder.name = name;
  save(convDir, data);
  return true;
}

function deleteFolder(convDir, id) {
  const data = loadFolders(convDir);
  const before = data.folders.length;
  data.folders = data.folders.filter((f) => f.id !== id);
  if (data.folders.length === before) return false;
  for (const convId of Object.keys(data.assignments)) {
    if (data.assignments[convId] === id) delete data.assignments[convId];
  }
  save(convDir, data);
  return true;
}

function assignConversation(convDir, convId, folderId) {
  const data = loadFolders(convDir);
  if (folderId === null || folderId === undefined) {
    delete data.assignments[convId];
  } else {
    data.assignments[convId] = folderId;
  }
  save(convDir, data);
}

module.exports = { loadFolders, createFolder, renameFolder, deleteFolder, assignConversation };
