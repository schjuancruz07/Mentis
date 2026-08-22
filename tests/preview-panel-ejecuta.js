// Ejecuta la logica real de apertura del panel de progreso, con un DOM simulado.
//
// POR QUE (2026-08-18): test-preview-vivo.sh verifica con grep que las funciones y las variables
// existan. Pero el bug que motivo ese archivo no era una funcion faltante: TODAS las piezas
// andaban y el panel igual no se abria, porque nacia con `collapsed` y nadie se la sacaba. O sea
// que era un problema de COMPORTAMIENTO, y un grep no lo ve. Aca se extraen las funciones del
// renderer y se corren contra un DOM de mentira.
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'app', 'renderer', 'renderer.js'), 'utf-8');
const fn = src.match(/function abrirPanelSiHaceFalta\(\)[\s\S]*?\n\}/);
if (!fn) { console.log('MAL no se pudo extraer abrirPanelSiHaceFalta del renderer'); process.exit(1); }

function nuevoPanel(colapsado) {
  const clases = new Set(colapsado ? ['collapsed'] : []);
  return {
    classList: {
      contains: (c) => clases.has(c),
      remove: (c) => clases.delete(c),
      add: (c) => clases.add(c),
    },
    _abierto: () => !clases.has('collapsed'),
  };
}

function correr({ cerradoPorJuan, colapsado }) {
  const panel = nuevoPanel(colapsado);
  const ctx = {
    panelCerradoPorJuan: cerradoPorJuan,
    panelAbiertoEsteTurno: false,
    document: { getElementById: (id) => (id === 'status-panel' ? panel : null) },
  };
  const f = new Function('document', 'panelCerradoPorJuan', 'panelAbiertoEsteTurno',
    fn[0] + '\n return (function(){ abrirPanelSiHaceFalta(); return panelAbiertoEsteTurno; })();');
  const marcado = f(ctx.document, ctx.panelCerradoPorJuan, ctx.panelAbiertoEsteTurno);
  return { abierto: panel._abierto(), marcado };
}

const fallos = [];

// 1) EL BUG ORIGINAL: llega actividad y el panel esta cerrado -> se abre
if (!correr({ cerradoPorJuan: false, colapsado: true }).abierto) {
  fallos.push('el panel NO se abre cuando llega actividad: es exactamente el bug que ya paso');
}
// 2) si el usuario lo cerro a mano, se respeta -- no se le abre solo en la cara
if (correr({ cerradoPorJuan: true, colapsado: true }).abierto) {
  fallos.push('el panel se abre aunque el usuario lo haya cerrado a mano');
}
// 3) si ya estaba abierto, no se rompe nada
if (!correr({ cerradoPorJuan: false, colapsado: false }).abierto) {
  fallos.push('el panel ya abierto termino cerrado');
}
// 4) el reset al empezar turno existe y vuelve a permitir la apertura
if (!/panelCerradoPorJuan = false/.test(src)) {
  fallos.push('nada resetea panelCerradoPorJuan: cerrarlo una vez lo cerraria para siempre');
}

if (fallos.length) { fallos.forEach((f) => console.log('MAL ' + f)); process.exit(1); }
console.log('casos: 4');
