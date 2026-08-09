// Puente entre formato.js (modulo ES) y renderer.js (script clasico).
//
// renderer.js no puede hacer `import` porque se carga como script comun, y convertirlo en modulo
// cambiaria el orden de ejecucion de todo el archivo. Mismo arreglo que ya se uso para el cuerpo
// digital: un modulo chico que cuelga la funcion de window.
import { formatearMensaje, escaparHtml } from './formato.js';
import { TEMAS, TEMA_POR_DEFECTO, aplicarTema, listaDeTemas } from './temas.js';

window.MentisFormato = { formatearMensaje, escaparHtml };
window.MentisTemas = { TEMAS, TEMA_POR_DEFECTO, aplicarTema, listaDeTemas };

// El tema se aplica APENAS carga el modulo y no cuando el renderer termina de armar la pantalla:
// si se esperara, se veria un parpadeo naranja antes de pintar la paleta elegida. El valor guardado
// llega despues por IPC; hasta entonces rige el que ya esta en el CSS.
window.dispatchEvent(new Event('mentis-temas-listos'));
