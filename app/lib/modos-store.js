'use strict';
// modos-store.js -- lee y escribe el modo de Mentis desde el proceso principal.
//
// POR QUE EXISTE (2026-08-10): Mentis pasa a tener cuatro modos y la app necesita mostrarlos,
// saber cuál está puesto y poder cambiarlo. La decisión de QUÉ hace cada modo no vive acá: vive
// en modos.json, que también leen el motor (engine/nv-modos-lib.sh) y la página del celular.
//
// UNA SOLA LISTA PARA LOS TRES. Es la misma razón por la que temas.js es un archivo compartido:
// si la app armara su propia lista de modos, un día tendría un modo que el motor no conoce, o al
// revés -- y el síntoma sería "elegí Code y sigue sin poder ejecutar", que es dificilísimo de
// diagnosticar porque las dos mitades parecen correctas por separado.
//
// ESTE ARCHIVO NO DECIDE PERMISOS. Solo lee y guarda cuál está elegido. Quien traduce el modo a
// permisos concretos es mentis-chat.sh, en el turno, y ahí la regla es que el modo sólo puede
// QUITAR sobre lo que los conectores ya permitían.

const fs = require('fs');
const path = require('path');

function rutaModos(mentisEnvDir) { return path.join(mentisEnvDir, 'modos.json'); }
function rutaEstado(mentisEnvDir) { return path.join(mentisEnvDir, 'state.json'); }

function leerJson(p, siFalla) {
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')); } catch (e) { return siFalla; }
}

// La declaración completa. Si el archivo no está o está roto se devuelve una estructura mínima
// con un solo modo en vez de null: la app tiene que poder abrir igual. Un Mentis sin selector de
// modos es incómodo; un Mentis que no abre porque un JSON tiene una coma de más es inservible.
function leerDeclaracion(mentisEnvDir) {
  const d = leerJson(rutaModos(mentisEnvDir), null);
  if (d && d.modos && Object.keys(d.modos).length) return d;
  return { por_defecto: 'mentis', modos: { mentis: { titulo: 'Mentis', descripcion: '', letra: 'google-sans' } } };
}

function listaDeModos(mentisEnvDir) {
  const d = leerDeclaracion(mentisEnvDir);
  return Object.entries(d.modos).map(([id, m]) => ({
    id,
    titulo: m.titulo || id,
    descripcion: m.descripcion || '',
    letra: m.letra || 'google-sans',
  }));
}

function modoActual(mentisEnvDir) {
  const d = leerDeclaracion(mentisEnvDir);
  const s = leerJson(rutaEstado(mentisEnvDir), {});
  const elegido = String(s.modo || '');
  // Un modo guardado que ya no existe (se renombró, se sacó) NO puede dejar a Mentis sin modo:
  // cae al de fábrica. Lo mismo hace nv_modo_actual del lado del motor, a propósito -- si los dos
  // lados degradaran distinto, la app mostraría un modo y el turno correría con otro.
  if (d.modos[elegido]) return elegido;
  return d.por_defecto && d.modos[d.por_defecto] ? d.por_defecto : Object.keys(d.modos)[0];
}

function datosDelModo(mentisEnvDir, id) {
  const d = leerDeclaracion(mentisEnvDir);
  const m = d.modos[id] || d.modos[modoActual(mentisEnvDir)] || {};
  const unicos = (a) => [...new Set(a)];
  return {
    id,
    titulo: m.titulo || id,
    descripcion: m.descripcion || '',
    letra: m.letra || 'google-sans',
    // Los paneles y las capacidades se calculan igual que del lado del motor -- nucleo + modo --
    // para que la interfaz y el turno no puedan contar historias distintas sobre el mismo modo.
    // Es el mismo motivo por el que modos.json es un solo archivo: dos fuentes terminan siendo
    // dos productos.
    paneles: unicos((((d.paneles || {}).nucleo) || []).concat(m.paneles || [])),
    capacidades: unicos((((d.nucleo || {}).capacidades) || []).concat(m.capacidades || [])),
    invasivas: !!m.invasivas,
    // LAS BANDERAS DEL MODO, para que la app muestre exactamente los botones de capacidad que
    // ese modo puede usar. La regla: el botón se ve si y sólo si el modo tiene su bandera. Una
    // lista aparte de "botones por modo" se desincronizaría del reparto real el primer día.
    //
    // `banderas_fuera` (2026-08-12): el núcleo también se puede recortar. Study apaga la web
    // porque es un modo de corpus cerrado, y sin este filtro el usuario vería el botón de navegar
    // encendido en un modo que no navega -- la interfaz prometiendo algo que el motor rechaza.
    // Se resta AL FINAL y sólo quita: es la misma invariante que del lado del motor.
    banderas: unicos((((d.nucleo || {}).banderas) || [])
.concat(m.banderas || [])
.concat(m.invasivas ? (((d.invasivas || {}).banderas) || []) : []))
.filter((b) => !(m.banderas_fuera || []).includes(b)),
  };
}

// Guardar reescribe state.json ENTERO leyéndolo antes: nunca se parchea el texto. Es un archivo
// que tocan varios procesos (el motor, la app, los scripts) y un reemplazo de texto sobre JSON
// funciona hasta el día que aparece una clave con una llave adentro de un string.
function guardarModo(mentisEnvDir, id) {
  const d = leerDeclaracion(mentisEnvDir);
  if (!d.modos[id]) return { ok: false, error: `modo desconocido: ${id}` };
  const p = rutaEstado(mentisEnvDir);
  const s = leerJson(p, {});
  s.modo = id;
  try {
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
  return { ok: true, modo: datosDelModo(mentisEnvDir, id) };
}

module.exports = { leerDeclaracion, listaDeModos, modoActual, datosDelModo, guardarModo };
