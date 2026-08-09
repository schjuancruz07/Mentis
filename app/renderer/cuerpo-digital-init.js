/* =============================================================================
   PUENTE ENTRE EL CUERPO DIGITAL Y EL RESTO DE LA APP
   =============================================================================
   cuerpo-digital.js es un módulo ESM (Three.js solo se distribuye así). renderer.js
   es un script clásico de 3000 líneas. Convertirlo entero a módulo para poder
   importar el cuerpo sería un cambio grande y riesgoso a cambio de nada, así que
   este archivo hace de puente: importa el módulo y publica una API mínima en
   window.MentisCuerpo, que renderer.js usa sin enterarse de que hay módulos.

   LA SINAPSIS SALE DE ACTIVIDAD REAL, Y NO CUESTA NADA (pedido del usuario):
   el motor ya emite sus pasos por stderr y la app ya los reenvía al renderer
   ('mentis:log') para el panel de progreso. El cuerpo se cuelga de ESE flujo que
   ya existe: cada línea de progreso dispara una sinapsis. No agrega una sola
   consulta ni una llamada extra al motor -- son eventos que ya viajaban.
   ============================================================================= */

import { crearCuerpoDigital } from './cuerpo-digital.js';

const instancias = {};

window.MentisCuerpo = {
  crear: crearCuerpoDigital,
  instancias,

  /** Cambia el estado de TODOS los cuerpos vivos a la vez. */
  setEstado(estado) {
    for (const c of Object.values(instancias)) {
      if (c && typeof c.setEstado === 'function') c.setEstado(estado);
    }
  },

  /** Reparte el volumen del micrófono a todos los cuerpos vivos (estado LISTENING). */
  setNivelVoz(nivel) {
    for (const c of Object.values(instancias)) {
      if (c && typeof c.setNivelVoz === 'function') c.setNivelVoz(nivel);
    }
  },

  /** Cuerpo puntual por nombre ('splash', 'onboarding', 'voz',...). */
  get(nombre) { return instancias[nombre] || null; },

  /** Monta un cuerpo nuevo sobre un canvas y lo registra con un nombre. */
  montar(nombre, canvas, opciones) {
    if (!canvas) return null;
    if (instancias[nombre]) instancias[nombre].destruir();
    instancias[nombre] = crearCuerpoDigital(canvas, opciones);
    return instancias[nombre];
  },

  /** Lo desmonta y libera la memoria de GPU. */
  desmontar(nombre) {
    if (!instancias[nombre]) return;
    instancias[nombre].destruir();
    delete instancias[nombre];
  }
};

// El del splash se monta solo: es lo primero que se ve al abrir la app y no puede
// depender de que alguien se acuerde de inicializarlo.
const canvasSplash = document.getElementById('splash-cuerpo');
if (canvasSplash) {
  window.MentisCuerpo.montar('splash', canvasSplash, { detalle: 'alto', estado: 'STANDBY' });
}

// El del onboarding es chico y aparece una sola vez: con detalle bajo alcanza y de
// paso no pelea por CPU con el arranque de la app.
const canvasOnboarding = document.getElementById('onboarding-cuerpo');
if (canvasOnboarding) {
  window.MentisCuerpo.montar('onboarding', canvasOnboarding, { detalle: 'bajo', estado: 'STANDBY' });
}

// renderer.js corre ANTES que este módulo (los módulos son diferidos por
// definición), así que no puede usar la API en su primera pasada. Este evento le
// avisa que ya puede.
window.dispatchEvent(new CustomEvent('mentis-cuerpo-listo'));
