// bajar-fuentes.js -- baja las fuentes de la identidad Mentis y las deja EMPAQUETADAS en el repo.
//
// POR QUE EXISTE (2026-08-10, identidad terracota): la app tiene que verse igual sin internet y
// dentro de un.exe empaquetado. Un <link> a fonts.googleapis.com falla en las dos situaciones:
// sin red no baja nada y queda la fuente de respaldo, y en el repo publico agrega una llamada a
// un servidor de Google en cada arranque que nadie pidio. Asi que las fuentes viven en
// assets/fonts/ como archivos, y este script es la forma de volver a bajarlas si alguna vez hay
// que actualizarlas.
//
// SE CORRE A MANO, NO EN CADA BUILD: las fuentes ya estan committeadas. Correrlo de nuevo solo
// tiene sentido si se agrega una familia o si Google publica una version nueva.
//   node app/bajar-fuentes.js
//
// LICENCIAS: las seis familias son SIL Open Font License (OFL), que permite empaquetarlas y
// redistribuirlas en un proyecto comercial o abierto sin atribucion obligatoria. Por eso se
// pueden incluir en el repo publico; si alguna vez se agrega una familia que NO sea OFL, no va
// acá adentro.
//
// SOLO LATIN: Google parte cada familia en subconjuntos por alfabeto (latin, latin-ext, cirilico,
// griego, vietnamita). Se guardan solo 'latin' y 'latin-ext' -- alcanzan de sobra para español y
// evitan bajar ~400 KB de alfabetos que esta app no usa nunca.

'use strict';
const https = require('https');
const fs = require('fs');
const path = require('path');

const DESTINO = path.join(__dirname, 'renderer', 'assets', 'fonts');

// El User-Agent decide QUE FORMATO devuelve Google. Con un UA viejo o vacio manda.ttf (3-5x mas
// pesado); con uno de Chrome moderno manda woff2. No es cosmetico: son megabytes.
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
           '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// Cada entrada: el nombre con el que se pide a Google y para que se usa en la app.
const FAMILIAS = [
  { spec: 'Google+Sans+Flex:wght@100..900', para: 'toda la interfaz (cuerpo, botones, burbujas)' },
  { spec: 'Playfair+Display:ital,wght@1,800', para: 'logotipo maestro y Mentis Designe' },
  { spec: 'Syne:wght@700..800',              para: 'base del logotipo de Mentis Designe' },
  { spec: 'Silkscreen:wght@400;700',          para: 'logotipo de Mentis Code' },
  { spec: 'Plus+Jakarta+Sans:wght@600;800',   para: 'logotipo de Mentis Cowork' },
  { spec: 'Michroma',                         para: 'logotipo de Mentis Science' },
  // 2026-08-20: Study y Editor eran los dos unicos modos sin letra propia -- su logotipo salia
  // igual al del modo Mentis a secas, o sea que cambiar de modo no se notaba. Bitter es una slab
  // serif (aire de libro de texto) y Oswald una condensada de titulos (aire de placa de video).
  // Las dos son OFL, como el resto.
  { spec: 'Bitter:wght@700',                  para: 'logotipo de Mentis Study' },
  { spec: 'Oswald:wght@500',                  para: 'logotipo de Mentis Editor' },
];

const SUBCONJUNTOS = ['latin', 'latin-ext'];

function bajar(url, binario) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': UA } }, (res) => {
      if (res.statusCode !== 200) {
        // Se consume el cuerpo igual: dejar una respuesta sin leer traba el socket y el proceso
        // se queda colgado sin decir por que.
        res.resume();
        return reject(new Error(`${res.statusCode} al bajar ${url}`));
      }
      const trozos = [];
      res.on('data', (d) => trozos.push(d));
      res.on('end', () => resolve(binario ? Buffer.concat(trozos) : Buffer.concat(trozos).toString('utf8')));
    }).on('error', reject);
  });
}

// El CSS que devuelve Google viene con un comentario /* latin */ arriba de cada bloque @font-face.
// Ese comentario es la unica forma de saber a que alfabeto corresponde cada archivo sin parsear
// los unicode-range a mano, asi que se parte el texto por ahi.
function partirBloques(css) {
  const bloques = [];
  const re = /\/\*\s*([a-z0-9-]+)\s*\*\/\s*(@font-face\s*\{[^}]*\})/gi;
  let m;
  while ((m = re.exec(css)) !== null) bloques.push({ subconjunto: m[1], cuerpo: m[2] });
  return bloques;
}

function campo(bloque, nombre) {
  const m = bloque.match(new RegExp(nombre + '\\s*:\\s*([^;]+);'));
  return m ? m[1].trim() : '';
}

async function main() {
  fs.mkdirSync(DESTINO, { recursive: true });
  const reglas = [];
  let bajados = 0, pesoTotal = 0;

  for (const fam of FAMILIAS) {
    const css = await bajar(`https://fonts.googleapis.com/css2?family=${fam.spec}&display=swap`, false);
    const bloques = partirBloques(css).filter((b) => SUBCONJUNTOS.includes(b.subconjunto));
    if (!bloques.length) throw new Error(`no se encontro ningun subconjunto latino para ${fam.spec}`);

    for (const b of bloques) {
      const familia = campo(b.cuerpo, 'font-family').replace(/['"]/g, '');
      const estilo = campo(b.cuerpo, 'font-style') || 'normal';
      const peso = campo(b.cuerpo, 'font-weight') || '400';
      const rango = campo(b.cuerpo, 'unicode-range');
      const url = (b.cuerpo.match(/url\(([^)]+)\)/) || [])[1];
      if (!url) continue;

      // Nombre de archivo predecible y legible, no el hash de Google: si alguien abre la carpeta
      // tiene que poder decir que es cada cosa.
      const archivo = [familia.replace(/\s+/g, '-').toLowerCase(), peso.replace(/\s+/g, '-'),
                       estilo, b.subconjunto].join('-') + '.woff2';
      const bin = await bajar(url, true);
      fs.writeFileSync(path.join(DESTINO, archivo), bin);
      bajados++; pesoTotal += bin.length;
      console.log(`  ${archivo}  ${(bin.length / 1024).toFixed(1)} KB`);

      reglas.push(
        `@font-face {\n` +
        `  font-family: '${familia}';\n` +
        `  font-style: ${estilo};\n` +
        `  font-weight: ${peso};\n` +
        `  font-display: swap;\n` +
        `  src: url('./${archivo}') format('woff2');\n` +
        (rango ? `  unicode-range: ${rango};\n` : '') +
        `}`
      );
    }
    console.log(`${fam.spec.split(':')[0].replace(/\+/g, ' ')} -- ${fam.para}`);
  }

  const cabecera =
    `/* fuentes.css -- GENERADO POR app/bajar-fuentes.js. No editar a mano: se pisa.\n` +
    `   Las cinco familias son SIL Open Font License. Viven como archivos en esta misma carpeta\n` +
    `   para que la app se vea igual sin internet y dentro del.exe empaquetado.\n` +
    `   Regenerado: ${new Date().toISOString().slice(0, 10)} */\n\n`;
  fs.writeFileSync(path.join(DESTINO, 'fuentes.css'), cabecera + reglas.join('\n\n') + '\n');

  console.log(`\n${bajados} archivos, ${(pesoTotal / 1024).toFixed(0)} KB en total.`);
  console.log(`Escrito: ${path.join(DESTINO, 'fuentes.css')}`);
}

main().catch((e) => { console.error('FALLO:', e.message); process.exit(1); });
