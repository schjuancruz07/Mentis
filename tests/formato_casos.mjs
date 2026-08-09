// Casos de formato.js. Lo corre tests/test-formato.sh.
//
// El caso que NO se puede fallar es el de seguridad: lo que entra es texto de un modelo, que a su
// vez puede venir de una pagina web que Mentis leyo. Si el HTML no se escapa antes de formatear,
// una pagina cualquiera puede ejecutar codigo dentro de la ventana de Mentis.
import { formatearMensaje } from '../app/renderer/formato.js';

let fallas = 0;
const casos = [];

function caso(nombre, entrada, comprobar) {
  const salida = formatearMensaje(entrada);
  const problema = comprobar(salida);
  if (problema) { fallas++; casos.push('FALLA: ' + nombre + ' -> ' + problema + '\n   salida: ' + salida); }
  else { casos.push('ok: ' + nombre); }
}

const tiene = (s) => (out) => out.includes(s) ? null : 'esperaba ' + JSON.stringify(s);
const noTiene = (s) => (out) => !out.includes(s) ? null : 'NO esperaba ' + JSON.stringify(s);

// --- Seguridad ---------------------------------------------------------------------------------
caso('escapa etiquetas', '<img src=x onerror=alert(1)>', noTiene('<img'));
caso('escapa script', '<script>alert(1)</script>', noTiene('<script>'));
caso('escapa dentro de negrita', '**<b>hola</b>**', noTiene('<b>hola'));
caso('escapa dentro de codigo', '`<script>x</script>`', noTiene('<script>'));
caso('un onerror no sobrevive', 'texto <div onerror="x">', noTiene('onerror="x"'));

// --- Formato basico ----------------------------------------------------------------------------
caso('negrita', 'esto es **importante** si', tiene('<strong>importante</strong>'));
caso('cursiva', 'esto es *raro* si', tiene('<em>raro</em>'));
caso('negrita gana a cursiva', '**muy**', tiene('<strong>muy</strong>'));
caso('codigo en linea', 'usa `ls -la` ahi', tiene('<code>ls -la</code>'));
caso('bloque de codigo', '```python\nprint(1)\n```', tiene('<pre class="bloque-codigo"'));
caso('bloque conserva el lenguaje', '```python\nprint(1)\n```', tiene('data-lenguaje="python"'));
caso('titulo', '# Titulo', tiene('<h3>Titulo</h3>'));
caso('lista con guiones', '- uno\n- dos', tiene('<ul>'));
caso('lista numerada', '1. uno\n2. dos', tiene('<ol>'));
caso('tachado', '~~mal~~', tiene('<del>mal</del>'));

// --- Lo que NO se tiene que romper ---------------------------------------------------------------
caso('no rompe guiones bajos de nombres', 'el archivo nv_web_server.py anda', noTiene('<em>'));
caso('no formatea adentro de codigo', '`a * b * c`', noTiene('<em>'));
caso('no formatea adentro de bloque', '```\nx = a * b * c\n```', noTiene('<em>'));
caso('multiplicacion suelta no es cursiva', '2 * 3 * 4 = 24', noTiene('<em>'));
// El marcador interno no puede comerse numeros del mensaje: era el bug de usar un placeholder
// que fuera solo un digito.
caso('los numeros del texto quedan intactos', 'son 20 gramos y 3 rebanadas',
     (o) => o.includes('20 gramos') && o.includes('3 rebanadas') ? null : 'se comio un numero');
caso('codigo y numeros juntos', '`x` son 0 y 1 y `y`',
     (o) => o.includes('son 0 y 1') ? null : 'se comio un numero al restaurar');
caso('texto vacio no explota', '', (o) => o === '' ? null : 'esperaba cadena vacia');
caso('null no explota', null, (o) => o === '' ? null : 'esperaba cadena vacia');

console.log(casos.join('\n'));
console.log(fallas === 0 ? `\nTODO OK (${casos.length} casos)` : `\n${fallas} FALLAS de ${casos.length}`);
process.exit(fallas ? 1 : 0);
