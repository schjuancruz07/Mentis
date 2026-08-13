// temas.js -- las dos paletas de Mentis, para la app Y para la pagina del celular.
//
// POR QUE HAY DOS Y NO SIETE (2026-08-10, decision del usuario): hasta hoy habia siete paletas
// (naranja, azul, bosque, vino, violeta, papel) porque Mentis pasaba a usarlo mas gente y la idea
// era que cada uno lo pusiera a su gusto. Eso cambio: Mentis ahora TIENE una identidad -- terracota,
// blanco y negro -- y una identidad que se puede cambiar por un violeta no es una identidad. Lo que
// queda es la unica eleccion que sigue siendo del usuario y no de la marca: **claro u oscuro**, que
// no es gusto sino la luz que tenga en la pieza y como le vengan los ojos.
//
// LA IDEA DE CADA UNO, en palabras del usuario:
//   - El claro simula texturas naturales: papel, lienzo, pergamino. Nada de blanco de pantalla.
//   - El oscuro mantiene la calidez de la marca SIN negros puros ni grises azulados. El gris
//     carbon #141413 tiene una pizca de amarillo; un #0a0a0f cualquiera se ve azul al lado del
//     terracota y ensucia la marca entera.
//
// VIVE EN UN SOLO ARCHIVO Y LO USAN LOS DOS. La app lo importa y el servidor de la pagina lo sirve
// desde /estatico, igual que formato.js y el cuerpo digital. Si hubiera dos listas de temas, un dia
// la app tendria un color y el telefono otro.
//
// EL CONTRASTE NO ES DECORACION: hay un test (tests/temas_casos.mjs) que calcula el contraste real
// segun WCAG y falla si alguna combinacion baja del minimo. Un tema lindo con texto ilegible es un
// tema roto.
//
// DOS COLORES DE LA PALETA DE MARCA NO LLEGAN EN EL TEMA CLARO, y esta medido, no supuesto:
//   - Cloudy (#b1ada1) como texto secundario sobre el crema da 2.13 (minimo 3.0). En el OSCURO da
//     8.22 y ahi si se usa. En el claro queda para bordes, que son decoracion y no se leen.
//   - Crail (#d97757) como acento sobre el crema da 2.96, apenas por debajo de 3.0. En el oscuro
//     da 5.90 y ahi es el acento.
// el usuario dio dos opciones de cada uno ("gris medio o Cloudy", "#d97757 o #c15f3c"), asi que cada tema
// usa la que pasa: no se invento ningun color fuera de la paleta que el eligio.

export const TEMAS = {
  // El predeterminado. Gris carbon calido + crema + terracota Crail.
  //
  // EL ROJO DE PELIGRO NO ES TERRACOTA Y NO DEBE SERLO: terracota ya es un rojo apagado, asi que
  // un peligro del mismo tono haria que el boton de borrar se confunda con el de aceptar. Se
  // separan por saturacion, no por tono. Si alguien lo apaga "para que combine mejor", rompe la
  // unica senal visual de que algo es destructivo.
  'mentis-oscuro': {
    nombre: 'Mentis oscuro',
    claro: false,
    logo: 'oscuro',
    vars: {
      '--fondo': '#141413', '--principal': '#1f1e1d', '--secundario': '#2a2927',
      '--texto': '#faf9f5', '--texto-dim': '#b1ada1',
      '--acento': '#d97757', '--acento-soft': 'rgba(217, 119, 87, 0.16)',
      '--acento-rgb': '217, 119, 87',
      '--peligro': '#ff453a', '--peligro-soft': 'rgba(255, 69, 58, 0.16)',
      '--border': '#33322f', '--bubble-usuario': '#232220',
    },
  },

  // Papel, lienzo, pergamino. Va con color-scheme distinto para que los controles del sistema
  // (barras de desplazamiento, menus, campos nativos) no salgan oscuros sobre un fondo claro.
  //
  // Las TARJETAS son blanco puro y el FONDO es crema, no al reves: asi los bloques de texto se
  // levantan del lienzo en vez de fundirse con el. Con los dos en blanco no se distingue donde
  // termina un mensaje y empieza el siguiente.
  'mentis-claro': {
    nombre: 'Mentis claro',
    claro: true,
    logo: 'claro',
    vars: {
      '--fondo': '#faf9f5', '--principal': '#ffffff', '--secundario': '#f4f3ee',
      '--texto': '#141413', '--texto-dim': '#8a857a',
      '--acento': '#c15f3c', '--acento-soft': 'rgba(193, 95, 60, 0.12)',
      '--acento-rgb': '193, 95, 60',
      '--peligro': '#c62828', '--peligro-soft': 'rgba(198, 40, 40, 0.12)',
      '--border': '#b1ada1', '--bubble-usuario': '#f4f3ee',
    },
  },
};

// El naranja sobre negro ('mentis-clasico') fue el default hasta 2026-08-10, junto con otras cinco
// paletas de color que se retiraron el mismo dia. Si alguien las quiere de vuelta estan en el
// historial de git -- pero volver a meterlas significa volver a decidir que Mentis no tiene color
// propio, y esa fue justamente la decision que se tomo al reves.
export const TEMA_POR_DEFECTO = 'mentis-oscuro';

export function aplicarTema(id, raiz) {
  const t = TEMAS[id] || TEMAS[TEMA_POR_DEFECTO];
  const el = raiz || document.documentElement;
  for (const [k, v] of Object.entries(t.vars)) el.style.setProperty(k, v);
  // color-scheme le dice al navegador de que color pintar lo que no controlamos: barras de
  // desplazamiento, campos de texto nativos, menus. Sin esto, el tema claro queda con scrollbars
  // negras y se ve roto por un detalle que no esta en ningun CSS nuestro.
  el.style.setProperty('color-scheme', t.claro ? 'light' : 'dark');
  el.dataset.tema = id;
  // El tema tambien decide QUE LOGO se ve (pedido del usuario, 2026-08-10): el de fondo terracota va
  // con el tema claro y el de fondo carbon con el oscuro. Se expone como dato en el <html> para
  // que lo lea tanto el CSS como el proceso principal, que es quien cambia el icono de la ventana
  // y el de la bandeja -- esos no son CSS y no se pueden pintar desde aca.
  el.dataset.logo = t.logo || (t.claro ? 'claro' : 'oscuro');
  return t;
}

export function listaDeTemas() {
  return Object.entries(TEMAS).map(([id, t]) => ({ id, nombre: t.nombre, claro: !!t.claro,
                                                   logo: t.logo || (t.claro ? 'claro' : 'oscuro'),
                                                   muestra: [t.vars['--fondo'], t.vars['--acento'], t.vars['--texto']] }));
}
