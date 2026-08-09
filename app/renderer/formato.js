// formato.js -- convierte el texto de Mentis en HTML con formato, para la app Y para el celular.
//
// POR QUE EXISTE (2026-08-06, pedido del usuario): las respuestas se pintaban con textContent, o sea
// texto plano. Cuando Mentis contestaba con una lista, un titulo o algo en negrita, llegaban los
// asteriscos crudos: "**Importante**: no mezclar" en vez de "Importante: no mezclar". Los modelos
// escriben en markdown por costumbre, asi que la mitad de las respuestas tenian ruido tipografico.
//
// VIVE EN UN SOLO ARCHIVO Y LO USAN LOS DOS. La app lo importa directo y el servidor de la pagina
// del celular lo sirve desde /estatico (misma idea que cuerpo-digital.js). Tener dos copias de un
// formateador garantiza que un dia la app muestre negrita y el celular no.
//
// LA REGLA DE SEGURIDAD, QUE NO SE NEGOCIA: se ESCAPA PRIMERO y se formatea despues. Lo que entra
// aca es texto generado por un modelo, que a su vez puede venir de una pagina web que Mentis leyo.
// Si se formateara sobre el texto crudo, un "<img onerror=...>" en una pagina cualquiera terminaria
// ejecutandose adentro de la ventana de Mentis, que tiene acceso a la máquina del usuario.

const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function escaparHtml(txt) {
  return String(txt).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

// Los bloques de codigo se apartan ANTES de tocar nada mas: adentro de un bloque, un asterisco es
// un asterisco y un guion es un guion. Si se formateara primero, un fragmento de codigo con
// `*ptr` o `a * b` saldria en cursiva y con el asterisco comido.
// El marcador se arma con String.fromCharCode(1): un caracter de control que no puede venir en
// como ESCAPE y no como caracter literal a proposito: un byte de control invisible dentro del
// codigo sobrevive mal a las ediciones y al copiar y pegar, y si se perdiera el placeholder
// quedaria siendo un numero pelado -- con lo cual la restauracion se comeria cualquier numero del
// mensaje ("son 20 gramos" terminaria convertido en un bloque de codigo).
const MARCA = String.fromCharCode(1);

function apartar(txt, regex, guardados, envolver) {
  return txt.replace(regex, (...args) => {
    guardados.push(envolver(...args));
    return MARCA + (guardados.length - 1) + MARCA;
  });
}

function restaurar(txt, guardados) {
  // OJO con el doble backslash: esto es un STRING que despues se compila como regex. '\d' dentro
  // de un string de JavaScript no es la clase de digitos, es la letra 'd' -- asi que con un solo
  // backslash el patron buscaba "d+" literal, no encontraba nada, y los bloques de codigo
  // apartados nunca volvian: quedaban como un numero suelto en el medio del mensaje.
  return txt.replace(new RegExp(MARCA + '(\\d+)' + MARCA, 'g'), (_, i) => guardados[Number(i)]);
}

function formatearLinea(l) {
  // Negrita ANTES que cursiva: si se hiciera al reves, el ** de **negrita** se comeria como dos
  // cursivas vacias y quedaria un asterisco suelto.
  l = l.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  l = l.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
  // La cursiva con guion bajo exige bordes que no sean letras: sin eso, nombres_con_guiones_bajos
  // (rutas, variables, claves JSON) se romperian en cursivas a la mitad.
  // El contenido de la cursiva no puede empezar ni terminar con espacio. Sin esa condicion,
  // "2 * 3 * 4 = 24" se convertia en "2 <em> 3 </em> 4": cualquier multiplicacion escrita con
  // espacios quedaba en cursiva y perdia los asteriscos. Markdown de verdad tampoco lo permite.
  l = l.replace(/(^|[\s(])\*([^*\s\n](?:[^*\n]*[^*\s\n])?)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
  l = l.replace(/(^|[\s(])_([^_\s\n](?:[^_\n]*[^_\s\n])?)_(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
  l = l.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
  return l;
}

export function formatearMensaje(texto) {
  if (texto === null || texto === undefined) return '';
  let t = escaparHtml(texto).replace(/\r\n?/g, '\n');

  const guardados = [];
  // Bloques ``` con lenguaje opcional.
  t = apartar(t, /```([a-zA-Z0-9_+-]*)\n?([\s\S]*?)```/g, guardados,
    (_m, lang, cuerpo) => '<pre class="bloque-codigo"' + (lang ? ' data-lenguaje="' + lang + '"' : '') +
                          '><code>' + cuerpo.replace(/\n$/, '') + '</code></pre>');
  // Codigo en linea.
  t = apartar(t, /`([^`\n]+)`/g, guardados, (_m, cuerpo) => '<code>' + cuerpo + '</code>');

  const salida = [];
  let lista = null;   // 'ul' | 'ol' | null

  const cerrarLista = () => { if (lista) { salida.push('</' + lista + '>'); lista = null; } };

  for (const linea of t.split('\n')) {
    const titulo = /^(#{1,3})\s+(.*)$/.exec(linea);
    const vinieta = /^\s*[-*]\s+(.*)$/.exec(linea);
    const numerada = /^\s*\d+[.)]\s+(.*)$/.exec(linea);

    if (titulo) {
      cerrarLista();
      const n = titulo[1].length + 2;   // # -> h3, ## -> h4, ### -> h5 (h1/h2 son de la app)
      salida.push('<h' + n + '>' + formatearLinea(titulo[2]) + '</h' + n + '>');
    } else if (vinieta) {
      if (lista !== 'ul') { cerrarLista(); salida.push('<ul>'); lista = 'ul'; }
      salida.push('<li>' + formatearLinea(vinieta[1]) + '</li>');
    } else if (numerada) {
      if (lista !== 'ol') { cerrarLista(); salida.push('<ol>'); lista = 'ol'; }
      salida.push('<li>' + formatearLinea(numerada[1]) + '</li>');
    } else if (linea.trim() === '') {
      cerrarLista();
      salida.push('');
    } else {
      cerrarLista();
      salida.push(formatearLinea(linea));
    }
  }
  cerrarLista();

  // Los saltos se respetan tal cual: Mentis escribe parrafos cortos separados por saltos, y
  // convertirlos en <p> le cambiaria el ritmo a todas las respuestas.
  let html = salida.join('\n').replace(/\n/g, '<br>');
  // Un <br> pegado a un bloque o a una lista mete una linea vacia de mas.
  html = html.replace(/<br>(<\/?(?:ul|ol|li|h[3-5]|pre)\b)/g, '$1');
  html = html.replace(/(<\/(?:ul|ol|li|h[3-5]|pre)>)<br>/g, '$1');

  return restaurar(html, guardados);
}
