// Casos de temas.js. Lo corre tests/test-temas.sh.
//
// Lo que se prueba de verdad es el CONTRASTE. Un tema con lindos colores y texto ilegible es un
// tema roto, y "se ve bien" no es una medicion: se calcula el contraste real segun WCAG y se exige
// un minimo. Sin esto, el dia que alguien agregue una paleta a ojo, alguien mas se queda sin poder
// leer las respuestas.
import { TEMAS, TEMA_POR_DEFECTO, aplicarTema, listaDeTemas } from '../app/renderer/temas.js';

let fallas = [];

function rgb(hex) {
  const h = hex.replace('#', '');
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}
// Luminancia relativa segun WCAG 2.1.
function lum(hex) {
  const [r, g, b] = rgb(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contraste(a, b) {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

// 4.5 es el minimo WCAG AA para texto normal. Para texto atenuado y acentos se pide 3.0, que es el
// minimo para texto grande y elementos de interfaz: son etiquetas y detalles, no cuerpo de lectura.
const MIN_TEXTO = 4.5;
const MIN_SECUNDARIO = 3.0;

const fila = (a, b, c, d, e, f) =>
  String(a).padEnd(16) + String(b).padEnd(22) + String(c).padStart(8) +
  String(d).padStart(9) + String(e).padStart(9) + String(f).padStart(9);
console.log(fila('tema', 'nombre', 'txt/fon', 'txt/sec', 'dim/fon', 'ace/fon'));
for (const [id, t] of Object.entries(TEMAS)) {
  const v = t.vars;
  const c = {
    textoSobreFondo: contraste(v['--texto'], v['--fondo']),
    textoSobreSecundario: contraste(v['--texto'], v['--secundario']),
    dimSobreFondo: contraste(v['--texto-dim'], v['--fondo']),
    acentoSobreFondo: contraste(v['--acento'], v['--fondo']),
  };
  console.log(fila(id, t.nombre, c.textoSobreFondo.toFixed(2), c.textoSobreSecundario.toFixed(2),
                   c.dimSobreFondo.toFixed(2), c.acentoSobreFondo.toFixed(2)));

  if (c.textoSobreFondo < MIN_TEXTO)
    fallas.push(`${id}: el texto sobre el fondo da ${c.textoSobreFondo.toFixed(2)} (minimo ${MIN_TEXTO})`);
  if (c.textoSobreSecundario < MIN_TEXTO)
    fallas.push(`${id}: el texto sobre la burbuja da ${c.textoSobreSecundario.toFixed(2)} (minimo ${MIN_TEXTO}) -- es donde se leen las respuestas`);
  if (c.dimSobreFondo < MIN_SECUNDARIO)
    fallas.push(`${id}: el texto atenuado da ${c.dimSobreFondo.toFixed(2)} (minimo ${MIN_SECUNDARIO})`);
  if (c.acentoSobreFondo < MIN_SECUNDARIO)
    fallas.push(`${id}: el acento da ${c.acentoSobreFondo.toFixed(2)} (minimo ${MIN_SECUNDARIO}) -- se usa en botones y titulos`);
}

// Todos los temas tienen que definir TODAS las variables: si a uno le falta una, esa queda con el
// valor del tema anterior y aparece un color suelto que no pertenece a la paleta.
const claves = Object.keys(TEMAS[TEMA_POR_DEFECTO].vars).sort();
for (const [id, t] of Object.entries(TEMAS)) {
  const mias = Object.keys(t.vars).sort();
  const faltan = claves.filter((k) => !mias.includes(k));
  if (faltan.length) fallas.push(`${id}: le faltan variables (${faltan.join(', ')}) y van a quedar con el color del tema anterior`);
}

if (!TEMAS[TEMA_POR_DEFECTO]) fallas.push('el tema por defecto no existe en la lista');

// Antes se exigian 5 paletas o mas ("que haya de donde elegir"). Desde 2026-08-10 la regla es la
// contraria y por un motivo concreto: Mentis tiene una identidad de marca, y una identidad que el
// usuario puede cambiar por un violeta no es una identidad. Lo unico que sigue siendo eleccion
// suya es claro u oscuro -- que no es gusto, es la luz de la pieza.
// Este test es la traba: si alguien agrega un tema nuevo, tiene que venir a leer esto primero.
const claros = Object.values(TEMAS).filter((t) => t.claro);
const oscuros = Object.values(TEMAS).filter((t) => !t.claro);
if (claros.length !== 1)
  fallas.push(`tiene que haber exactamente UN tema claro y hay ${claros.length} -- ver el comentario de arriba antes de agregar otro`);
if (oscuros.length !== 1)
  fallas.push(`tiene que haber exactamente UN tema oscuro y hay ${oscuros.length} -- ver el comentario de arriba antes de agregar otro`);

// Los dos tienen que ser el MISMO color de marca, no dos identidades distintas. Se compara el tono
// del acento: si alguien pinta el claro de azul, esto lo agarra.
const tono = (hex) => {
  const [r, g, b] = rgb(hex).map((v) => v / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  if (max === min) return 0;
  const d = max - min;
  let h;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return ((h * 60) + 360) % 360;
};
if (claros.length === 1 && oscuros.length === 1) {
  const dif = Math.abs(tono(claros[0].vars['--acento']) - tono(oscuros[0].vars['--acento']));
  if (Math.min(dif, 360 - dif) > 20)
    fallas.push(`el acento del tema claro y el del oscuro son colores distintos (${Math.round(dif)}° de diferencia de tono): tienen que ser el mismo terracota, uno mas oscuro que el otro`);
}

// aplicarTema con un id inventado no puede dejar la pantalla sin colores: cae al de por defecto.
const falso = { style: { setProperty(k, v) { (this._v = this._v || {})[k] = v; } }, dataset: {} };
const usado = aplicarTema('no-existe-este-tema', falso);
if (usado !== TEMAS[TEMA_POR_DEFECTO]) fallas.push('un tema inexistente no cae al de por defecto');
if (!falso.style._v || !falso.style._v['--fondo']) fallas.push('aplicarTema no escribio las variables');
if (falso.style._v && !falso.style._v['color-scheme']) fallas.push('aplicarTema no fijo color-scheme (las barras del sistema quedarian del color equivocado)');

if (listaDeTemas().some((t) => !t.nombre || !t.muestra || t.muestra.length !== 3))
  fallas.push('listaDeTemas no devuelve nombre y muestra de color para el selector');

// ===== Los valores de arranque de style.css tienen que ser los del tema por defecto =====
// Antes de que corra una linea de JavaScript, la pantalla se pinta con los valores escritos en el
// bloque :root de style.css. Recien despues temas.js los pisa con la paleta guardada. Si esos dos
// juegos de colores no coinciden, cada arranque muestra medio segundo de una paleta que no existe
// -- y peor: cuando se cambio el tema por defecto a terracota, :root quedo con el acento nuevo y
// el fondo viejo, que era una mezcla de dos identidades distintas. Nadie lo iba a notar leyendo
// el codigo, porque los dos archivos por separado se veian bien.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const aqui = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(aqui, '..', 'app', 'renderer', 'style.css'), 'utf8');
const bloqueRaiz = (css.match(/:root\s*\{([\s\S]*?)\}/) || [])[1] || '';

// Solo los colores planos: --acento-soft y compania son rgba() y comparar strings de esos daria
// falsos negativos por un espacio de diferencia.
const COLORES = ['--fondo', '--principal', '--secundario', '--texto', '--texto-dim', '--acento',
                 '--peligro', '--border', '--bubble-usuario'];
const porDefecto = TEMAS[TEMA_POR_DEFECTO].vars;
for (const clave of COLORES) {
  const m = bloqueRaiz.match(new RegExp(clave + '\\s*:\\s*(#[0-9a-fA-F]{3,8})\\s*;'));
  if (!m) { fallas.push(`style.css :root no define ${clave} -- la primera pintada va a usar un color de ninguna parte`); continue; }
  const enCss = m[1].toLowerCase();
  const enTema = String(porDefecto[clave] || '').toLowerCase();
  if (enCss !== enTema)
    fallas.push(`${clave}: style.css arranca en ${enCss} pero el tema por defecto ('${TEMA_POR_DEFECTO}') es ${enTema} -- se ve un parpadeo de una paleta que no existe`);
}

// ===== El tema por defecto esta escrito en TRES archivos y los tres tienen que decir lo mismo =====
// temas.js no se puede importar desde el proceso principal (es un modulo ES y aquello es CommonJS),
// asi que el valor esta copiado en lib/settings-store.js y, para el primer instante de pintura, en
// renderer.js. Cuando se separan no falla nada: aplicarTema() cae en silencio al de por defecto y
// el color termina saliendo bien por accidente. Vivieron meses desfasados sin que nadie lo viera.
const fuentesDelDefecto = [
  ['app/lib/settings-store.js', /const TEMA_POR_DEFECTO = '([^']+)'/],
  ['app/renderer/renderer.js', /aparienciaActual = \{ paleta: '([^']+)'/],
];
for (const [rel, re] of fuentesDelDefecto) {
  const txt = readFileSync(join(aqui, '..', rel), 'utf8');
  const m = txt.match(re);
  if (!m) { fallas.push(`${rel}: no se encontro el tema por defecto (¿se renombro la variable?)`); continue; }
  if (m[1] !== TEMA_POR_DEFECTO)
    fallas.push(`${rel} dice '${m[1]}' pero temas.js dice '${TEMA_POR_DEFECTO}' -- se separaron y nadie se entera porque el fallback lo tapa`);
  if (!TEMAS[m[1]])
    fallas.push(`${rel} apunta a '${m[1]}', que no existe en la lista de temas`);
}

console.log();
for (const f of fallas) console.log('FALLA: ' + f);
console.log(fallas.length ? `${fallas.length} FALLAS` : `TODO OK (${Object.keys(TEMAS).length} temas)`);
process.exit(fallas.length ? 1 : 0);
