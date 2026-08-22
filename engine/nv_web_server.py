#!/usr/bin/env python3
"""nv_web_server.py -- Mentis desde el celular, sin estar sentado en la computadora (2026-07-30).

POR QUE EXISTE
    el usuario pidio poder mandarle un mensaje a Mentis sin estar pegado a la maquina. Esto sirve una
    pagina chiquita en la red de casa: se abre desde el navegador del telefono, se escribe (o se
    dicta con el teclado de Android, que no tiene limite de duracion) y la respuesta aparece ahi.

POR QUE ESTA ACOTADO
    La pagina vive en la WiFi de una casa donde hay mas gente. Dos candados, no uno:
      1. TOKEN obligatorio en cada pedido, incluida la pagina misma. Sin token no hay nada.
      2. Mentis corre en MODO REMOTO (mentis-chat.sh -R): conversa, consulta, busca y navega,
         pero NO escribe archivos, NO ejecuta comandos, NO mira la pantalla, NO prende la camara
         y NO controla la computadora. Eso se pide sentado adelante.

    El token se compara con hmac.compare_digest y no con ==: comparar cadenas secretas con == deja
    ver cuantos caracteres acertaste por el tiempo que tarda en fallar.

COMO SE CONTESTA
    No se parsea la salida del chat. Se anota donde termina history.jsonl ANTES de correrlo y se
    leen las lineas nuevas despues: el propio chat ya escribe ahi cada turno como JSON. Parsear
    una salida pensada para una persona es una fuente de bugs que se descubren un martes.

Uso:
    nv_web_server.py --raiz <ruta a Mentis> --puerto 8765 --estado ruta/estado.json [--token XXX]
"""
import argparse
import hmac
import json
import os
import re
import socket
import subprocess
import threading
import time
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Import por ruta absoluta y no relativo: este servidor se lanza con `python nv_web_server.py`
# desde una carpeta cualquiera (y desde 2026-08-01 explicitamente desde OTRA carpeta, por ERR-106),
# asi que no se puede confiar en que el directorio del script este en sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nv_web_extras  # noqa: E402

RAIZ = ""
TOKEN = ""
HISTORIAL = ""
# Un turno a la vez. Dos instancias de mentis-chat.sh en paralelo escribirian el mismo historial
# y se pisarian; ademas cada turno puede usar el navegador o el puente MCP, que son unicos.
TURNO = threading.Lock()
TIMEOUT_TURNO_S = 300

# --- TURNOS EN VIVO (2026-07-30) -------------------------------------------------------------
# Antes el turno se corria de una y se contestaba al final. Desde el telefono eso son hasta cinco
# minutos mirando "pensando..." sin saber si esta vivo, y sin forma de cortarlo. Ahora el turno
# arranca en un hilo, sus pasos se van juntando a medida que salen, y la pagina los pide con
# "long polling" (pide y el servidor le retiene la respuesta hasta que haya novedad o pasen unos
# segundos). Se eligio long polling y no SSE a proposito: SSE necesita mantener una respuesta
# abierta sin Content-Length, que con BaseHTTPRequestHandler y HTTP/1.1 es justo donde aparecen
# los cuelgues; esto es una peticion normal que termina siempre.
TURNOS = {}
TURNO_SEQ = 0
ESTADO = threading.Lock()   # protege TURNOS y TURNO_SEQ
# La misma linea que lee la app para su panel de progreso (renderer.js: TASK_LOG_RE).
PASO_RE = re.compile(r"^\[nv-agent\] iter \d+: (.+)$")
# Prefijo de la carpeta de builds de Three.js (ver _servir_estatico).
BUILD_THREE = "/estatico/node_modules/three/build/"

# La pagina NO inventa un estilo propio: usa los mismos valores que app/renderer/style.css.
# Esquinas de 2px (no redondeadas), las respuestas de Mentis en SERIF y las del usuario en sans.
#
# LA ADVERTENCIA DE ABAJO SE INCUMPLIO SOLA (2026-08-20). Este comentario decia, desde el
# principio: 'si alguna vez cambia la paleta de la app, hay que cambiarla aca tambien: son el
# mismo Mentis'. La paleta de la app cambio el 2026-08-10 con la identidad terracota y esto se
# quedo con la vieja -- naranja #ff6600 sobre negro #050507 -- durante diez dias. O sea que la
# pagina del celular y la app eran dos productos distintos a la vista.
#
# tests/test-web.sh lo venia diciendo en cada corrida (seis FAIL, uno por color). La leccion no
# es que faltara el aviso: es que un aviso escrito en un comentario depende de que alguien lo
# lea el dia exacto en que toca otro archivo. El test si lo agarro; lo que faltaba era mirarlo.
# EL PREFIJO r NO ES OPCIONAL Y ROMPIA LA PAGINA ENTERA (2026-08-06).
#
# Adentro de este bloque hay JavaScript, y el JavaScript tiene sus propias secuencias de escape.
# Sin la r, Python se las come ANTES de que el navegador las vea: un '\n' escrito para JS llegaba
# convertido en un salto de linea de verdad, en el medio de una cadena entre comillas simples.
# JavaScript no permite saltos literales dentro de '...' -- eso es un SyntaxError.
#
# Y un SyntaxError no rompe una funcion: impide que se ejecute EL SCRIPT ENTERO. La pagina cargaba,
# el HTML estaba completo y el CSS pintaba, pero nada se inicializaba: en el celular se veian el
# buscador y las dos pestanias de arriba, y abajo negro. Parecia un problema de red o del telefono.
# Eran dos lineas de JavaScript (retomar() y la de la foto) con un \n que nunca fue para Python.
#
# Con la r, todo lo de aca adentro llega al navegador tal cual esta escrito. El unico \n de este
# archivo que SI es para Python esta en la linea ~819, fuera de este bloque.
PAGINA = r"""<!doctype html>
<html lang="es"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#141413">
<title>Mentis</title>
<style>
  :root {
    color-scheme: dark;
    --fondo: #141413;
    --principal: #1f1e1d;
    --secundario: #2a2927;
    --texto: #faf9f5;
    --texto-dim: #b1ada1;
    --acento: #d97757;
    --acento-soft: rgba(217, 119, 87, 0.16);
    --peligro: #ff453a;
    --border: #33322f;
    --bubble-usuario: #232220;
    /* El redondeo pasa de 2px a 10px (2026-08-22). Tiene que ser EL MISMO cambio que en
       app/renderer/style.css, por la misma razon que la tipografia y la paleta: la pagina del
       celular y la app son la misma cosa vista de dos lados, y una esquina viva en el telefono
       contra una redondeada en la computadora se nota al instante. */
    --radius: 10px;
    --radius-chico: 6px;
    --radius-pildora: 999px;
    /* Courier tambien aca (2026-08-07). Tiene que ser el MISMO cambio que en
       app/renderer/style.css: la pagina del celular y la app son la misma cosa vista de dos
       lados, y si una queda con Courier y la otra no, se nota al instante. Ver el comentario
       largo en style.css para el por que y para el aviso sobre legibilidad. */
    --font-sans: "Courier New", Courier, monospace;
    --font-serif: "Courier New", Courier, monospace;
    --font-mono: "Courier New", Courier, monospace;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  * { scrollbar-color: var(--border) transparent; scrollbar-width: thin; }
  *::-webkit-scrollbar { width: 10px; }
  *::-webkit-scrollbar-track { background: transparent; }
  *::-webkit-scrollbar-thumb { background: var(--border); border-radius: 999px;
                               border: 2px solid transparent; background-clip: padding-box; }
  body { margin: 0; background: var(--fondo); color: var(--texto);
         font-family: var(--font-sans); display: flex; flex-direction: column; height: 100dvh; }

  /* Barra de titulo: la misma de la app -- negra, 34px, el nombre en versalitas espaciadas. */
  #barra-titulo {
    height: 34px; flex: 0 0 auto; display: flex; align-items: center; gap: 10px;
    background: #000; border-bottom: 1px solid var(--border); padding: 0 12px; user-select: none;
    padding-top: env(safe-area-inset-top);
  }
  #barra-titulo-nombre { font-size: 12px; letter-spacing: 0.18em; color: var(--texto-dim);
                         text-transform: uppercase; }
  #estado-conexion { margin-left: auto; font-size: 10px; letter-spacing: 0.14em;
                     text-transform: uppercase; color: var(--texto-dim); }
  #estado-conexion.mal { color: var(--peligro); }

  /* Encabezado: wordmark y modo, igual que #main-header en la app. */
  #cabecera { flex: 0 0 auto; display: flex; align-items: center; gap: 10px; padding: 8px 12px; }
  #wordmark { font-family: var(--font-serif); font-size: 13px; font-weight: 700;
              letter-spacing: 0.18em; color: var(--acento); }
  #modo { margin-left: auto; font-size: 11px; color: var(--acento);
          background: var(--acento-soft); border: 1px solid var(--acento);
          border-radius: var(--radius); padding: 3px 8px; font-weight: 600; }

  /* EL CUERPO DIGITAL COMO MOSTRADOR DE ESTADO (pedido del usuario). Igual que en la app, no vive en
     un rincon decorativo: esta en la zona del chat y es lo que te dice de un vistazo si Mentis
     esta esperando, trabajando o hablando. Debajo, el nombre del estado en palabras -- en un
     telefono al que le mirás de reojo, el color solo no alcanza. */
  #zona-cuerpo { flex: 0 0 auto; display: flex; flex-direction: column; align-items: center;
                 gap: 4px; padding: 6px 0 10px; }
  #cuerpo { width: 110px; height: 110px; display: block; }
  #cuerpo-estado { font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase;
                   color: var(--texto-dim); min-height: 13px; }
  #cuerpo-estado.trabajando { color: var(--acento); }
  #cuerpo-estado.mal { color: var(--peligro); }

  #messages { flex: 1; overflow-y: auto; padding: 12px 14px 20px; }
.bubble { max-width: 88%; padding: 10px 14px; border-radius: var(--radius); margin-bottom: 10px;
            white-space: pre-wrap; font-size: 14px; word-wrap: break-word; overflow-wrap: anywhere;
            animation: mentis-bubble-in 0.2s ease-out; }
.bubble.usuario { background: var(--bubble-usuario); color: var(--texto);
                 font-family: var(--font-sans); margin-left: auto; }
.bubble.mentis { background: var(--secundario); border: 1px solid var(--border);
                   color: var(--texto); font-family: var(--font-serif); font-size: 15px;
                   line-height: 1.7; margin-right: auto; }
.bubble.mentis.error { border-color: var(--peligro); color: #ff8a80; font-family: var(--font-sans); }
  /* Formato de las respuestas. Mismas reglas que en la app, adaptadas al celular: los bloques de
     codigo scrollean solos (overflow-x) porque en una pantalla angosta una linea larga estiraria
     la pagina entera y se perderia el ancho de todo el chat. */
.bubble.mentis strong { font-weight: 650; color: #fff; }
.bubble.mentis em { font-style: italic; }
.bubble.mentis h3,.bubble.mentis h4,.bubble.mentis h5 {
    margin: 10px 0 5px; font-family: var(--font-sans); font-weight: 600; line-height: 1.3; }
.bubble.mentis h3 { font-size: 1.1em; }
.bubble.mentis h4 { font-size: 1.04em; }
.bubble.mentis h5 { font-size: 1em; color: var(--texto-dim); }
.bubble.mentis ul,.bubble.mentis ol { margin: 5px 0; padding-left: 20px; }
.bubble.mentis li { margin: 3px 0; }
.bubble.mentis code { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.88em;
                        background: rgba(255,255,255,0.08); padding: 1px 5px; border-radius: 4px; }
.bubble.mentis pre.bloque-codigo { background: rgba(0,0,0,0.35); border: 1px solid var(--border);
                                     border-radius: 8px; padding: 9px 11px; margin: 7px 0;
                                     overflow-x: auto; white-space: pre; font-size: 0.85em;
                                     line-height: 1.5; -webkit-overflow-scrolling: touch; }
.bubble.mentis pre.bloque-codigo code { background: none; padding: 0; font-size: 1em; }
  @keyframes mentis-bubble-in {
    from { opacity: 0; transform: translateY(6px) scale(0.96); }
    to { opacity: 1; transform: translateY(0) scale(1); }
  }

  #composer { flex: 0 0 auto; padding: 12px; border-top: 1px solid var(--border);
              padding-bottom: calc(12px + env(safe-area-inset-bottom)); display: flex;
              align-items: flex-end; gap: 10px; background: var(--fondo); }
  #message-input {
    flex: 1 1 auto; min-width: 0; max-height: 38vh; background: var(--secundario);
    color: var(--texto); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 10px; resize: none; font-family: inherit; font-size: 15px; line-height: 1.4;
  }
  #message-input:focus { outline: 2px solid var(--acento); outline-offset: 1px; }
  #btn-send { background: var(--acento); color: var(--fondo); border: none;
              border-radius: var(--radius); padding: 0 18px; height: 44px; font: inherit;
              font-weight: 600; cursor: pointer; flex: 0 0 auto; }
  #btn-send:disabled { opacity: 0.4; }
  /* Detener: rojo y redondo, el mismo lenguaje que usa la app para "esto corta algo en curso". */
  #btn-stop { width: 44px; height: 44px; border-radius: 50%; flex: 0 0 auto; background: var(--peligro);
              color: var(--fondo); border: none; font-size: 16px; cursor: pointer; display: none; }
  #btn-stop.visible { display: block; }
  /* Frenar todo: siempre visible pero discreto. No es para el uso normal -- es el botón de "algo
     quedó dando vueltas y quiero que pare", que en la app vive arriba a la derecha. */
  #btn-frenar { width: 44px; height: 44px; border-radius: 50%; flex: 0 0 auto; background: transparent;
                color: var(--peligro); border: 1px solid var(--peligro); font-size: 15px; cursor: pointer; }
  #btn-frenar:active { background: var(--peligro); color: var(--fondo); }
.puntos::after { content: ''; animation: puntos 1.2s steps(4, end) infinite; }
  @keyframes puntos { 0%{content:''} 25%{content:'.'} 50%{content:'..'} 75%{content:'...'} }

  /* Pasos en vivo: mismos valores que.live-step en la app -- barra de acento a la izquierda,
     roja si fue un rechazo o un fallo, sin emoji (el estado se distingue por color). */
.live-steps { display: flex; flex-direction: column; gap: 4px; margin-bottom: 6px; }
.live-step { font-size: 13px; color: var(--texto-dim); font-family: var(--font-sans);
               padding-left: 10px; border-left: 2px solid var(--acento-soft);
               animation: mentis-bubble-in 0.2s ease-out; word-wrap: break-word;
               overflow-wrap: anywhere; }
.live-step-error { border-left-color: var(--peligro); color: #f0a8a4; }
  /* Los pasos de un turno ya terminado se pliegan, como el <details> "N pasos" de la app. */
.steps-summary { margin-bottom: 6px; font-family: var(--font-sans); font-size: 12px; }
.steps-summary summary { cursor: pointer; color: var(--texto-dim); list-style: none;
                           display: inline-flex; align-items: center; gap: 4px; }
.steps-summary summary::-webkit-details-marker { display: none; }
.steps-summary summary::before { content: '▸'; }
.steps-summary[open] summary::before { content: '▾'; }
  /* --- Panel de la Fase 3 (conversaciones, buscador, estadisticas) --- */
  #btn-panel { background: none; border: 0; color: var(--texto-dim); font-size: 20px;
               padding: 4px 10px; cursor: pointer; }
  #btn-panel:active { color: var(--texto); }
  #panel { position: fixed; inset: 0; z-index: 50; background: var(--fondo);
           display: flex; flex-direction: column; padding: env(safe-area-inset-top) 0 0 0; }
  /* ESTA LINEA ES LA QUE HACE QUE EL PANEL SE PUEDA CERRAR (2026-08-06).
     El panel se abre y se cierra con el atributo `hidden` (ver abrirPanel/cerrarPanel), y el HTML
     lo declara <div id="panel" hidden>. Pero el `display:none` que el navegador le da a [hidden]
     es una regla del user-agent, y CUALQUIER regla de autor que declare `display` le gana: el
     `display:flex` de arriba lo estaba pisando. Resultado: el panel quedaba fijo, inset:0, encima
     de todo, imposible de cerrar -- ni con el boton ni llamando a cerrarPanel() a mano.
     En el celular eso se veia como una pantalla con el buscador y las dos pestanias arriba y todo
     negro abajo: el chat estaba ahi, completo y visible, tapado por un panel de pantalla completa. */
  #panel[hidden] { display: none; }
.panel-fila { display: flex; gap: 8px; padding: 12px; align-items: center; }
  #panel-buscar { flex: 1; background: var(--secundario); border: 1px solid #2a2a32;
                  border-radius: 10px; color: var(--texto); padding: 11px 13px; font-size: 16px; }
  #panel-cerrar { background: none; border: 0; color: var(--texto-dim); font-size: 20px;
                  padding: 6px 10px; cursor: pointer; }
  #panel-tabs { display: flex; gap: 6px; padding: 0 12px 10px; }
.tab { flex: 1; background: var(--secundario); border: 1px solid #2a2a32; color: var(--texto-dim);
         padding: 9px; border-radius: 9px; font-size: 14px; cursor: pointer; }
.tab-activa { color: var(--texto); border-color: #3a3a44; background: var(--principal); }
  #panel-cuerpo { flex: 1; overflow-y: auto; padding: 0 12px 20px; -webkit-overflow-scrolling: touch; }
.conv { background: var(--principal); border: 1px solid #23232a; border-radius: 11px;
          padding: 12px; margin-bottom: 9px; cursor: pointer; }
.conv:active { border-color: #3a3a44; }
.conv-meta { color: var(--texto-dim); font-size: 12px; margin-bottom: 5px;
               display: flex; justify-content: space-between; gap: 8px; }
.conv-vista { font-size: 14px; line-height: 1.45; }
.res-frag { font-size: 13px; line-height: 1.5; color: var(--texto); }
.res-frag b { color: #fff; }
.stat { display: flex; justify-content: space-between; padding: 11px 2px;
          border-bottom: 1px solid #1e1e25; font-size: 14px; }
.stat span:last-child { color: var(--texto-dim); }
.panel-vacio { color: var(--texto-dim); text-align: center; padding: 32px 12px; font-size: 14px; line-height: 1.6; }
  /* El "+" va mas grande y con line-height fijo: un signo mas al tamaño del emoji que reemplazo se
     veria diminuto al lado del boton Enviar, y en el celular hay que poder pegarle con el pulgar. */
  #btn-foto { background: none; border: 0; font-size: 30px; line-height: 1; padding: 0 10px;
              cursor: pointer; opacity:.75; color: var(--texto-dim); font-weight: 300; }
  #btn-foto:active { opacity: 1; color: var(--texto); }
</style>
<!-- App instalable sin pasar por ninguna tienda (2026-08-22). Ni el manifest ni el registro del
     service worker llevan el token: cuando esta pagina se sirve, el servidor deja una cookie
     HttpOnly con el, y todo lo de abajo se autentica con eso. La primera version SI ponia el
     token en estas URLs y estaba mal -- habria roto la regla, con test propio desde antes, de que
     el token no viaja escrito en el cuerpo de la pagina. De paso queda mejor de lo que estaba: la
     app instalada abre en "/" a secas, sin la llave colgando de la direccion. -->
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/estatico/pwa/icono-192.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Mentis">
<meta name="mobile-web-app-capable" content="yes">
</head><body>
<div id="barra-titulo">
  <div id="barra-titulo-nombre" data-nombre-ia>Mentis</div>
  <div id="estado-conexion">conectado</div>
</div>
<div id="cabecera">
  <div id="wordmark" data-nombre-ia>MENTIS</div>
  <div id="modo">remoto</div>
  <button id="btn-panel" type="button" title="Conversaciones, buscador y estadisticas" aria-label="Conversaciones">&#9776;</button>
</div>
<!-- Panel de la Fase 3: conversaciones, buscador, resumen y estadisticas. Arranca oculto para no
     robarle pantalla al chat, que es a lo que se entra el 95% de las veces. -->
<div id="panel" hidden>
  <div class="panel-fila">
    <input id="panel-buscar" type="search" placeholder="Buscar en todas las conversaciones..." autocomplete="off">
    <button id="panel-cerrar" type="button" aria-label="Cerrar">&#10005;</button>
  </div>
  <div id="panel-tabs">
    <button class="tab tab-activa" data-tab="convs" type="button">Conversaciones</button>
    <button class="tab" data-tab="stats" type="button">Estadisticas</button>
  </div>
  <div id="panel-cuerpo"></div>
</div>
<div id="zona-cuerpo">
  <div id="cuerpo-estado">en espera</div>
</div>
<div id="messages"></div>
<form id="composer">
  <textarea id="message-input" rows="1" placeholder="Escribí o dictá..." autocomplete="off"></textarea>
  <!-- La foto usa capture="environment": en el celular abre la camara de atras directamente en
       vez de mandar al explorador de archivos, que es lo que uno quiere el 90% de las veces. -->
  <input id="foto-input" type="file" accept="image/*" capture="environment" hidden>
  <!-- Un "+" y no el emoji de camara (pedido del usuario, 2026-08-06): el emoji se ve distinto en cada
       sistema, canta "esto es del celular" y ademas miente un poco -- el boton no solo saca fotos,
       tambien adjunta una imagen que ya tengas. El signo mas dice "agregar algo" y se ve igual en
       todos lados porque es un caracter, no un emoji. -->
  <button id="btn-foto" type="button" title="Sacar una foto o adjuntar una imagen" aria-label="Adjuntar">+</button>
  <button id="btn-stop" type="button" title="Detener este turno" aria-label="Detener">■</button>
  <button id="btn-frenar" type="button" title="Frenar TODO lo que Mentis esté haciendo" aria-label="Frenar todo">✖</button>
  <button id="btn-send" type="submit">Enviar</button>
</form>

<!-- ACA IBA EL CUERPO DIGITAL, y ya no va (2026-08-20). el usuario lo saco de la app hace tiempo por
     decision propia; lo que quedaba era el import de un modulo que NO EXISTE en el repo. No
     rompia nada -- el catch escondia el canvas -- pero pedia un archivo inexistente en cada
     carga y el test lo reportaba como un 404 de permisos, mandando a buscar un problema que no
     era. Se saca el import, el canvas y la entrada de la lista blanca. El texto de estado
     (#cuerpo-estado) SI se queda: no dependia del modulo 3D y es lo que dice si Mentis esta
     trabajando. -->
<script>
const T = new URLSearchParams(location.search).get('t') || '';

// UNA CONVERSACION POR SESION DEL NAVEGADOR (pedido del usuario, 2026-07-30).
// sessionStorage y no localStorage: sessionStorage sobrevive a recargar la pagina -- si no,
// recargar sin querer te borraria la charla a la mitad -- pero se limpia solo cuando cerras el
// navegador, que es exactamente el corte que el usuario pidio. Del lado del servidor, este id elige un
// archivo de historial propio, asi que lo que ves en pantalla es LO MISMO que lee el modelo.
const SESION = (() => {
  let s = sessionStorage.getItem('mentis-sesion');
  if (!s) {
    s = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()).replace(/[^A-Za-z0-9-]/g, '').slice(0, 32);
    sessionStorage.setItem('mentis-sesion', s);
  }
  return s;
})();
const chat = document.getElementById('messages'), campo = document.getElementById('message-input'),
      boton = document.getElementById('btn-send'), form = document.getElementById('composer'),
      conexion = document.getElementById('estado-conexion'), botonStop = document.getElementById('btn-stop'),
      cuerpoEstado = document.getElementById('cuerpo-estado');

let turnoActual = null;

// El cuerpo es el mostrador de estado: mismo juego de estados que la app (STANDBY / PROCESSING /
// SPEAKING / ALERT), y debajo el nombre en palabras.
const NOMBRE_ESTADO = { STANDBY: 'en espera', PROCESSING: 'trabajando', SPEAKING: 'contestando',
                        LISTENING: 'escuchando', ALERT: 'algo falló' };
function estadoCuerpo(e) {
  // (el cuerpo digital 3D ya no esta; el estado se muestra solo como texto)
  cuerpoEstado.textContent = NOMBRE_ESTADO[e] || '';
  cuerpoEstado.className = e === 'PROCESSING' ? 'trabajando' : (e === 'ALERT' ? 'mal' : '');
}
function sinapsis() { /* era el destello del cuerpo digital 3D, que ya no esta */ }
function conexionMal(txt) { conexion.textContent = txt; conexion.classList.add('mal'); }
function conexionBien() { conexion.textContent = 'conectado'; conexion.classList.remove('mal'); }

// El formateador se carga del MISMO archivo que usa la app (ver _servir_estatico). Hasta que
// llegue -- es un import dinamico -- las burbujas se pintan como texto plano: mostrar asteriscos
// crudos un instante es mejor que no mostrar el mensaje.
let FORMATO = null;
import('/estatico/renderer/formato.js').then((m) => { FORMATO = m; }).catch(() => {});

// La paleta y el nombre elegidos en la app (2026-08-06). Se piden apenas carga la pagina para que
// el telefono se vea igual que la computadora. Si algo falla, queda el naranja de siempre: un tema
// que no llega es un detalle, una pantalla en blanco seria un problema.
(async () => {
  try {
    const [temas, r] = await Promise.all([
      import('/estatico/renderer/temas.js'),
      fetch('/api/apariencia' + location.search).then((x) => x.json()),
    ]);
    const a = (r && r.apariencia) || {};
    if (a.paleta) temas.aplicarTema(a.paleta);
    if (a.nombre) {
      document.title = a.nombre;
      document.querySelectorAll('[data-nombre-ia]').forEach((el) => { el.textContent = a.nombre; });
    }
  } catch (e) { /* se queda con lo del CSS */ }
})();

// Lo del usuario va SIEMPRE como texto plano: es lo que el escribio y tiene que verse tal cual. El
// formato se aplica solo a las respuestas de Mentis, que es donde vienen los asteriscos.
function pintar(el, texto, quien) {
  if (quien === 'mentis' && FORMATO && FORMATO.formatearMensaje) {
    el.innerHTML = FORMATO.formatearMensaje(texto);
  } else {
    el.textContent = texto;
  }
}

function burbuja(quien, texto, error) {
  const d = document.createElement('div');
  d.className = 'bubble ' + quien + (error ? ' error' : '');
  pintar(d, texto, error ? 'usuario' : quien);
  chat.appendChild(d);
  chat.scrollTop = chat.scrollHeight;
  return d;
}
campo.addEventListener('input', () => {
  campo.style.height = 'auto';
  campo.style.height = Math.min(campo.scrollHeight, window.innerHeight * 0.38) + 'px';
});

// Traduce una linea cruda de accion a una frase legible. Es la MISMA funcion que usa la app
// (renderer.js: humanizeStep) -- copiada tal cual para que los pasos se lean igual en los dos
// lados. Si algun dia cambia alla, hay que cambiarla aca: el test compara las dos.
function humanizeStep(action) {
  if (/RECHAZADO|FALLO|BLOQUEADO|no devolvió JSON/.test(action)) return { text: action, isError: true };
  const word = action.split(' ')[0];
  const rest = action.slice(word.length).trim();
  let text;
  switch (word) {
    case 'read': text = rest ? `Leyendo ${rest}` : 'Leyendo un archivo'; break;
    case 'write': text = rest ? `Escribiendo ${rest}` : 'Escribiendo un archivo'; break;
    case 'search': text = rest ? `Buscando ${rest}` : 'Buscando en el proyecto'; break;
    case 'run': text = 'Ejecutando código en un sandbox aislado'; break;
    case 'exec': text = 'Ejecutando un comando'; break;
    case 'browse': text = `Navegando la web (${rest || '...'})`; break;
    case 'mcp': text = rest.startsWith('list') ? 'Consultando qué herramientas externas hay disponibles' : `Usando una herramienta externa (${rest.replace(/^call /, '')})`; break;
    case 'gen': text = `Generando contenido (${rest})`; break;
    case 'screen': text = 'Mirando la pantalla'; break;
    case 'control': text = `Controlando mouse/teclado (${rest})`; break;
    case 'delegate': text = `Consultando a otro cerebro (${rest.replace('-> ', '')})`; break;
    case 'parallel': text = `Consultando varios cerebros a la vez (${rest})`; break;
    case 'recordar': text = 'Buscando en lo que hablamos antes'; break;
    case 'done': text = 'Preparando la respuesta'; break;
    default: text = action;
  }
  return { text, isError: false };
}

function agregarPaso(contenedor, accion) {
  const { text, isError } = humanizeStep(accion);
  const fila = document.createElement('div');
  fila.className = 'live-step' + (isError ? ' live-step-error' : '');
  fila.textContent = text;
  contenedor.appendChild(fila);
  chat.scrollTop = chat.scrollHeight;
  sinapsis();
}

// Los pasos de un turno terminado se pliegan en "N pasos", como en la app.
function plegarPasos(contenedor, cuantos) {
  if (!cuantos) { contenedor.remove(); return; }
  const det = document.createElement('details');
  det.className = 'steps-summary';
  const sum = document.createElement('summary');
  sum.textContent = cuantos + (cuantos === 1 ? ' paso' : ' pasos');
  det.appendChild(sum);
  contenedor.parentNode.insertBefore(det, contenedor);
  det.appendChild(contenedor);
}

async function cargarHistorial() {
  try {
    const r = await fetch('/api/historial?t=' + encodeURIComponent(T) + '&sesion=' + encodeURIComponent(SESION));
    if (!r.ok) { conexionMal('token invalido'); return; }
    const d = await r.json();
    chat.innerHTML = '';
    (d.mensajes || []).forEach((m) => burbuja(m.role === 'usuario' ? 'usuario' : 'mentis', m.text));
    conexionBien();
  } catch (e) { conexionMal('sin conexion'); }
}

function enCurso(si) {
  boton.disabled = si; campo.disabled = si;
  botonStop.classList.toggle('visible', si);
}

document.getElementById('btn-frenar').addEventListener('click', async () => {
  try {
    const r = await fetch('/api/frenar?t=' + encodeURIComponent(T), { method: 'POST' });
    const d = await r.json();
    burbuja('mentis', d.frenados ? ('Frené ' + d.frenados + ' cosa(s) que estaban corriendo.') : 'No había nada corriendo.');
  } catch (e) { burbuja('mentis', 'No pude frenar: se cortó la conexión.', true); }
  estadoCuerpo('STANDBY');
  turnoActual = null;
  enCurso(false);
});

botonStop.addEventListener('click', async () => {
  if (turnoActual === null) return;
  botonStop.disabled = true;
  // Se avisa ANTES de que el servidor confirme: matar el árbol de procesos y cerrar el turno
  // lleva unos segundos, y un botón que no acusa recibo se siente roto.
  const pendiente = document.querySelector('.bubble.mentis.puntos');
  if (pendiente) { pendiente.classList.remove('puntos'); pendiente.textContent = 'Cortando'; pendiente.classList.add('puntos'); }
  try {
    await fetch('/api/detener?t=' + encodeURIComponent(T), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: turnoActual })
    });
  } catch (e) { /* si no llegó, el turno termina igual por su cuenta */ }
  botonStop.disabled = false;
});

// Sigue un turno hasta que termina. Cada vuelta pide "lo nuevo desde el paso N": el servidor
// retiene la respuesta hasta que haya algo o pasen ~20 s, asi que esto NO es un sondeo que
// machaca al servidor -- es una espera que se corta sola apenas hay novedad.
async function seguirTurno(id, contenedorPasos, burbujaRespuesta) {
  let desde = 0, vivo = true, fallosSeguidos = 0;
  while (vivo) {
    let d;
    try {
      const r = await fetch('/api/turno?t=' + encodeURIComponent(T) + '&id=' + id + '&desde=' + desde);
      d = await r.json();
      conexionBien();
      fallosSeguidos = 0;
    } catch (e) {
      // Un corte de WiFi no puede matar el turno: la computadora sigue trabajando igual. Se
      // reintenta y se avisa arriba, sin tocar lo que ya se mostro.
      conexionMal('reintentando');
      if (++fallosSeguidos > 30) { vivo = false; break; }
      await new Promise((r2) => setTimeout(r2, 2000));
      continue;
    }
    if (!d.ok) { vivo = false; break; }
    (d.pasos || []).forEach((p) => agregarPaso(contenedorPasos, p));
    desde = d.total;
    if (d.terminado) {
      burbujaRespuesta.classList.remove('puntos');
      if (d.respuesta) {
        pintar(burbujaRespuesta, d.respuesta, 'mentis');
        estadoCuerpo('SPEAKING');
        setTimeout(() => estadoCuerpo('STANDBY'), 1800);
      } else if (d.error === 'cortado') {
        burbujaRespuesta.textContent = 'Lo corté acá.';
        burbujaRespuesta.classList.add('error');
        estadoCuerpo('STANDBY');
      } else {
        burbujaRespuesta.textContent = 'No pude contestar: ' + (d.error || 'error desconocido');
        burbujaRespuesta.classList.add('error');
        estadoCuerpo('ALERT');
      }
      plegarPasos(contenedorPasos, desde);
      vivo = false;
    }
  }
  turnoActual = null;
  enCurso(false);
  campo.focus();
}

form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const texto = campo.value.trim();
  if (!texto) return;
  campo.value = ''; campo.style.height = 'auto';
  burbuja('usuario', texto);
  enCurso(true);
  estadoCuerpo('PROCESSING');

  const pasos = document.createElement('div');
  pasos.className = 'live-steps';
  chat.appendChild(pasos);
  const pensando = burbuja('mentis', 'pensando');
  pensando.classList.add('puntos');

  try {
    const r = await fetch('/api/mensaje?t=' + encodeURIComponent(T), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ texto, sesion: SESION })
    });
    const d = await r.json();
    if (!d.ok) {
      pensando.classList.remove('puntos');
      pensando.textContent = d.error || 'no pude arrancar el turno';
      pensando.classList.add('error');
      estadoCuerpo('ALERT');
      pasos.remove();
      enCurso(false);
      return;
    }
    turnoActual = d.id;
    seguirTurno(d.id, pasos, pensando);
  } catch (e) {
    pensando.classList.remove('puntos');
    pensando.textContent = 'Se cortó la conexión con la computadora.';
    pensando.classList.add('error');
    conexionMal('sin conexion');
    estadoCuerpo('ALERT');
    pasos.remove();
    enCurso(false);
  }
});

/* ============ Fase 3: conversaciones, buscador, resumen, estadisticas y foto ============
   Todo esto es de solo lectura salvo la foto, que guarda el archivo pero NO dispara un turno.
   La pagina del celular corre en modo remoto y no puede escribir, ejecutar, ver la pantalla ni
   usar la camara de la computadora; el panel no le agrega ninguna de esas cosas por la ventana. */
const panel = document.getElementById('panel');
const panelCuerpo = document.getElementById('panel-cuerpo');
const panelBuscar = document.getElementById('panel-buscar');
let tabActual = 'convs';

function fechaCorta(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000), hoy = new Date();
  const mismoDia = d.toDateString() === hoy.toDateString();
  if (mismoDia) return d.toTimeString().slice(0, 5);
  return d.getDate() + '/' + (d.getMonth() + 1);
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

async function pedir(ruta) {
  const r = await fetch(ruta + (ruta.includes('?') ? '&' : '?') + 't=' + encodeURIComponent(T));
  if (!r.ok) return null;
  return await r.json();
}

async function verConversaciones() {
  panelCuerpo.innerHTML = '<div class="panel-vacio">cargando...</div>';
  const d = await pedir('/api/conversaciones');
  if (!d || !d.conversaciones.length) {
    panelCuerpo.innerHTML = '<div class="panel-vacio">Todavia no hay conversaciones guardadas.</div>';
    return;
  }
  panelCuerpo.innerHTML = d.conversaciones.map(c =>
    '<div class="conv" data-id="' + esc(c.id) + '">' +
      '<div class="conv-meta"><span>' + esc(c.origen) + ' &middot; ' + c.mensajes + ' mensajes</span>' +
      '<span>' + fechaCorta(c.modificada) + '</span></div>' +
      '<div class="conv-vista">' + esc(c.vista) + '</div>' +
    '</div>').join('');
  panelCuerpo.querySelectorAll('.conv').forEach(el => {
    el.addEventListener('click', () => retomar(el.dataset.id));
  });
}

/* RETOMAR: trae los ultimos intercambios y los deja escritos en el cuadro de texto como contexto.
   No los manda solo. Que el ultimo paso sea del usuario es a proposito: retomar una conversacion vieja
   sin mirar que se esta arrastrando es como se terminan mandando cosas sin querer. */
async function retomar(id) {
  const d = await pedir('/api/resumen?c=' + encodeURIComponent(id));
  if (!d || !d.resumen) return;
  const r = d.resumen;
  campo.value = 'Retomemos esto que veniamos hablando:\n\n' + r.contexto + '\n\n';
  cerrarPanel();
  campo.focus();
  campo.dispatchEvent(new Event("input"));
}

async function verEstadisticas() {
  panelCuerpo.innerHTML = '<div class="panel-vacio">cargando...</div>';
  const d = await pedir('/api/estadisticas');
  if (!d) { panelCuerpo.innerHTML = '<div class="panel-vacio">no se pudieron leer</div>'; return; }
  const e = d.estadisticas;
  const filas = [
    ['Conversaciones', e.conversaciones],
    ['Mensajes en total', e.mensajes],
    ['Conversaciones esta semana', e.conversaciones_ultima_semana],
    ['Mensajes esta semana', e.mensajes_ultima_semana],
    ['Promedio por conversacion', e.promedio_mensajes],
    ['Desde el celular', (e.por_origen && e.por_origen.celular) || 0],
    ['Desde la computadora', (e.por_origen && e.por_origen.computadora) || 0],
  ];
  panelCuerpo.innerHTML = filas.map(f =>
    '<div class="stat"><span>' + f[0] + '</span><span>' + f[1] + '</span></div>').join('');
}

let temporizadorBusqueda = null;
panelBuscar.addEventListener('input', () => {
  clearTimeout(temporizadorBusqueda);
  /* Se espera a que deje de escribir: sin esto, cada tecla dispara una lectura de TODAS las
     conversaciones del disco. */
  temporizadorBusqueda = setTimeout(async () => {
    const q = panelBuscar.value.trim();
    if (!q) { tabActual === 'stats' ? verEstadisticas() : verConversaciones(); return; }
    panelCuerpo.innerHTML = '<div class="panel-vacio">buscando...</div>';
    const d = await pedir('/api/buscar?q=' + encodeURIComponent(q));
    if (!d || !d.resultados.length) {
      panelCuerpo.innerHTML = '<div class="panel-vacio">Nada con &laquo;' + esc(q) + '&raquo;.</div>';
      return;
    }
    panelCuerpo.innerHTML = d.resultados.map(r =>
      '<div class="conv" data-id="' + esc(r.conversacion) + '">' +
        '<div class="conv-meta"><span>' + (r.role === 'usuario' ? 'vos' : 'Mentis') +
        ' &middot; ' + esc(r.origen) + '</span></div>' +
        '<div class="res-frag">' + esc(r.fragmento) + '</div>' +
      '</div>').join('');
    panelCuerpo.querySelectorAll('.conv').forEach(el => {
      el.addEventListener('click', () => retomar(el.dataset.id));
    });
  }, 280);
});

function abrirPanel()  { panel.hidden = false; verConversaciones(); }
function cerrarPanel() { panel.hidden = true; panelBuscar.value = ''; }
document.getElementById('btn-panel').addEventListener('click', abrirPanel);
document.getElementById('panel-cerrar').addEventListener('click', cerrarPanel);
document.querySelectorAll('.tab').forEach(t => {
  t.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(x => x.classList.remove('tab-activa'));
    t.classList.add('tab-activa');
    tabActual = t.dataset.tab;
    panelBuscar.value = '';
    tabActual === 'stats' ? verEstadisticas() : verConversaciones();
  });
});

/* --- FOTO --- */
const fotoInput = document.getElementById('foto-input');
document.getElementById('btn-foto').addEventListener('click', () => fotoInput.click());
fotoInput.addEventListener('change', async () => {
  const f = fotoInput.files && fotoInput.files[0];
  if (!f) return;
  const lector = new FileReader();
  lector.onload = async () => {
    const r = await fetch('/api/foto?t=' + encodeURIComponent(T), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ imagen: lector.result, sesion: SESION })
    });
    const d = await r.json().catch(() => null);
    if (!d || !d.ok) {
      alert('No se pudo adjuntar la foto' + (d && d.error ? ': ' + d.error : '.'));
      return;
    }
    /* Se deja la ruta escrita para que el usuario agregue su pregunta. Mandarlo solo obligaria a
       adivinar que queria preguntar sobre la foto. */
    campo.value = (campo.value ? campo.value + '\n' : '') + 'Mira esta foto: ' + d.ruta + '\n';
    campo.focus();
    campo.dispatchEvent(new Event("input"));
  };
  lector.readAsDataURL(f);
  fotoInput.value = '';
});

/* --- ESCUCHAR LA RESPUESTA --- */
/* Se usa la voz del PROPIO celular (speechSynthesis) y no el servidor de voz de la computadora.
   El servidor generaria un.wav de varios megas que habria que mandar por la red en cada
   respuesta; el celular ya tiene una voz local que arranca al instante y no gasta datos. */
function hablar(texto) {
  if (!('speechSynthesis' in window)) return false;
  try {
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(texto.slice(0, 1200));
    u.lang = 'es-AR';
    speechSynthesis.speak(u);
    return true;
  } catch (e) { return false; }
}

estadoCuerpo('STANDBY');
cargarHistorial();

// --- instalable como app (2026-08-22) ---------------------------------------------------------
// El service worker es lo que convierte esta pagina en una app que se instala en el telefono sin
// pasar por Google Play. Chrome solo lo permite en un contexto seguro (HTTPS o localhost), y la
// direccion de Tailscale es HTTP: por eso se pregunta antes en vez de registrar a ciegas. Sin
// esta guarda, la consola del celular se llena de un error que no significa nada y que hace
// perder el tiempo buscando un bug donde solo falta habilitar HTTPS en la tailnet.
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/sw.js', { scope: '/' })
.catch(function (e) { console.warn('no se pudo instalar el service worker:', e); });
}
</script>
</body></html>"""

# --- lo que hace falta para instalar la pagina como app -------------------------------------------
# POR QUE UNA PWA Y NO UN.APK (2026-08-22): el usuario pidio "una app verdadera sin pasar por Google Play
# ni App Store". Un.apk cumple, pero exige el SDK de Android y un JDK para compilarlo, y despues
# hay que rearmarlo en cada cambio. Una PWA se instala desde el navegador con "Agregar a pantalla de
# inicio", queda con su icono, abre en pantalla completa sin barra de direcciones, y se actualiza
# sola porque es la misma pagina. Para el que la usa es lo mismo; para el que la mantiene, no.
#
# LO QUE FALTA Y NO DEPENDE DE ESTE ARCHIVO: Chrome exige contexto seguro. La direccion de Tailscale
# es http://100.x.y.z:8765, que NO lo es. Se arregla habilitando HTTPS en la consola de Tailscale
# (una casilla, gratis) y sirviendo por `tailscale serve` -- ver `mentis-web.sh https`. Mientras
# tanto la pagina funciona igual por HTTP; lo unico que no se puede es instalarla.
MANIFEST = {
    "name": "Mentis",
    "short_name": "Mentis",
    "description": "Mentis desde el telefono, por la red privada de Tailscale.",
    "start_url": "/",
    "scope": "/",
    # 'standalone' es lo que saca la barra de direcciones: sin esto se instala igual pero se ve
    # como una pestaña, que es justo lo que el usuario no queria.
    "display": "standalone",
    "orientation": "portrait",
    "background_color": "#141413",
    "theme_color": "#141413",
    "lang": "es",
    "icons": [
        {"src": "/estatico/pwa/icono-192.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/estatico/pwa/icono-512.png", "sizes": "512x512", "type": "image/png"},
        {"src": "/estatico/pwa/icono-maskable-512.png", "sizes": "512x512",
         "type": "image/png", "purpose": "maskable"},
    ],
}

# El service worker MINIMO que Chrome acepta para declarar la app instalable: tiene que existir y
# tiene que atender 'fetch'. A proposito NO cachea las respuestas de Mentis -- una conversacion
# vieja servida desde el cache en vez de la real seria peor que un error de red, porque parece
# fresca. Solo guarda la cascara para poder decir "no hay conexion" en vez de mostrar el dinosaurio.
SERVICE_WORKER = r"""
const CACHE = 'mentis-cascara-v1';

self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // Nada de la API se cachea NUNCA: son turnos, historial y estado en vivo.
  if (url.pathname.startsWith('/api/')) return;
  if (e.request.method !== 'GET') return;

  e.respondWith(
    fetch(e.request)
.then((r) => {
        if (r && r.ok && (url.pathname === '/' || url.pathname.startsWith('/estatico/'))) {
          const copia = r.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copia)).catch(() => {});
        }
        return r;
      })
.catch(() => caches.match(e.request).then((c) => c || new Response(
        'Sin conexion con Mentis. Revisa que la computadora este prendida y Tailscale activo.',
        { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })))
  );
});
"""


def _token_ok(handler):
    q = parse_qs(urlparse(handler.path).query)
    dado = (q.get("t") or [""])[0] or handler.headers.get("X-Mentis-Token", "")
    # Y la cookie (2026-08-22). LA COOKIE NO ES UNA COMODIDAD: es lo que permite que la app
    # instalada en el telefono no tenga el token escrito en ningun lado. Sin esto, el manifest
    # tendria que llevar el token en su start_url y en el <link> del HTML -- y hay una regla
    # anterior, con test propio, de que el token NO viaja escrito en el cuerpo de la pagina.
    # Bajar esa regla para que entrara la app instalable habria sido cambiar seguridad por
    # comodidad; con la cookie se cumplen las dos cosas y ademas el token deja de estar en la URL
    # una vez que el navegador la guardo.
    if not dado:
        cookies = handler.headers.get("Cookie", "") or ""
        for parte in cookies.split(";"):
            nombre, _, valor = parte.strip().partition("=")
            if nombre == "mentis_token":
                dado = valor
                break
    return bool(TOKEN) and hmac.compare_digest(str(dado), TOKEN)


def _limpiar_conversaciones_remotas(dias=14):
    """Junta lo que dejan las sesiones del navegador (pedido del usuario, 2026-07-31).

    Cada vez que el usuario abre la pagina se crea un hilo nuevo, asi que sin esto la carpeta se llena
    sola. Se borran dos cosas y nada mas: las VACIAS (abrio el celular y no escribio) y las mas
    viejas que 'dias'. Las de hoy no se tocan aunque esten vacias -- podria estar usandolas ahora.
    Es a proposito que NO borre conversaciones de la app: esta funcion solo mira 'remoto-*'."""
    carpeta = os.path.join(RAIZ, "conversations")
    if not os.path.isdir(carpeta):
        return 0
    limite = time.time() - dias * 86400
    hoy = time.time() - 86400
    borradas = 0
    for nombre in os.listdir(carpeta):
        if not nombre.startswith("remoto-") or not nombre.endswith(".jsonl"):
            continue
        ruta = os.path.join(carpeta, nombre)
        try:
            st = os.stat(ruta)
            vacia = st.st_size == 0
            vieja = st.st_mtime < limite
            reciente = st.st_mtime > hoy
            if (vacia and not reciente) or vieja:
                os.remove(ruta)
                borradas += 1
        except Exception:
            pass
    return borradas


def _apariencia():
    """Paleta y nombre elegidos, leidos de mentis-settings.json (los escribe la app).

    Se lee en CADA pedido y no una vez al arrancar: el servidor de la pagina vive mientras vive
    Mentis, asi que si se cacheara, cambiar el tema desde la app no se veria en el telefono hasta
    reiniciar todo. El archivo es chico y esto se llama una vez por carga de pagina.
    """
    try:
        with open(os.path.join(RAIZ, "mentis-settings.json"), encoding="utf-8") as f:
            d = json.load(f)
        a = d.get("apariencia") or {}
        return {
            "paleta": a.get("paleta") or "mentis-clasico",
            "nombre": (a.get("nombre") or "").strip() or "Mentis",
        }
    except Exception:
        # Sin configuracion, los valores de siempre: el telefono nunca se queda sin tema ni sin nombre.
        return {"paleta": "mentis-clasico", "nombre": "Mentis"}


def _archivo_de_sesion(sesion):
    """El historial de ESTA sesion del navegador (pedido del usuario, 2026-07-30: "cada vez que cierre
    el navegador y lo vuelva a abrir, quiero que el chat este vacio").

    Cada sesion tiene su propio archivo, asi lo que el usuario VE es exactamente lo que Mentis ve: si la
    pantalla arrancara vacia pero el modelo siguiera leyendo la charla anterior, contestaria cosas
    referidas a mensajes invisibles. El archivo NO se crea hasta el primer mensaje -- si no, abrir
    el celular diez veces al dia dejaria diez conversaciones vacias de basura.

    El nombre se limpia contra un patron cerrado: llega del navegador, y un identificador con
    barras o puntos escribiria fuera de la carpeta."""
    if not sesion:
        return HISTORIAL
    limpio = re.sub(r"[^A-Za-z0-9-]", "", str(sesion))[:40]
    if not limpio:
        return HISTORIAL
    carpeta = os.path.join(RAIZ, "conversations")
    os.makedirs(carpeta, exist_ok=True)
    return os.path.join(carpeta, "remoto-%s.jsonl" % limpio)


def _ultimos_mensajes(n=20, desde_byte=None, archivo=None):
    """Lee un historial. Con desde_byte, sólo lo NUEVO a partir de esa posición."""
    HISTORIAL_ = archivo or HISTORIAL
    if not os.path.exists(HISTORIAL_):
        return []
    with open(HISTORIAL_, "rb") as f:
        if desde_byte is not None:
            f.seek(desde_byte)
        crudo = f.read()
    salida = []
    for linea in crudo.decode("utf-8", "replace").splitlines():
        linea = linea.strip()
        if not linea:
            continue
        try:
            d = json.loads(linea)
        except Exception:
            continue
        if d.get("role") in ("usuario", "mentis") and (d.get("text") or "").strip():
            salida.append({"role": d["role"], "text": d["text"]})
    return salida if desde_byte is not None else salida[-n:]


def _matar_arbol(proc):
    """Mata el proceso Y sus hijos. proc es 'bash', pero el trabajo de verdad lo hacen los nietos
    (nv-agent, curl, python); matar solo al padre deja al modelo trabajando para nadie. En Windows
    eso se pide con taskkill /T, no con proc.kill()."""
    if proc is None or proc.poll() is not None:
        return
    try:
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _leer_pasos(turno, stderr):
    """Va anotando cada paso del agente a medida que aparece. Corre en su propio hilo y es
    'daemon': si la tuberia nunca cierra (ver el comentario en _correr_turno), que quede colgado
    no le importa a nadie."""
    try:
        for cruda in iter(stderr.readline, b""):
            linea = cruda.decode("utf-8", "replace").rstrip()
            m = PASO_RE.match(linea)
            if m:
                with ESTADO:
                    turno["pasos"].append(m.group(1))
    except Exception:
        pass


def _correr_turno(turno, texto, archivo_hist=None):
    """Corre mentis-chat.sh EN MODO REMOTO anotando cada paso a medida que sale."""
    chat = os.path.join(RAIZ, "mentis-chat.sh")
    if not os.path.exists(chat):
        with ESTADO:
            turno["error"] = "no encuentro mentis-chat.sh en " + RAIZ
            turno["terminado"] = True
        return

    hist = archivo_hist or HISTORIAL
    marca = os.path.getsize(hist) if os.path.exists(hist) else 0
    # "-R" es el modo acotado; sin eso, un mensaje desde el telefono tendria permiso de escribir
    # archivos y ejecutar comandos en la máquina del usuario.
    # "-H" manda la conversacion de ESTA sesion del navegador: el chat escribe ahi y de ahi
    # saca el contexto, asi lo que el usuario ve en pantalla es lo mismo que lee el modelo.
    orden = ["bash", chat, "-R", "-H", hist]
    try:
        proc = subprocess.Popen(
            orden,
            stdin=subprocess.PIPE,
            # stdout va al vacio A PROPOSITO: no se usa (la respuesta se lee del historial) y si se
            # dejara en una tuberia que nadie lee, al llenarse el buffer bash se bloquearia para
            # siempre a mitad de turno.
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            cwd=RAIZ,
        )
    except Exception as e:
        with ESTADO:
            turno["error"] = "no pude arrancar el chat: %s" % e
            turno["terminado"] = True
        return

    with ESTADO:
        turno["proc"] = proc
    try:
        entrada = texto + "\nsalir\n"
        proc.stdin.write(entrada.encode("utf-8"))
        proc.stdin.flush()
        proc.stdin.close()
    except Exception:
        pass

    # OJO CON COMO SE DECIDE QUE EL TURNO TERMINO (bug real, 2026-07-30, encontrado probandolo).
    # La primera version leia stderr con un for hasta el final del archivo y recien ahi daba el
    # turno por cerrado. Nunca cerraba: bash termina, la respuesta YA esta escrita en el historial,
    # pero los procesos de fondo que arranca el chat (el demonio del navegador, el puente MCP)
    # HEREDAN esa misma tuberia de stderr y la mantienen abierta para siempre. El turno quedaba
    # "trabajando" con la respuesta lista y nadie la veia.
    # Quien decide que termino es el PROCESO, no la tuberia: los pasos se leen en un hilo aparte y
    # el turno se cierra cuando bash sale.
    lector = threading.Thread(target=_leer_pasos, args=(turno, proc.stderr), daemon=True)
    lector.start()
    try:
        proc.wait(timeout=TIMEOUT_TURNO_S)
    except subprocess.TimeoutExpired:
        with ESTADO:
            turno["error"] = "Mentis tardo mas de %d segundos y corte la espera" % TIMEOUT_TURNO_S
        _matar_arbol(proc)
        try:
            proc.wait(timeout=20)
        except Exception:
            pass
    # Un respiro para que el lector vuelque las ultimas lineas que ya estaban en la tuberia.
    time.sleep(0.8)

    # PRIMERO se cierra el turno, DESPUES se limpia. El orden importa y lo aprendi rompiendolo
    # (2026-07-30, segunda vez el mismo dia): antes esto hacia proc.stderr.close() antes de marcar
    # el turno terminado, y ese close() SE CUELGA -- el hilo lector esta bloqueado en readline y
    # tiene tomado el candado interno de esa tuberia, asi que cerrarla desde aca espera un candado
    # que no se suelta nunca. Resultado: la respuesta estaba escrita en el historial, bash ya habia
    # muerto, y el turno seguia diciendo "trabajando" para siempre.
    # Regla: la limpieza NUNCA puede ir antes de publicar el resultado.
    nuevos = _ultimos_mensajes(desde_byte=marca, archivo=hist)
    respuestas = [m["text"] for m in nuevos if m["role"] == "mentis"]
    with ESTADO:
        if turno.get("cortado"):
            turno["error"] = turno.get("error") or "cortado"
        elif respuestas:
            turno["respuesta"] = respuestas[-1]
        elif not turno.get("error"):
            turno["error"] = "el chat no dejo respuesta en el historial"
        turno["terminado"] = True
        turno["proc"] = None

    # La tuberia se suelta en un hilo APARTE y descartable. Va por descriptor (os.close) y no por
    # el objeto de archivo, porque el objeto toma el mismo candado que el lector tiene agarrado.
    # Y va en otro hilo porque incluso asi puede quedarse esperando: si eso pasara aca, el turno
    # nunca devolveria el control y el candado de "un turno a la vez" no se soltaria -- el mensaje
    # SIGUIENTE rebotaria con "Mentis esta contestando otro mensaje" para siempre. Ya me paso.
    def _soltar_tuberia():
        try:
            os.close(proc.stderr.fileno())
        except Exception:
            pass
    threading.Thread(target=_soltar_tuberia, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    # BaseHTTPRequestHandler habla HTTP/1.0 por defecto, que cierra la conexion despues de cada
    # respuesta. Con eso, el navegador CARGABA los archivos con fetch pero fallaba al importarlos
    # como modulo ("Failed to fetch dynamically imported module"): el cargador de modulos es mas
    # estricto que fetch con la conexion. Todas las respuestas de aca mandan Content-Length, que es
    # lo unico que HTTP/1.1 exige para poder reusar la conexion.
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass  # el log por defecto escupe una linea por pedido; no aporta nada

    def _responder(self, codigo, cuerpo, tipo="application/json; charset=utf-8", extra=None):
        datos = cuerpo if isinstance(cuerpo, bytes) else str(cuerpo).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(datos)))
        # 'extra' existe para una sola cosa hoy: el Service-Worker-Allowed del service worker.
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        # Sin cache: si el telefono guardara la pagina, cambiarla no serviria de nada.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(datos)
        except Exception:
            pass

    def _servir_estatico(self, ruta):
        """Archivos de la app que la pagina necesita para verse igual: el cuerpo digital y su
        Three.js. Van SIN token a proposito, y no es un descuido: un <script type="module"> resuelve
        sus imports relativos por su cuenta y esas peticiones no llevarian el token, asi que la
        alternativa seria que el cuerpo no cargue nunca. No hay nada secreto en ellos -- es codigo
        de dibujo y una libreria publica -- y la lista blanca de abajo impide pedir cualquier otra
        cosa: sin ella, un "/estatico/../../engine/.nv-secrets" seria una fuga de claves."""
        permitidos = {
            # El formateador de las respuestas es EL MISMO archivo que usa la app. Si hubiera una
            # copia aca, el dia que se arregle un caso raro en uno de los dos el otro se queda con
            # el bug -- y el celular es justo donde menos se mira.
            "/estatico/renderer/formato.js": ("app/renderer/formato.js", "text/javascript"),
            # Las paletas, tambien compartidas: si el celular tuviera su propia lista, el tema
            # elegido en la app se veria distinto en el telefono, que es peor que no tener temas.
            "/estatico/renderer/temas.js": ("app/renderer/temas.js", "text/javascript"),
            # Los iconos de la app instalable. Van SIN token igual que los de arriba, y aca la
            # razon es distinta: Android los vuelve a pedir por su cuenta cuando arma el icono de
            # la pantalla de inicio, y si algun dia se rota el token, un icono roto en el telefono
            # del usuario seria un misterio caro de diagnosticar. No hay nada secreto: es el logo.
            "/estatico/pwa/icono-192.png": ("app/renderer/assets/pwa/icono-192.png", "image/png"),
            "/estatico/pwa/icono-512.png": ("app/renderer/assets/pwa/icono-512.png", "image/png"),
            "/estatico/pwa/icono-maskable-512.png": (
                "app/renderer/assets/pwa/icono-maskable-512.png", "image/png"),
        }
        tipo = "text/javascript"
        if ruta in permitidos:
            rel, tipo = permitidos[ruta]
            camino = os.path.join(RAIZ, *rel.split("/"))
        elif ruta.startswith(BUILD_THREE):
            # La carpeta entera de builds de Three.js, y no un archivo suelto: three.module.min.js
            # IMPORTA a su vez three.core.min.js. Con un solo archivo en la lista, el import
            # anidado daba 401 y se caia la cadena completa -- el cuerpo digital no aparecia y el
            # unico rastro era un 401 en la pestaña de red. (Encontrado mirandolo, 2026-07-30.)
            # El nombre se valida contra un patron sin barras ni puntos dobles: sin eso,
            # ".../build/../../../engine/.nv-secrets" seria una fuga de claves.
            nombre = ruta[len(BUILD_THREE):]
            if not re.fullmatch(r"[A-Za-z0-9._-]+\.js", nombre):
                self._responder(404, json.dumps({"ok": False, "error": "no esta"}))
                return True
            camino = os.path.join(RAIZ, "app", "node_modules", "three", "build", nombre)
        else:
            return False
        try:
            with open(camino, "rb") as f:
                datos = f.read()
        except Exception:
            self._responder(404, json.dumps({"ok": False, "error": "no esta"}))
            return True
        self._responder(200, datos, tipo + "; charset=utf-8")
        return True

    def do_GET(self):
        ruta = urlparse(self.path).path
        if ruta == "/salud":
            return self._responder(200, json.dumps({"ok": True, "servicio": "mentis-web"}))
        if self._servir_estatico(ruta):
            return
        if not _token_ok(self):
            return self._responder(401, json.dumps({"ok": False, "error": "token invalido"}))
        if ruta in ("/", "/index.html"):
            # Al entrar con el token bueno se deja una cookie con el mismo valor. Desde ahi el
            # manifest, el service worker y la app instalada se autentican solos, sin que el token
            # aparezca ni en el HTML ni en el start_url. SameSite=Strict para que ninguna otra
            # pagina pueda usarla, y HttpOnly para que el JavaScript de la propia pagina tampoco
            # pueda leerla. Un anio de vida: si expirara antes, la app instalada dejaria de abrir
            # un dia cualquiera sin motivo visible, que es la peor forma de fallar.
            galleta = ("mentis_token=%s; Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"
                       % TOKEN)
            return self._responder(200, PAGINA, "text/html; charset=utf-8",
                                   extra={"Set-Cookie": galleta})
        if ruta == "/manifest.webmanifest":
            return self._responder(200, json.dumps(MANIFEST),
                                   "application/manifest+json; charset=utf-8")
        if ruta == "/sw.js":
            # Sin 'Service-Worker-Allowed' el navegador limita el alcance a la carpeta del archivo.
            # Como este se sirve desde la raiz ya alcanza, pero se declara igual para que el dia
            # que se mueva no deje de controlar la pagina en silencio.
            return self._responder(200, SERVICE_WORKER, "text/javascript; charset=utf-8",
                                   extra={"Service-Worker-Allowed": "/"})
        if ruta == "/api/historial":
            q = parse_qs(urlparse(self.path).query)
            arch = _archivo_de_sesion((q.get("sesion") or [""])[0])
            return self._responder(200, json.dumps({"ok": True, "mensajes": _ultimos_mensajes(20, archivo=arch)}))
        if ruta == "/api/turno":
            return self._responder(200, json.dumps(self._novedades_del_turno()))
        # Apariencia (2026-08-06): el celular tiene que verse con la MISMA paleta y el MISMO nombre
        # que la app. Sin esto, quien eligiera un tema lo tendria a medias -- lindo en la
        # computadora y naranja en el telefono.
        if ruta == "/api/apariencia":
            return self._responder(200, json.dumps({"ok": True, "apariencia": _apariencia()}))

        # --- Fase 3 (2026-08-01): conversaciones, buscador, resumen y estadisticas -------------
        # Todo esto es de SOLO LECTURA sobre el historial. El modo remoto tiene prohibido escribir,
        # ejecutar, ver la pantalla y usar la camara; agregarle capacidades por aca vaciaria esa
        # decision. Ver engine/nv_web_extras.py.
        if ruta == "/api/conversaciones":
            return self._responder(200, json.dumps({
                "ok": True, "conversaciones": nv_web_extras.listar_conversaciones(RAIZ)}))
        if ruta == "/api/buscar":
            q = parse_qs(urlparse(self.path).query)
            consulta = (q.get("q") or [""])[0]
            return self._responder(200, json.dumps({
                "ok": True, "consulta": consulta,
                "resultados": nv_web_extras.buscar(RAIZ, consulta)}))
        if ruta == "/api/resumen":
            q = parse_qs(urlparse(self.path).query)
            r = nv_web_extras.resumen_para_retomar(RAIZ, (q.get("c") or [""])[0])
            if r is None:
                return self._responder(404, json.dumps({"ok": False, "error": "esa conversacion no existe"}))
            return self._responder(200, json.dumps({"ok": True, "resumen": r}))
        if ruta == "/api/estadisticas":
            return self._responder(200, json.dumps({
                "ok": True, "estadisticas": nv_web_extras.estadisticas(RAIZ)}))

        return self._responder(404, json.dumps({"ok": False, "error": "no existe"}))

    def _novedades_del_turno(self):
        """Long polling: contesta apenas hay un paso nuevo o el turno termino; si no pasa nada,
        vuelve igual a los ~20 s para que el telefono no quede colgado de una conexion eterna."""
        q = parse_qs(urlparse(self.path).query)
        try:
            ident = int((q.get("id") or ["0"])[0])
            desde = int((q.get("desde") or ["0"])[0])
        except ValueError:
            return {"ok": False, "error": "id o desde invalidos"}
        with ESTADO:
            turno = TURNOS.get(ident)
        if turno is None:
            return {"ok": False, "error": "ese turno no existe"}

        fin = time.time() + 20
        while time.time() < fin:
            with ESTADO:
                # 'cortado' tambien cuenta como novedad: matar el arbol de procesos y leer el
                # historial lleva unos segundos, y sin esto la pagina se quedaria esperando el
                # tope de 20 s despues de que apretaste Detener, como si no hubiera pasado nada.
                hay = len(turno["pasos"]) > desde or turno["terminado"] or turno.get("cortado")
            if hay:
                break
            time.sleep(0.25)

        with ESTADO:
            return {
                "ok": True,
                "pasos": turno["pasos"][desde:],
                "total": len(turno["pasos"]),
                "terminado": turno["terminado"],
                "cortando": bool(turno.get("cortado")) and not turno["terminado"],
                "respuesta": turno.get("respuesta"),
                "error": turno.get("error"),
            }

    def _cuerpo_json(self):
        try:
            largo = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(largo).decode("utf-8") or "{}")
        except Exception:
            return None

    def do_POST(self):
        if not _token_ok(self):
            return self._responder(401, json.dumps({"ok": False, "error": "token invalido"}))
        ruta = urlparse(self.path).path

        # --- Fase 3: adjuntar una foto sacada con el celular ------------------------------------
        # Guarda la imagen y devuelve su ruta. NO dispara ningun turno: quien la manda decide
        # despues que preguntar sobre ella. Separar "guardar" de "usar" es lo que permite validar
        # la imagen antes de que llegue a ningun lado.
        if ruta == "/api/foto":
            cuerpo = self._cuerpo_json() or {}
            camino, error = nv_web_extras.guardar_foto(
                RAIZ, cuerpo.get("imagen") or "", str(cuerpo.get("sesion") or ""))
            if error:
                return self._responder(400, json.dumps({"ok": False, "error": error}))
            return self._responder(200, json.dumps({"ok": True, "ruta": camino}))

        if ruta == "/api/detener":
            cuerpo = self._cuerpo_json() or {}
            try:
                ident = int(cuerpo.get("id") or 0)
            except (TypeError, ValueError):
                ident = 0
            with ESTADO:
                turno = TURNOS.get(ident)
                proc = turno.get("proc") if turno else None
                if turno:
                    turno["cortado"] = True
            if turno is None:
                return self._responder(404, json.dumps({"ok": False, "error": "ese turno no existe"}))
            _matar_arbol(proc)
            return self._responder(200, json.dumps({"ok": True}))

        if ruta == "/api/frenar":
            # FRENAR TODO YA, no solo el turno (pedido del usuario: la app lo tiene y el celular no).
            # Diferencia con /api/detener: aquel corta EL turno en curso; este ademas barre lo que
            # haya quedado dando vueltas de turnos anteriores -- procesos huerfanos que ya no
            # reporta nadie y que igual siguen gastando la maquina.
            matados = 0
            with ESTADO:
                procesos = [t.get("proc") for t in TURNOS.values() if t.get("proc")]
                for t in TURNOS.values():
                    if not t["terminado"]:
                        t["cortado"] = True
            for pr in procesos:
                try:
                    if pr.poll() is None:
                        _matar_arbol(pr)
                        matados += 1
                except Exception:
                    pass
            return self._responder(200, json.dumps({"ok": True, "frenados": matados}))

        if ruta != "/api/mensaje":
            return self._responder(404, json.dumps({"ok": False, "error": "no existe"}))

        cuerpo = self._cuerpo_json()
        if cuerpo is None:
            return self._responder(400, json.dumps({"ok": False, "error": "pedido ilegible"}))
        texto = str(cuerpo.get("texto") or "").strip()
        if not texto:
            return self._responder(400, json.dumps({"ok": False, "error": "mensaje vacio"}))

        # El candado se toma acá y se suelta cuando el hilo del turno termina, no al responder:
        # la respuesta HTTP se va enseguida (con el id del turno) pero Mentis sigue trabajando.
        if not TURNO.acquire(blocking=False):
            return self._responder(429, json.dumps(
                {"ok": False, "error": "Mentis esta contestando otro mensaje, probá en un momento"}))

        global TURNO_SEQ
        with ESTADO:
            TURNO_SEQ += 1
            ident = TURNO_SEQ
            turno = {"id": ident, "pasos": [], "respuesta": None, "error": None,
                     "terminado": False, "proc": None, "cortado": False}
            TURNOS[ident] = turno
            # Los turnos viejos no se guardan para siempre: la pagina ya los mostro.
            for viejo in sorted(TURNOS)[:-8]:
                TURNOS.pop(viejo, None)

        archivo_hist = _archivo_de_sesion(str(cuerpo.get("sesion") or ""))

        def trabajar():
            try:
                _correr_turno(turno, texto, archivo_hist)
            finally:
                TURNO.release()

        threading.Thread(target=trabajar, daemon=True).start()
        return self._responder(200, json.dumps({"ok": True, "id": ident}))


def _mi_ip():
    """La IP de esta maquina EN LA RED DE CASA. socket.gethostbyname(hostname) devuelve 127.0.0.1
    en varias configuraciones de Windows, asi que se abre un socket UDP contra una direccion
    externa (no manda ni un byte) y se le pregunta al sistema que interfaz eligio."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    global RAIZ, TOKEN, HISTORIAL
    ap = argparse.ArgumentParser()
    ap.add_argument("--raiz", required=True)
    ap.add_argument("--puerto", type=int, default=8765)
    ap.add_argument("--estado", default="")
    ap.add_argument("--token", default="")
    args = ap.parse_args()

    RAIZ = os.path.abspath(args.raiz)
    HISTORIAL = os.path.join(RAIZ, "history.jsonl")
    TOKEN = args.token or os.environ.get("MENTIS_WEB_TOKEN", "")
    if not TOKEN:
        raise SystemExit("ERROR: hace falta un token (--token o MENTIS_WEB_TOKEN)")

    borradas = _limpiar_conversaciones_remotas()
    if borradas:
        print("limpieza: %d conversaciones remotas viejas o vacias" % borradas, flush=True)

    servidor = ThreadingHTTPServer(("0.0.0.0", args.puerto), Handler)
    puerto = servidor.server_address[1]
    url = "http://%s:%d/?t=%s" % (_mi_ip(), puerto, TOKEN)
    if args.estado:
        with open(args.estado, "w", encoding="utf-8") as f:
            json.dump({"puerto": puerto, "pid": os.getpid(), "url": url,
                       "desde": time.strftime("%Y-%m-%dT%H:%M:%S")}, f)
    print(url, flush=True)
    servidor.serve_forever()


if __name__ == "__main__":
    main()
