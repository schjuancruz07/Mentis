/* =============================================================================
   CUERPO DIGITAL DE MENTIS
   =============================================================================
   Rescatado del prototipo que escribió el usuario ("Mentis cuerpo digital.html",
   2026-07-26). De aquel archivo se conserva SOLO el cuerpo: el núcleo de plasma,
   las tres mallas poliédricas, los doce anillos giroscópicos, la nube de
   partículas, las sinapsis digitales, las ondas de choque y la máquina de
   estados con su paleta.

   Lo que quedó afuera a propósito, porque era andamiaje de la demo y no el
   cuerpo en sí:
     - la barra de botones para cambiar de estado a mano (acá los estados los
       maneja Mentis según lo que esté haciendo de verdad),
     - el badge de "MODO: STANDBY [28.4°C]" (esa temperatura era decorativa,
       y Mentis no debería mostrar números inventados),
     - todo el control gestual por webcam con MediaPipe (prender la cámara para
       mover un logo no se justifica; si algún día se quiere, va aparte),
     - las fuentes y FontAwesome por CDN (eran para el HUD).

   Cambios necesarios para que viva dentro de la app:
     1. Deja de ser pantalla completa: se dibuja en el canvas que se le pase.
     2. Three.js sale de node_modules, no de un CDN: la app tiene que arrancar
        sin internet, y un logo que no carga por estar sin red es un logo roto.
     3. Se pausa solo cuando no está visible. La máquina no tiene GPU discreta,
        y no tiene sentido gastar cuadros dibujando algo que nadie ve.

   Uso:
       import { crearCuerpoDigital } from './cuerpo-digital.js';
       const cuerpo = crearCuerpoDigital(document.getElementById('mi-canvas'));
       cuerpo.setEstado('SPEAKING');
       cuerpo.destruir();
   ============================================================================= */

import * as THREE from '../node_modules/three/build/three.module.min.js';

// Paleta y comportamiento por estado, tal como los definió el usuario.
export const PALETA = {
  STANDBY:    { primary: 0xd95500, glow: 0xff7700, bg: 0x050507, speedMult: 0.6, pulseRate: 0.04 },
  PROCESSING: { primary: 0xff6600, glow: 0xff8800, bg: 0x050507, speedMult: 1.8, pulseRate: 0.22 },
  SPEAKING:   { primary: 0xffaa00, glow: 0xffcc00, bg: 0x050507, speedMult: 1.2, pulseRate: 0.15 },
  // ESCUCHANDO (2026-07-27): el único estado frío. Los otros cuatro son fuego -- Mentis
  // emitiendo. Cuando escucha se enfría al Gainsboro de la paleta: de un vistazo, y sin leer
  // un cartel, se distingue "te estoy oyendo" de "te estoy hablando". Late lento por su cuenta
  // (pulseRate bajo) porque el latido de verdad no sale de acá: sale de tu voz, vía setNivelVoz.
  LISTENING:  { primary: 0xdcdcdc, glow: 0xffffff, bg: 0x050507, speedMult: 0.9, pulseRate: 0.06 },
  ALERT:      { primary: 0xff1100, glow: 0xff3300, bg: 0x0a0204, speedMult: 2.8, pulseRate: 0.35 }
};

// Dos niveles de detalle. El completo es el del prototipo; el liviano existe
// porque este cuerpo puede terminar dibujándose en un rincón de la interfaz
// mientras Mentis trabaja, y ahí importa más no robarle CPU al turno que se vea
// espectacular.
const DETALLE = {
  alto:  { particulas: 2000, segmentosAnillo: 120, pulsos: 16, conexiones: 12, ondas: 2 },
  bajo:  { particulas: 500,  segmentosAnillo: 48,  pulsos: 8,  conexiones: 6,  ondas: 1 }
};

const ANILLOS = [
  { radius: 1.9, tube: 0.008, color: 0xff6600, rotX: Math.PI / 2,  rotY: 0,            rotZ: 0,           opacity: 0.9,  speedX: 0.2,   speedY: 0.05, wire: false },
  { radius: 2.1, tube: 0.012, color: 0xd4d4d8, rotX: 0,            rotY: Math.PI / 3,  rotZ: 0,           opacity: 0.8,  speedX: -0.15, speedY: 0.1,  wire: true },
  { radius: 2.3, tube: 0.006, color: 0xff7700, rotX: -Math.PI / 4, rotY: Math.PI / 6,  rotZ: Math.PI / 8, opacity: 0.75, speedX: 0.1,   speedY: -0.18, wire: false },
  { radius: 2.7, tube: 0.018, color: 0xd4d4d8, rotX: Math.PI / 6,  rotY: -Math.PI / 4, rotZ: 0,           opacity: 0.7,  speedX: -0.08, speedY: 0.12, wire: true },
  { radius: 3.0, tube: 0.009, color: 0xff6600, rotX: Math.PI / 3,  rotY: Math.PI / 2,  rotZ: -Math.PI / 6, opacity: 0.85, speedX: 0.12, speedY: 0.08, wire: false },
  { radius: 3.3, tube: 0.014, color: 0x71717a, rotX: -Math.PI / 3, rotY: 0,            rotZ: Math.PI / 4, opacity: 0.5,  speedX: -0.1,  speedY: -0.1, wire: true },
  { radius: 3.6, tube: 0.007, color: 0xff7700, rotX: 0,            rotY: -Math.PI / 3, rotZ: 0,           opacity: 0.8,  speedX: 0.18,  speedY: 0.03, wire: false },
  { radius: 4.0, tube: 0.022, color: 0xd4d4d8, rotX: Math.PI / 4,  rotY: Math.PI / 4,  rotZ: Math.PI / 3, opacity: 0.6,  speedX: -0.05, speedY: 0.08, wire: true },
  { radius: 4.3, tube: 0.008, color: 0xff6600, rotX: -Math.PI / 6, rotY: Math.PI / 3,  rotZ: 0,           opacity: 0.75, speedX: 0.08,  speedY: -0.12, wire: false },
  { radius: 4.7, tube: 0.012, color: 0x3f3f46, rotX: Math.PI / 2,  rotY: 0,            rotZ: -Math.PI / 4, opacity: 0.4, speedX: -0.04, speedY: 0.05, wire: true },
  { radius: 5.1, tube: 0.016, color: 0xff6600, rotX: 0,            rotY: -Math.PI / 6, rotZ: Math.PI / 6, opacity: 0.5,  speedX: 0.06,  speedY: -0.06, wire: false },
  { radius: 5.5, tube: 0.005, color: 0xd4d4d8, rotX: Math.PI / 3,  rotY: -Math.PI / 2, rotZ: 0,           opacity: 0.6,  speedX: -0.07, speedY: 0.02, wire: true }
];

function crearTexturaDestello(r, g, b) {
  const c = document.createElement('canvas');
  c.width = 32; c.height = 32;
  const ctx = c.getContext('2d');
  const grad = ctx.createRadialGradient(16, 16, 0, 16, 16, 16);
  grad.addColorStop(0, `rgba(${r}, ${g}, ${b}, 1)`);
  grad.addColorStop(0.3, `rgba(${r}, ${g}, ${b}, 0.7)`);
  grad.addColorStop(0.7, `rgba(${r}, ${g}, ${b}, 0.2)`);
  grad.addColorStop(1, 'rgba(0, 0, 0, 0)');
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, 32, 32);
  return new THREE.CanvasTexture(c);
}

function extraerVertices(geometria, destino) {
  const pos = geometria.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    destino.push(new THREE.Vector3(pos.getX(i), pos.getY(i), pos.getZ(i)));
  }
}

/**
 * @param {HTMLCanvasElement} canvas  dónde se dibuja
 * @param {object} opciones
 *        estado    estado inicial (default 'STANDBY')
 *        detalle   'alto' | 'bajo'  (default 'alto')
 *        deriva    si el cuerpo flota solo cuando está quieto (default true)
 */
export function crearCuerpoDigital(canvas, opciones = {}) {
  // Accesibilidad: si el sistema pide menos movimiento, se baja el detalle y se apaga la deriva
  // flotante. Antes esto lo cubría una regla de CSS sobre el logo; ahora que el logo es 3D, le
  // toca al propio cuerpo respetarlo.
  const menosMovimiento = typeof window !== 'undefined' && window.matchMedia
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const cfgDetalle = DETALLE[opciones.detalle] || (menosMovimiento ? DETALLE.bajo : DETALLE.alto);
  let estadoActual = PALETA[opciones.estado] ? opciones.estado : 'STANDBY';
  const conDeriva = menosMovimiento ? false : (opciones.deriva !== false);

  const reloj = new THREE.Clock();
  const escena = new THREE.Scene();
  escena.fog = new THREE.FogExp2(PALETA.STANDBY.bg, 0.022);

  const camara = new THREE.PerspectiveCamera(55, 1, 0.1, 1000);
  camara.position.set(0, 0, 10);

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

  const grupo = new THREE.Group();
  escena.add(grupo);

  const texturaDestello = crearTexturaDestello(255, 102, 0);
  const colorActual = new THREE.Color(PALETA[estadoActual].primary);
  const colorObjetivo = new THREE.Color(PALETA[estadoActual].primary);

  // --- núcleo de plasma ---
  const plasma = new THREE.Mesh(
    new THREE.SphereGeometry(0.85, 32, 32),
    new THREE.MeshBasicMaterial({ color: PALETA.STANDBY.glow, transparent: true, opacity: 0.8, wireframe: true })
  );
  grupo.add(plasma);

  // --- tres mallas poliédricas ---
  const icoInternoGeo = new THREE.IcosahedronGeometry(1.6, 2);
  const icoInterno = new THREE.Mesh(icoInternoGeo,
    new THREE.MeshBasicMaterial({ color: PALETA.STANDBY.primary, wireframe: true, transparent: true, opacity: 0.65 }));
  grupo.add(icoInterno);
  const verticesIco = [];
  extraerVertices(icoInternoGeo, verticesIco);

  const dodecaGeo = new THREE.DodecahedronGeometry(2.3, 1);
  const dodeca = new THREE.Mesh(dodecaGeo,
    new THREE.MeshBasicMaterial({ color: 0xd4d4d8, wireframe: true, transparent: true, opacity: 0.3 }));
  grupo.add(dodeca);
  const verticesDodeca = [];
  extraerVertices(dodecaGeo, verticesDodeca);

  const icoExternoGeo = new THREE.IcosahedronGeometry(3.1, 1);
  const icoExterno = new THREE.Mesh(icoExternoGeo,
    new THREE.MeshBasicMaterial({ color: 0x71717a, wireframe: true, transparent: true, opacity: 0.15 }));
  grupo.add(icoExterno);

  const nodos = new THREE.Points(icoExternoGeo, new THREE.PointsMaterial({
    color: PALETA.STANDBY.primary, size: 0.12, map: texturaDestello,
    transparent: true, blending: THREE.AdditiveBlending
  }));
  grupo.add(nodos);

  // --- anillos giroscópicos ---
  const anillos = [];
  for (const cfg of ANILLOS) {
    const anillo = new THREE.Mesh(
      new THREE.TorusGeometry(cfg.radius, cfg.tube, 16, cfgDetalle.segmentosAnillo),
      new THREE.MeshBasicMaterial({ color: cfg.color, transparent: true, opacity: cfg.opacity, wireframe: cfg.wire })
    );
    anillo.rotation.set(cfg.rotX, cfg.rotY, cfg.rotZ);
    anillo.userData = { baseSpeedX: cfg.speedX, baseSpeedY: cfg.speedY };
    anillos.push(anillo);
    grupo.add(anillo);
  }

  // --- nube de partículas ---
  const posiciones = new Float32Array(cfgDetalle.particulas * 3);
  for (let i = 0; i < cfgDetalle.particulas * 3; i += 3) {
    const radio = 1.8 + Math.random() * 5.8;
    const theta = Math.random() * Math.PI * 2;
    const phi = Math.acos((Math.random() * 2) - 1);
    posiciones[i]     = radio * Math.sin(phi) * Math.cos(theta);
    posiciones[i + 1] = radio * Math.sin(phi) * Math.sin(theta);
    posiciones[i + 2] = radio * Math.cos(phi);
  }
  const geoParticulas = new THREE.BufferGeometry();
  geoParticulas.setAttribute('position', new THREE.BufferAttribute(posiciones, 3));
  const particulas = new THREE.Points(geoParticulas, new THREE.PointsMaterial({
    color: PALETA.STANDBY.primary, size: 0.07, map: texturaDestello,
    transparent: true, opacity: 0.7, blending: THREE.AdditiveBlending, depthWrite: false
  }));
  grupo.add(particulas);

  // --- sinapsis digitales: vías + paquetes de luz ---
  const conexiones = [];
  for (let i = 0; i < cfgDetalle.conexiones; i++) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(6), 3));
    const linea = new THREE.Line(geo, new THREE.LineBasicMaterial({
      color: PALETA.STANDBY.primary, transparent: true, opacity: 0, blending: THREE.AdditiveBlending
    }));
    linea.userData = { active: false, opacity: 0, fadeSpeed: 0.015 };
    conexiones.push(linea);
    grupo.add(linea);
  }

  const pulsos = [];
  for (let i = 0; i < cfgDetalle.pulsos; i++) {
    const pulso = new THREE.Mesh(
      new THREE.SphereGeometry(0.04, 8, 8),
      new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0, blending: THREE.AdditiveBlending })
    );
    pulso.userData = { active: false, start: new THREE.Vector3(), end: new THREE.Vector3(), progress: 0, speed: 0.012 };
    pulsos.push(pulso);
    grupo.add(pulso);
  }

  // --- ondas de choque ---
  const ondas = [];
  for (let i = 0; i < cfgDetalle.ondas; i++) {
    const onda = new THREE.Mesh(
      new THREE.SphereGeometry(1, 24, 24),
      new THREE.MeshBasicMaterial({ color: PALETA.STANDBY.primary, wireframe: true, transparent: true, opacity: 0 })
    );
    onda.userData = { scale: 1, active: false, speed: 0.025 };
    ondas.push(onda);
    grupo.add(onda);
  }

  // --- luces ---
  const luzPunto = new THREE.PointLight(PALETA.STANDBY.primary, 3.0, 20);
  escena.add(luzPunto);
  escena.add(new THREE.AmbientLight(0xd4d4d8, 0.45));

  function dispararSinapsis() {
    const pulso = pulsos.find((p) => !p.userData.active);
    if (!pulso) return;
    const desde = verticesIco[Math.floor(Math.random() * verticesIco.length)].clone().applyEuler(icoInterno.rotation);
    const hasta = verticesDodeca[Math.floor(Math.random() * verticesDodeca.length)].clone().applyEuler(dodeca.rotation);
    pulso.userData.start.copy(desde);
    pulso.userData.end.copy(hasta);
    pulso.userData.progress = 0;
    pulso.userData.speed = 0.008 + Math.random() * 0.01;
    pulso.userData.active = true;
    pulso.material.opacity = 0.9;
    pulso.position.copy(desde);

    const via = conexiones.find((c) => !c.userData.active);
    if (via) {
      const arr = via.geometry.attributes.position.array;
      arr[0] = desde.x; arr[1] = desde.y; arr[2] = desde.z;
      arr[3] = hasta.x; arr[4] = hasta.y; arr[5] = hasta.z;
      via.geometry.attributes.position.needsUpdate = true;
      via.userData.active = true;
      via.userData.opacity = 0.6;
      via.material.opacity = 0.6;
    }
  }

  function dispararOnda() {
    const onda = ondas.find((o) => !o.userData.active);
    if (!onda) return;
    onda.userData.active = true;
    onda.userData.scale = 0.8;
    onda.scale.set(0.8, 0.8, 0.8);
    onda.material.opacity = 0.45;
  }

  // El radio se CALCULA de la tabla de anillos, no se escribe a mano. La primera versión de esto
  // llevaba un 3,75 puesto a ojo y el anillo más externo mide 5,5: el cuerpo seguía saliéndose
  // del cuadro y agrandar el canvas no lo arreglaba, porque el recorte era del encuadre 3D y no
  // del tamaño en píxeles. Sacándolo de ANILLOS, agregar un anillo nuevo reencuadra solo.
  const RADIO_CUERPO = ANILLOS.reduce((max, a) => Math.max(max, a.radius + a.tube), 0);
  const MARGEN = 1.06;

  function redimensionar() {
    const ancho = canvas.clientWidth || canvas.width || 300;
    const alto = canvas.clientHeight || canvas.height || 300;
    camara.aspect = ancho / alto;

    // POR QUÉ SENO Y NO TANGENTE (el error que dejaba el cuerpo cortado, 2026-07-27):
    // con tangente se encuadra un disco plano parado en el centro de la escena. Pero los anillos
    // GIRAN en los tres ejes, así que con el tiempo barren una esfera de radio R, y parte de esa
    // esfera queda MÁS CERCA de la cámara que el centro -- ahí es donde la perspectiva la agranda
    // y se sale por los bordes. El ángulo que ocupa una esfera de radio R vista desde una
    // distancia D es asin(R/D), no atan(R/D). Despejando: D = R / sin(fov/2).
    // Con tangente la cámara quedaba un 30% más cerca de lo necesario, y el recorte aparecía
    // recién cuando el anillo giraba hasta el peor ángulo -- por eso parecía intermitente.
    const mitadFovV = (camara.fov * Math.PI) / 180 / 2;
    // El fov de Three.js es el VERTICAL. El horizontal sale del aspecto, y en un canvas más alto
    // que ancho es el que manda.
    const mitadFovH = Math.atan(Math.tan(mitadFovV) * camara.aspect);
    const necesario = (mitad) => (RADIO_CUERPO * MARGEN) / Math.sin(mitad);
    camara.position.z = Math.max(necesario(mitadFovV), necesario(mitadFovH));

    camara.updateProjectionMatrix();
    renderer.setSize(ancho, alto, false);
  }

  let animando = false;
  let idFrame = null;

  // --- nivel de voz en vivo (estado LISTENING) ---
  // El núcleo late con TU volumen real, no con un seno decorativo. Tres detalles que son la
  // diferencia entre que se sienta vivo o epiléptico:
  //   1. Ataque rápido / caída lenta, como un vúmetro. Si subiera y bajara a la misma velocidad
  //      temblaría en cada sílaba; así acompaña la frase.
  //   2. Raíz cuadrada sobre el nivel. El RMS de una voz normal ronda 0.05-0.15: lineal, no se
  //      movería nada. La raíz levanta lo bajo sin saturar lo alto.
  //   3. Caducidad. Si el que alimenta el nivel se cae (se cortó la grabación, se colgó el
  //      micrófono), el núcleo vuelve solo a reposo en ~300 ms en vez de quedar trabado abierto
  //      mostrando un volumen que ya no existe.
  const NIVEL_CADUCA_MS = 300;
  const ATAQUE = 0.35;
  const CAIDA = 0.08;
  let nivelObjetivo = 0;
  let nivelSuave = 0;
  let nivelSelloMs = 0;

  function cuadro() {
    if (!animando) return;
    idFrame = requestAnimationFrame(cuadro);
    const t = reloj.getElapsedTime();
    const cfg = PALETA[estadoActual];

    colorActual.lerp(colorObjetivo, 0.05);
    plasma.material.color.copy(colorActual);
    icoInterno.material.color.copy(colorActual);
    nodos.material.color.copy(colorActual);
    luzPunto.color.copy(colorActual);

    // Si nadie refresca el nivel, se considera vencido y cae a cero solo.
    if (nivelObjetivo > 0 && (Date.now() - nivelSelloMs) > NIVEL_CADUCA_MS) nivelObjetivo = 0;
    nivelSuave += (nivelObjetivo - nivelSuave) * (nivelObjetivo > nivelSuave ? ATAQUE : CAIDA);

    // El pulso del núcleo cambia según el estado: rápido y marcado cuando habla
    // (simula la modulación de la voz), lento y suave cuando espera.
    let escalaPulso;
    if (estadoActual === 'LISTENING') {
      // Acá el latido NO se simula: es tu voz entrando. El seno queda solo como respiración de
      // fondo para que el núcleo no se congele en el silencio entre frases.
      const respiracion = Math.sin(t * 1.6) * 0.02;
      escalaPulso = 1 + respiracion + Math.sqrt(nivelSuave) * 0.45;
    } else {
      let amplitud = 0.04, frecuencia = 1.2;
      if (estadoActual === 'SPEAKING') { amplitud = 0.12; frecuencia = 4.5; }
      else if (estadoActual === 'ALERT') { amplitud = 0.09; frecuencia = 3.0; }
      escalaPulso = 1 + Math.sin(t * frecuencia) * amplitud;
    }
    plasma.scale.set(escalaPulso, escalaPulso, escalaPulso);
    plasma.rotation.y = t * (0.12 * cfg.speedMult);

    icoInterno.rotation.y = t * (0.05 * cfg.speedMult);
    icoInterno.rotation.x = -t * (0.025 * cfg.speedMult);
    dodeca.rotation.y = -t * (0.035 * cfg.speedMult);
    icoExterno.rotation.y = t * (0.015 * cfg.speedMult);

    for (const anillo of anillos) {
      anillo.rotation.x += anillo.userData.baseSpeedX * 0.005 * cfg.speedMult;
      anillo.rotation.y += anillo.userData.baseSpeedY * 0.005 * cfg.speedMult;
    }
    particulas.rotation.y = t * 0.01 * cfg.speedMult;

    // Escuchando, la luz del núcleo sube con tu voz: el cuerpo se ilumina cuando hablás fuerte y
    // se apaga en los silencios. Es la misma señal que la escala, aplicada a otra propiedad, así
    // que respira entero en vez de solo inflarse.
    luzPunto.intensity = estadoActual === 'LISTENING' ? 3.0 + nivelSuave * 5.0 : 3.0;

    // Las sinapsis también salen de tu voz mientras escucha: cuanto más fuerte hablás, más
    // tráfico interno. No es azar decorativo -- es la única fuente de actividad que hay en ese
    // momento, porque el motor todavía no arrancó.
    const tasaSinapsis = estadoActual === 'LISTENING'
      ? cfg.pulseRate + nivelSuave * 0.30
      : cfg.pulseRate;
    if (Math.random() < tasaSinapsis) dispararSinapsis();

    for (const pulso of pulsos) {
      if (!pulso.userData.active) continue;
      pulso.userData.progress += pulso.userData.speed * cfg.speedMult;
      pulso.position.lerpVectors(pulso.userData.start, pulso.userData.end, pulso.userData.progress);
      if (pulso.userData.progress >= 1) {
        pulso.userData.active = false;
        pulso.material.opacity = 0;
      }
    }

    for (const via of conexiones) {
      if (!via.userData.active) continue;
      via.userData.opacity -= via.userData.fadeSpeed;
      via.material.opacity = Math.max(0, via.userData.opacity);
      if (via.userData.opacity <= 0) via.userData.active = false;
    }

    if (estadoActual === 'ALERT' && Math.random() < 0.04) dispararOnda();
    else if (estadoActual === 'SPEAKING' && Math.random() < 0.02) dispararOnda();
    // Escuchando, la onda es la reacción al golpe de voz: sale sola cuando levantás el volumen,
    // no cada tantos cuadros. El umbral evita que el ruido de fondo la dispare sin parar.
    else if (estadoActual === 'LISTENING' && nivelSuave > 0.35 && Math.random() < nivelSuave * 0.10) dispararOnda();

    for (const onda of ondas) {
      if (!onda.userData.active) continue;
      onda.userData.scale += onda.userData.speed * cfg.speedMult;
      onda.scale.set(onda.userData.scale, onda.userData.scale, onda.userData.scale);
      onda.material.opacity *= 0.95;
      if (onda.material.opacity < 0.01) {
        onda.userData.active = false;
        onda.material.opacity = 0;
      }
    }

    if (conDeriva) {
      grupo.position.x = Math.sin(t * 0.4) * 0.15;
      grupo.position.y = Math.sin(t * 0.6) * 0.12 + Math.cos(t * 0.3) * 0.15;
    }

    renderer.render(escena, camara);
  }

  function reanudar() {
    if (animando) return;
    animando = true;
    cuadro();
  }

  function pausar() {
    animando = false;
    if (idFrame) cancelAnimationFrame(idFrame);
    idFrame = null;
  }

  // Si el canvas sale de pantalla, se deja de dibujar. Sin esto el cuerpo sigue
  // consumiendo cuadros aunque esté tapado por un modal o fuera del scroll.
  let observador = null;
  if (typeof IntersectionObserver !== 'undefined') {
    observador = new IntersectionObserver((entradas) => {
      for (const e of entradas) {
        if (e.isIntersecting) { redimensionar(); reanudar(); } else { pausar(); }
      }
    }, { threshold: 0.01 });
    observador.observe(canvas);
  }

  // Bug real (2026-07-26): el canvas quedaba en 300x150 -- el tamaño por defecto de HTML -- en
  // vez del que le da el CSS. Pasa cuando se monta antes de que el layout esté resuelto:
  // clientWidth devuelve 0 y el cálculo cae al valor por defecto. Un 'resize' de ventana no
  // alcanza, porque el canvas puede cambiar de tamaño sin que la ventana se mueva (al abrirse un
  // panel, al pasar de chico a pantalla completa). ResizeObserver mira el elemento en sí.
  let observadorTamano = null;
  if (typeof ResizeObserver !== 'undefined') {
    observadorTamano = new ResizeObserver(() => redimensionar());
    observadorTamano.observe(canvas);
  }

  const alRedimensionar = () => redimensionar();
  window.addEventListener('resize', alRedimensionar);

  redimensionar();
  reanudar();

  return {
    /** Cambia el estado del cuerpo: STANDBY | PROCESSING | LISTENING | SPEAKING | ALERT */
    setEstado(nuevo) {
      if (!PALETA[nuevo] || nuevo === estadoActual) return;
      estadoActual = nuevo;
      colorObjetivo.setHex(PALETA[nuevo].primary);
      escena.fog.color.setHex(PALETA[nuevo].bg);
      // Sacudida breve al cambiar de estado: el "glitch" del prototipo, sin la
      // capa de scanlines (esa vivía en el HTML de la demo).
      grupo.rotation.x += (Math.random() - 0.5) * 0.3;
      grupo.rotation.y += (Math.random() - 0.5) * 0.3;
    },
    getEstado() { return estadoActual; },
    /** Enciende UNA conexión sináptica ahora mismo.
     *  Lo usa la app para que cada paso real del motor (un archivo escrito, un comando
     *  ejecutado, una búsqueda) se vea como un pulso viajando por el cuerpo, en vez de que las
     *  sinapsis sean puro azar decorativo. */
    dispararSinapsis,
    /** Volumen del micrófono AHORA, de 0 a 1. Es lo que hace latir al núcleo en LISTENING.
     *  Hay que llamarlo seguido (una vez por cuadro): si deja de llegar, el nivel vence a los
     *  300 ms y el núcleo vuelve solo a reposo. Los valores fuera de rango se recortan, así que
     *  quien lo alimenta no necesita normalizar con cuidado. */
    setNivelVoz(nivel) {
      const n = Number(nivel);
      nivelObjetivo = Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0;
      nivelSelloMs = Date.now();
    },
    /** El nivel ya suavizado que se está dibujando (para tests y para la interfaz). */
    getNivelVoz() { return nivelSuave; },
    redimensionar,
    pausar,
    reanudar,
    destruir() {
      pausar();
      window.removeEventListener('resize', alRedimensionar);
      if (observador) observador.disconnect();
      if (observadorTamano) observadorTamano.disconnect();
      escena.traverse((obj) => {
        if (obj.geometry) obj.geometry.dispose();
        if (obj.material) {
          const mats = Array.isArray(obj.material) ? obj.material : [obj.material];
          for (const m of mats) { if (m.map) m.map.dispose(); m.dispose(); }
        }
      });
      renderer.dispose();
    }
  };
}
