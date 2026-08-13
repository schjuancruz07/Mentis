#!/usr/bin/env node
// empaquetar.js -- envuelve a electron-packager con un chequeo previo que dice QUIEN bloquea.
//
// POR QUE EXISTE (ERR-106 y su secuela):
//   electron-packager falla con "EBUSY: resource busy or locked, rmdir '...'" y NO nombra al
//   culpable. Ese mensaje mudo ya costo un dia entero de trabajo: se busco el problema en el
//   codigo de la app cuando en realidad habia un proceso reteniendo la carpeta de salida.
//   Windows no deja borrar ni reemplazar un directorio si algun proceso tiene ahi adentro un
//.exe corriendo, o lo tiene abierto como directorio de trabajo.
//
//   Hay DOS causas distintas y conviene no confundirlas:
//     1. Servicios que la app lanza (servidores de voz, web, KDE Connect) que heredaban la
//        carpeta como cwd. Eso es ERR-106 propiamente dicho y ya esta arreglado en origen:
//        cada lanzador sale de la carpeta antes de arrancar el proceso. Ver tests/test-cwd-servidores.sh.
//     2. La app EMPAQUETADA corriendo. Eso no es un bug: es Mentis abierto. Pero el mensaje de
//        error es identico, y ahi esta la trampa.
//
//   Este chequeo separa las dos y dice exactamente que cerrar. La regla de fondo es la misma que
//   ERR-098: una observacion que no dice la verdad manda a quien la lee a chocar.
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// MENTIS_DIST_DIR y --solo-chequeo existen para que esto sea PROBABLE: sin ellos, testear el
// chequeo exigiria cerrar la app del usuario y esperar un empaquetado real de un minuto. En uso
// normal nadie los define y el comportamiento es el de siempre.
const SALIDA = path.resolve(process.env.MENTIS_DIST_DIR || path.join(__dirname, '..', 'dist'));
const DESTINO = path.join(SALIDA, 'Mentis-win32-x64');
const SOLO_CHEQUEO = process.argv.includes('--solo-chequeo');

// Procesos que tienen su ejecutable DENTRO de la carpeta de salida, o que la declaran en su
// linea de comandos. Es lo que Win32_Process puede ver sin herramientas extra (el cwd de un
// proceso ajeno no es consultable desde PowerShell sin un handle.exe de Sysinternals).
function retenedores(carpeta) {
  const ps = [
    'Get-CimInstance Win32_Process |',
    `Where-Object { $_.ExecutablePath -like '${carpeta}*' } |`,
    'ForEach-Object { $_.ProcessId.ToString() + "|" + $_.Name }',
  ].join(' ');
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], {
    encoding: 'utf8',
    timeout: 20000,
  });
  if (r.error || r.status !== 0) return [];
  return String(r.stdout || '')
.split(/\r?\n/)
.map((l) => l.trim())
.filter(Boolean)
.map((l) => {
      const [pid, nombre] = l.split('|');
      return { pid, nombre };
    });
}

if (fs.existsSync(DESTINO)) {
  const presos = retenedores(DESTINO);
  if (presos.length > 0) {
    const nombres = [...new Set(presos.map((p) => p.nombre))].join(', ');
    console.error('');
    console.error('No se puede empaquetar: la carpeta de destino esta en uso.');
    console.error('');
    console.error(`  Carpeta : ${DESTINO}`);
    console.error(`  La usan : ${presos.length} proceso(s) -- ${nombres}`);
    console.error(`  PIDs    : ${presos.map((p) => p.pid).join(', ')}`);
    console.error('');
    if (presos.some((p) => /^Mentis\.exe$/i.test(p.nombre))) {
      console.error('  Es la app de Mentis, que esta abierta ahora mismo. Windows no deja');
      console.error('  reemplazar una carpeta que contiene un programa en ejecucion.');
      console.error('');
      console.error('  Cerra Mentis y volve a correr el empaquetado. Si no aparece ninguna');
      console.error('  ventana, quedaron procesos sueltos; se cierran con:');
      console.error('');
      console.error('      powershell -Command "Stop-Process -Name Mentis -Force"');
    } else {
      console.error('  Cerra esos procesos y volve a correr el empaquetado.');
    }
    console.error('');
    console.error('  (Si en cambio queres empaquetar SIN cerrar nada, mandalo a otra carpeta:');
    console.error('   npx electron-packager. Mentis --platform=win32 --arch=x64 --out=../dist-prueba)');
    console.error('');
    process.exit(1);
  }
}

if (SOLO_CHEQUEO) {
  console.log(`OK: nadie retiene ${DESTINO}; se puede empaquetar.`);
  process.exit(0);
}

// Sin retenedores: al empaquetado real. Los argumentos son los mismos de siempre.
const args = [
  '.', 'Mentis',
  '--platform=win32', '--arch=x64',
  '--icon=renderer/assets/mentis-app.ico',
  `--out=${path.relative(__dirname, SALIDA).replace(/\\/g, '/')}`,
  '--overwrite',
  '--app-version=0.1.0',
  '--win32metadata.FileDescription=Mentis',
  '--win32metadata.ProductName=Mentis',
  '--ignore=^/test$',
  '--ignore=^/dist$',
];

// Se llama al binario LOCAL de node_modules, no a `npx`. Con npx esto fallaba en silencio:
// salia con codigo 1 y CERO lineas de salida, y como el catch daba por sentado que
// electron-packager ya habria explicado el problema, no se imprimia nada. El resultado era el
// peor posible -- `npm run empaquetar` "terminaba bien" y el.exe seguia siendo el del dia
// anterior. Es la misma leccion de ERR-105: que un comando termine no significa que haya hecho
// algo, y hay que mirar el resultado, no el proceso.
const BIN = path.join(__dirname, 'node_modules', '.bin',
  process.platform === 'win32' ? 'electron-packager.cmd' : 'electron-packager');

if (!fs.existsSync(BIN)) {
  console.error(`No encuentro el empaquetador en ${BIN}`);
  console.error('Instalá las dependencias con:  npm install');
  process.exit(1);
}

const r = spawnSync(BIN, args, { cwd: __dirname, stdio: 'inherit', shell: true });

if (r.error) {
  console.error('No se pudo ejecutar el empaquetador:', r.error.message);
  process.exit(1);
}
if (r.status !== 0) {
  console.error(`\nEl empaquetado fallo (codigo ${r.status}). El.exe anterior quedo intacto.`);
  process.exit(r.status || 1);
}

// VERIFICAR EL RESULTADO, no el proceso. Un empaquetado "exitoso" que dejo el.exe viejo es
// justamente lo que hay que detectar.
const EXE = path.join(DESTINO, 'Mentis.exe');
if (!fs.existsSync(EXE)) {
  console.error(`\nEl empaquetador dijo que si, pero no hay ningun.exe en ${DESTINO}`);
  process.exit(1);
}
const edadMin = (Date.now() - fs.statSync(EXE).mtimeMs) / 60000;
if (edadMin > 10) {
  console.error(`\nOJO: el.exe de ${DESTINO} tiene ${Math.round(edadMin)} minutos de antiguedad.`);
  console.error('El empaquetado no lo reemplazo: lo que hay ahi es de una version anterior.');
  process.exit(1);
}
console.log(`\nListo: ${EXE} (reescrito recien)`);
