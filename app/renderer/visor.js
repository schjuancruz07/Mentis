// visor.js -- ver adentro de Mentis lo que Mentis crea (2026-08-12).
//
// POR QUE EXISTE: hasta hoy, todo lo que generaba (imagenes, modelos 3D, PDFs, paginas) aparecia
// como un chip "Abrir X" que llamaba a shell.openPath -- o sea que mirar un render implicaba
// salir de la app y volver. el usuario lo pidio con todas las letras para el modo Designe: "quiero que
// las cosas que Mentis cree se puedan ver en la misma app".
//
// COMO DECIDE QUE DIBUJAR: por tipo de archivo, y el tipo lo resuelve el proceso principal
// (main.js), no el nombre del archivo aca. El renderer no sabe de rutas ni tiene permiso de
// disco: pide 'verArtefacto' y recibe el contenido ya validado como data: URL o texto.
//
// LO QUE NO PUEDE, Y LO DICE: un.docx o un.xlsx no se dibujan en una ventana web. En vez de
// fallar con "no se pudo abrir" (que suena a error y no lo es), el visor muestra que ese formato
// se abre afuera y deja el boton para hacerlo. Decir la verdad sobre un limite es mejor que
// simular que se intento.
//
// THREE.JS SE CARGA SOLO SI HAY UN 3D. Es un import dinamico a proposito: son ~950 KB y la
// enorme mayoria de lo que Mentis crea son imagenes y documentos. Se retiro del paquete el
// 2026-08-11 junto con el cuerpo digital (24,8 MB -> 1,3 MB) y vuelve solo por esto, asi que
// vuelve pagando su costo unicamente cuando se usa.
'use strict';

const $ = (id) => document.getElementById(id);
let visorActual = null;   // la ruta que se esta mirando, para el boton "Abrir afuera"
let limpiar3D = null;     // corta el bucle de animacion al cerrar; sin esto sigue girando invisible

function cerrarVisor() {
  if (limpiar3D) { limpiar3D(); limpiar3D = null; }
  $('visor').classList.add('hidden');
  $('visor-cuerpo').replaceChildren();
  visorActual = null;
}

function ponerCuerpo(nodo) {
  const cuerpo = $('visor-cuerpo');
  cuerpo.replaceChildren(nodo);
}

function mensaje(texto, detalle) {
  const d = document.createElement('div');
  d.className = 'visor-mensaje';
  const p = document.createElement('p');
  p.textContent = texto;
  d.appendChild(p);
  if (detalle) {
    const s = document.createElement('span');
    s.textContent = detalle;
    d.appendChild(s);
  }
  return d;
}

// ---------------------------------------------------------------------------------------------
// 3D. Esferas y cilindros para moleculas, GLB/GLTF para lo que genera TripoSR.
async function dibujar3D(dataUrl, ext) {
  const cont = document.createElement('div');
  cont.className = 'visor-3d';
  ponerCuerpo(cont);

  const THREE = await import('three');
  const { OrbitControls } = await import('./assets/vendor/three/OrbitControls.js');
  const { GLTFLoader } = await import('./assets/vendor/three/GLTFLoader.js');

  const ancho = cont.clientWidth || 800;
  const alto = cont.clientHeight || 600;
  const escena = new THREE.Scene();
  escena.background = new THREE.Color(0x0a0a0b);
  const camara = new THREE.PerspectiveCamera(50, ancho / alto, 0.01, 1000);
  const render = new THREE.WebGLRenderer({ antialias: true });
  render.setSize(ancho, alto);
  render.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  cont.appendChild(render.domElement);

  // Dos luces y no una: con una sola, toda cara que no mire a la luz queda negra y el modelo se
  // lee como una silueta. La de relleno viene de atras y despega la forma del fondo.
  escena.add(new THREE.AmbientLight(0xffffff, 0.6));
  const principal = new THREE.DirectionalLight(0xffffff, 1.1);
  principal.position.set(3, 5, 4);
  escena.add(principal);
  const relleno = new THREE.DirectionalLight(0xffffff, 0.35);
  relleno.position.set(-4, -2, -3);
  escena.add(relleno);

  const controles = new OrbitControls(camara, render.domElement);
  controles.enableDamping = true;

  const loader = new GLTFLoader();
  const blob = await (await fetch(dataUrl)).blob();
  const url = URL.createObjectURL(blob);

  await new Promise((resolve) => {
    loader.load(url, (gltf) => {
      escena.add(gltf.scene);
      // Encuadre automatico: sin esto un modelo chico queda como un punto y uno grande no entra.
      // Se mide la caja real y se aleja la camara lo justo para que quepa en el campo de vision.
      const caja = new THREE.Box3().setFromObject(gltf.scene);
      const tam = caja.getSize(new THREE.Vector3());
      const centro = caja.getCenter(new THREE.Vector3());
      const mayor = Math.max(tam.x, tam.y, tam.z) || 1;
      const dist = (mayor / 2) / Math.tan((camara.fov * Math.PI) / 360) * 1.8;
      camara.position.set(centro.x + dist * 0.6, centro.y + dist * 0.4, centro.z + dist);
      camara.lookAt(centro);
      controles.target.copy(centro);
      controles.update();
      resolve();
    }, undefined, () => {
      ponerCuerpo(mensaje('No pude leer este modelo 3D.', ext + ' -- el archivo puede estar incompleto'));
      resolve();
    });
  });
  URL.revokeObjectURL(url);

  let vivo = true;
  (function animar() {
    if (!vivo) return;
    requestAnimationFrame(animar);
    controles.update();
    render.render(escena, camara);
  })();

  const alRedimensionar = () => {
    const a = cont.clientWidth, b = cont.clientHeight;
    if (!a || !b) return;
    camara.aspect = a / b; camara.updateProjectionMatrix(); render.setSize(a, b);
  };
  window.addEventListener('resize', alRedimensionar);

  // Sin esto el bucle sigue corriendo con el visor cerrado: gasta GPU para siempre y el contexto
  // WebGL nunca se libera (Chromium permite ~16 y despues empieza a matar los viejos).
  limpiar3D = () => {
    vivo = false;
    window.removeEventListener('resize', alRedimensionar);
    controles.dispose();
    render.dispose();
    render.forceContextLoss();
  };
}

// ---------------------------------------------------------------------------------------------
// Moleculas y cristales (modo Science). No es un modelo importado: se construye con esferas y
// cilindros a partir de las COORDENADAS reales que bajo capabilities/estructura.sh. Por eso lo
// que se ve en pantalla es el dato y no el render que hizo otro programa.
async function dibujarMolecula(est) {
  const cont = document.createElement('div');
  cont.className = 'visor-3d';
  ponerCuerpo(cont);

  const THREE = await import('three');
  const { OrbitControls } = await import('./assets/vendor/three/OrbitControls.js');

  const ancho = cont.clientWidth || 800;
  const alto = cont.clientHeight || 600;
  const escena = new THREE.Scene();
  escena.background = new THREE.Color(0x0a0a0b);
  const camara = new THREE.PerspectiveCamera(50, ancho / alto, 0.01, 5000);
  const render = new THREE.WebGLRenderer({ antialias: true });
  render.setSize(ancho, alto);
  render.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  cont.appendChild(render.domElement);

  escena.add(new THREE.AmbientLight(0xffffff, 0.65));
  const luz = new THREE.DirectionalLight(0xffffff, 1.0);
  luz.position.set(4, 6, 5);
  escena.add(luz);
  const relleno = new THREE.DirectionalLight(0xffffff, 0.3);
  relleno.position.set(-5, -3, -4);
  escena.add(relleno);

  const grupo = new THREE.Group();
  const elementos = est.elementos || {};
  // Una geometria de esfera y una de cilindro reutilizadas para TODOS los atomos: una celda
  // cristalina son cientos de esferas, y crear una geometria por cada una multiplica la memoria
  // sin cambiar un pixel de lo que se ve.
  const esfera = new THREE.SphereGeometry(1, 24, 18);
  const cilindro = new THREE.CylinderGeometry(1, 1, 1, 12);
  const materiales = {};
  const matDe = (el) => {
    if (!materiales[el]) {
      const c = (elementos[el] && elementos[el].color) || '#CCCCCC';
      materiales[el] = new THREE.MeshStandardMaterial({ color: c, roughness: 0.35, metalness: 0.1 });
    }
    return materiales[el];
  };

  // Escala de los atomos: 0,45 del radio covalente. Es la proporcion de "bolas y varillas" de
  // toda la quimica -- con el radio completo las esferas se tocan y no se ven los enlaces.
  for (const a of est.atomos) {
    const m = new THREE.Mesh(esfera, matDe(a.el));
    const r = ((elementos[a.el] && elementos[a.el].radio) || 1) * 0.45;
    m.scale.setScalar(r);
    m.position.set(a.x, a.y, a.z);
    grupo.add(m);
  }

  const matEnlace = new THREE.MeshStandardMaterial({ color: 0x9aa0a6, roughness: 0.5 });
  for (const [i, j] of est.enlaces || []) {
    const a = est.atomos[i], b = est.atomos[j];
    if (!a || !b) continue;
    const pa = new THREE.Vector3(a.x, a.y, a.z);
    const pb = new THREE.Vector3(b.x, b.y, b.z);
    const largo = pa.distanceTo(pb);
    if (!largo) continue;
    const m = new THREE.Mesh(cilindro, matEnlace);
    m.scale.set(0.08, largo, 0.08);
    m.position.copy(pa).add(pb).multiplyScalar(0.5);
    // El cilindro nace apuntando a +Y; se lo rota para que mire del atomo A al B.
    m.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0),
                                    pb.clone().sub(pa).normalize());
    grupo.add(m);
  }
  escena.add(grupo);

  const caja = new THREE.Box3().setFromObject(grupo);
  const centro = caja.getCenter(new THREE.Vector3());
  const tam = caja.getSize(new THREE.Vector3());
  const mayor = Math.max(tam.x, tam.y, tam.z) || 1;
  const dist = (mayor / 2) / Math.tan((camara.fov * Math.PI) / 360) * 2.0;
  camara.position.set(centro.x + dist * 0.5, centro.y + dist * 0.35, centro.z + dist);
  camara.lookAt(centro);

  const controles = new OrbitControls(camara, render.domElement);
  controles.enableDamping = true;
  controles.target.copy(centro);
  controles.update();

  // La ficha con la fuente del dato va SIEMPRE, y arriba del modelo. En Science la geometria sin
  // su procedencia es exactamente lo que el modo promete no hacer: una forma linda sin respaldo.
  const ficha = document.createElement('div');
  ficha.className = 'visor-ficha';
  const t = document.createElement('strong');
  t.textContent = est.nombre || '';
  ficha.appendChild(t);
  const f = document.createElement('span');
  f.textContent = est.fuente || '';
  ficha.appendChild(f);
  if (est.nota) {
    const n = document.createElement('em');
    n.textContent = est.nota;
    ficha.appendChild(n);
  }
  cont.appendChild(ficha);

  let vivo = true;
  (function animar() {
    if (!vivo) return;
    requestAnimationFrame(animar);
    controles.update();
    render.render(escena, camara);
  })();
  const alRedimensionar = () => {
    const a = cont.clientWidth, b = cont.clientHeight;
    if (!a || !b) return;
    camara.aspect = a / b; camara.updateProjectionMatrix(); render.setSize(a, b);
  };
  window.addEventListener('resize', alRedimensionar);
  limpiar3D = () => {
    vivo = false;
    window.removeEventListener('resize', alRedimensionar);
    controles.dispose(); render.dispose(); render.forceContextLoss();
    esfera.dispose(); cilindro.dispose();
    Object.values(materiales).forEach((m) => m.dispose());
    matEnlace.dispose();
  };
}

// ---------------------------------------------------------------------------------------------
async function abrirVisor(ruta) {
  const r = await window.mentisAPI.verArtefacto(ruta);
  if (!r || !r.ok) {
    $('visor').classList.remove('hidden');
    $('visor-nombre').textContent = 'No se pudo abrir';
    ponerCuerpo(mensaje('No pude mostrar esto.', (r && r.error) || 'error desconocido'));
    return;
  }
  visorActual = ruta;
  $('visor').classList.remove('hidden');
  $('visor-nombre').textContent = r.nombre || '';

  if (r.tipo === 'imagen') {
    const img = document.createElement('img');
    img.className = 'visor-imagen';
    img.src = r.dataUrl;
    img.alt = r.nombre || 'imagen creada por Mentis';
    ponerCuerpo(img);
  } else if (r.tipo === 'modelo3d') {
    ponerCuerpo(mensaje('Cargando el modelo…'));
    await dibujar3D(r.dataUrl, r.ext);
  } else if (r.tipo === 'molecula') {
    ponerCuerpo(mensaje('Armando la estructura…'));
    await dibujarMolecula(r.estructura);
  } else if (r.tipo === 'pdf' || r.tipo === 'html') {
    const marco = document.createElement('iframe');
    marco.className = 'visor-marco';
    // sandbox sin allow-same-origin: una pagina generada no tiene por que poder tocar la app que
    // la muestra. Con allow-scripts alcanza para que una infografia interactiva funcione.
    marco.setAttribute('sandbox', 'allow-scripts');
    marco.src = r.dataUrl;
    ponerCuerpo(marco);
  } else if (r.tipo === 'texto') {
    const pre = document.createElement('pre');
    pre.className = 'visor-texto';
    pre.textContent = r.texto || '';
    ponerCuerpo(pre);
  } else {
    ponerCuerpo(mensaje(
      `Los archivos ${r.ext || ''} se abren con una aplicación de Windows.`,
      r.motivo || 'Mentis no puede dibujarlos acá adentro, pero el archivo está listo.'));
  }
}

// ---------------------------------------------------------------------------------------------
// La galeria: todo lo que Mentis creo, lo mas nuevo primero.
async function abrirGaleria() {
  const r = await window.mentisAPI.listarCreaciones();
  $('visor').classList.remove('hidden');
  $('visor-nombre').textContent = 'Todo lo que creó Mentis';
  visorActual = null;
  if (!r || !r.ok) {
    ponerCuerpo(mensaje('No pude leer la carpeta de creaciones.', (r && r.error) || ''));
    return;
  }
  if (!r.archivos.length) {
    ponerCuerpo(mensaje('Todavía no creó nada.', 'Pedile una imagen, un modelo 3D o un documento.'));
    return;
  }
  const grilla = document.createElement('div');
  grilla.className = 'visor-galeria';
  for (const a of r.archivos) {
    const tarjeta = document.createElement('button');
    tarjeta.type = 'button';
    tarjeta.className = 'visor-tarjeta';
    if (a.tipo === 'imagen') {
      const mini = document.createElement('img');
      mini.loading = 'lazy';
      mini.alt = a.nombre;
      // La miniatura se pide una por una y no todas juntas: cargar 200 imagenes en base64 por
      // IPC de golpe congela la ventana. Esto llena cada una cuando le toca.
      window.mentisAPI.verArtefacto(a.ruta).then((v) => { if (v && v.ok && v.dataUrl) mini.src = v.dataUrl; });
      tarjeta.appendChild(mini);
    } else {
      const ico = document.createElement('span');
      ico.className = 'visor-tarjeta-ext';
      ico.textContent = (a.ext || '?').replace('.', '').toUpperCase();
      tarjeta.appendChild(ico);
    }
    const pie = document.createElement('span');
    pie.className = 'visor-tarjeta-nombre';
    pie.textContent = a.nombre;
    tarjeta.appendChild(pie);
    tarjeta.addEventListener('click', () => abrirVisor(a.ruta));
    grilla.appendChild(tarjeta);
  }
  ponerCuerpo(grilla);
}

$('visor-cerrar').addEventListener('click', cerrarVisor);
$('visor-galeria').addEventListener('click', abrirGaleria);
$('visor-afuera').addEventListener('click', () => {
  if (visorActual) window.mentisAPI.openArtifact(visorActual);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('visor').classList.contains('hidden')) cerrarVisor();
});

// renderer.js arma los chips de artefactos y no es un modulo, asi que la unica forma de que se
// hablen es una funcion global. Publicada aca y no al reves para que, si visor.js no cargara,
// renderer.js siga con el comportamiento viejo (abrir afuera) en vez de romperse.
window.MentisVisor = { abrir: abrirVisor, galeria: abrirGaleria };
