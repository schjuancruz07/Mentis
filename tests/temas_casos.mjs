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
if (Object.keys(TEMAS).length < 5) fallas.push('hay menos de 5 temas para elegir');
if (!Object.values(TEMAS).some((t) => t.claro)) fallas.push('no hay ningun tema claro y mucha gente los prefiere');

// aplicarTema con un id inventado no puede dejar la pantalla sin colores: cae al de por defecto.
const falso = { style: { setProperty(k, v) { (this._v = this._v || {})[k] = v; } }, dataset: {} };
const usado = aplicarTema('no-existe-este-tema', falso);
if (usado !== TEMAS[TEMA_POR_DEFECTO]) fallas.push('un tema inexistente no cae al de por defecto');
if (!falso.style._v || !falso.style._v['--fondo']) fallas.push('aplicarTema no escribio las variables');
if (falso.style._v && !falso.style._v['color-scheme']) fallas.push('aplicarTema no fijo color-scheme (las barras del sistema quedarian del color equivocado)');

if (listaDeTemas().some((t) => !t.nombre || !t.muestra || t.muestra.length !== 3))
  fallas.push('listaDeTemas no devuelve nombre y muestra de color para el selector');

console.log();
for (const f of fallas) console.log('FALLA: ' + f);
console.log(fallas.length ? `${fallas.length} FALLAS` : `TODO OK (${Object.keys(TEMAS).length} temas)`);
process.exit(fallas.length ? 1 : 0);
