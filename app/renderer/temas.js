// temas.js -- las paletas que se pueden elegir, para la app Y para la pagina del celular.
//
// POR QUE EXISTE (2026-08-06, pedido del usuario): Mentis pasa a usarlo mas gente, y cada uno tiene que
// poder ponerlo a su gusto. El naranja sobre negro es la identidad de Mentis para el usuario, no
// necesariamente para un familiar.
//
// VIVE EN UN SOLO ARCHIVO Y LO USAN LOS DOS. La app lo importa y el servidor de la pagina lo sirve
// desde /estatico, igual que formato.js y el cuerpo digital. Y funciona porque la app y la web ya
// usaban EXACTAMENTE los mismos nombres de variable CSS: --fondo, --texto, --acento y compania. Si
// hubiera dos listas de temas, un dia la app tendria un color y el telefono otro.
//
// EL CONTRASTE NO ES DECORACION: cada paleta tiene que dejar el texto legible sobre su fondo. Hay
// un test (tests/temas_casos.mjs) que calcula el contraste real de las combinaciones que importan y
// falla si alguna baja del minimo. Un tema lindo con texto ilegible es un tema roto.

export const TEMAS = {
  'mentis-clasico': {
    nombre: 'Mentis clásico',
    claro: false,
    vars: {
      '--fondo': '#050507', '--principal': '#141418', '--secundario': '#1c1c22',
      '--texto': '#dcdcdc', '--texto-dim': '#8b8b93',
      '--acento': '#ff6600', '--acento-soft': 'rgba(255, 102, 0, 0.16)',
      '--peligro': '#ff1100', '--peligro-soft': 'rgba(255, 17, 0, 0.16)',
      '--border': '#2e2e36', '--bubble-usuario': '#1f1f26',
    },
  },
  'noche-azul': {
    nombre: 'Noche azul',
    claro: false,
    vars: {
      '--fondo': '#04070f', '--principal': '#0e1524', '--secundario': '#151f33',
      '--texto': '#dde5f2', '--texto-dim': '#8496b3',
      '--acento': '#3d9dff', '--acento-soft': 'rgba(61, 157, 255, 0.16)',
      '--peligro': '#ff5169', '--peligro-soft': 'rgba(255, 81, 105, 0.16)',
      '--border': '#24314a', '--bubble-usuario': '#18233a',
    },
  },
  'bosque': {
    nombre: 'Bosque',
    claro: false,
    vars: {
      '--fondo': '#050a07', '--principal': '#101a13', '--secundario': '#17251b',
      '--texto': '#dbe6dd', '--texto-dim': '#879a8d',
      '--acento': '#4ecb7a', '--acento-soft': 'rgba(78, 203, 122, 0.16)',
      '--peligro': '#ff6b5b', '--peligro-soft': 'rgba(255, 107, 91, 0.16)',
      '--border': '#243527', '--bubble-usuario': '#1a2a1f',
    },
  },
  'vino': {
    nombre: 'Vino',
    claro: false,
    vars: {
      '--fondo': '#0a0507', '--principal': '#1a1014', '--secundario': '#26171d',
      '--texto': '#eadde1', '--texto-dim': '#a98d97',
      '--acento': '#ff5c8a', '--acento-soft': 'rgba(255, 92, 138, 0.16)',
      '--peligro': '#ff3b30', '--peligro-soft': 'rgba(255, 59, 48, 0.16)',
      '--border': '#3a242c', '--bubble-usuario': '#2a1a20',
    },
  },
  'violeta': {
    nombre: 'Violeta',
    claro: false,
    vars: {
      '--fondo': '#07050c', '--principal': '#151024', '--secundario': '#1e1733',
      '--texto': '#e2dcf2', '--texto-dim': '#9589b8',
      '--acento': '#a97bff', '--acento-soft': 'rgba(169, 123, 255, 0.16)',
      '--peligro': '#ff5169', '--peligro-soft': 'rgba(255, 81, 105, 0.16)',
      '--border': '#2f2547', '--bubble-usuario': '#221a3a',
    },
  },
  // El unico claro. Va con color-scheme distinto para que los controles del sistema (scrollbars,
  // menus) no salgan oscuros arriba de un fondo blanco.
  'papel': {
    nombre: 'Papel (claro)',
    claro: true,
    vars: {
      '--fondo': '#f7f5f0', '--principal': '#ffffff', '--secundario': '#eeebe3',
      '--texto': '#22201c', '--texto-dim': '#6b6760',
      '--acento': '#c2410c', '--acento-soft': 'rgba(194, 65, 12, 0.12)',
      '--peligro': '#b91c1c', '--peligro-soft': 'rgba(185, 28, 28, 0.12)',
      '--border': '#d6d1c6', '--bubble-usuario': '#e4e0d6',
    },
  },
};

export const TEMA_POR_DEFECTO = 'mentis-clasico';

export function aplicarTema(id, raiz) {
  const t = TEMAS[id] || TEMAS[TEMA_POR_DEFECTO];
  const el = raiz || document.documentElement;
  for (const [k, v] of Object.entries(t.vars)) el.style.setProperty(k, v);
  // color-scheme le dice al navegador de que color pintar lo que no controlamos: barras de
  // desplazamiento, campos de texto nativos, menus. Sin esto, el tema claro queda con scrollbars
  // negras y se ve roto por un detalle que no esta en ningun CSS nuestro.
  el.style.setProperty('color-scheme', t.claro ? 'light' : 'dark');
  el.dataset.tema = id;
  return t;
}

export function listaDeTemas() {
  return Object.entries(TEMAS).map(([id, t]) => ({ id, nombre: t.nombre, claro: !!t.claro,
                                                   muestra: [t.vars['--fondo'], t.vars['--acento'], t.vars['--texto']] }));
}
