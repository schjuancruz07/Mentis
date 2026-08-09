'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');

function psQuote(p) {
  return `'${String(p).replace(/'/g, "''")}'`;
}

// Backup/exportación completa (pedido del usuario, 2026-07-14): junta en un ZIP todo lo que el usuario no
// puede regenerar -- conversaciones, proyectos, memoria/perfil, skills. Deja afuera a propósito:
// API keys/secretos, archivos de estado transitorios, y las creaciones de IA (imágenes/videos/
// documentos ya generados) porque son regenerables y pueden pesar mucho.
function stageBackupSources(stagingDir, sources) {
  for (const { src, destName } of sources) {
    if (fs.existsSync(src)) {
      fs.cpSync(src, path.join(stagingDir, destName), { recursive: true });
    }
  }
}

function compressDir(stagingDir, destZipPath) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      `Compress-Archive -Path ${psQuote(path.join(stagingDir, '*'))} -DestinationPath ${psQuote(destZipPath)} -Force`
    ], { timeout: 180000 }, (err, _stdout, stderr) => {
      if (err) return reject(new Error(String(stderr || err.message)));
      resolve();
    });
  });
}

// sources: [{ src: <ruta absoluta>, destName: <nombre dentro del zip> }]
async function exportBackup(sources, destZipPath) {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mentis-backup-'));
  try {
    stageBackupSources(stagingDir, sources);
    if (fs.readdirSync(stagingDir).length === 0) {
      throw new Error('No hay datos todavía para exportar.');
    }
    await compressDir(stagingDir, destZipPath);
    return { ok: true, path: destZipPath };
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }
}

module.exports = { exportBackup, psQuote };
