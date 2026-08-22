# -*- coding: utf-8 -*-
"""Casos de trozo_para_juan: que texto ve el usuario segun QUE forma llega por el canal.

Este archivo existe por un bug real (2026-08-18): el streaming estuvo mudo en los dos caminos mas
frecuentes -- el cierre forzado y la charla directa -- porque el unico extractor que habia buscaba
el campo "answer" de un JSON, y esos dos caminos devuelven prosa. Los tests que habia entonces
verificaban el cableado con `grep` sobre el fuente, asi que estaban los cuatro en verde mientras
la pantalla no mostraba nada. De ahi que estos casos EJECUTEN la funcion en vez de mirarla.
"""
import io, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))
import nv_stream

fallos = []
def caso(nombre, acum, trozo, emitido, raw, esperado):
    got, _ = nv_stream.trozo_para_juan(acum, trozo, emitido, raw)
    if got != esperado:
        fallos.append("%s: esperaba %r, dio %r" % (nombre, esperado, got))

# --- prosa con raw: pasa tal cual (el caso que estaba roto) ---
caso("prosa-raw", "El mate es", " es", 0, True, " es")
caso("prosa-raw-primer-chunk", "El", "El", 0, True, "El")

# --- JSON con raw: NO se muestra crudo, se desarma ---
# El cierre forzado pide prosa y el modelo contesta JSON igual: si esto devolviera el trozo, el usuario
# veria '{"tool":"answer"...' en pantalla.
caso("json-pese-a-raw", '{"tool":"answer","answer":"Hola', '"Hola', 0, True, "Hola")
caso("json-pese-a-raw-arranque", '{"', '{"', 0, True, "")

# --- JSON sin raw: comportamiento de siempre ---
caso("json-normal", '{"tool":"answer","answer":"Hola', '"Hola', 0, False, "Hola")

# --- prosa SIN raw: no hay campo answer -> no se emite nada (no se inventa texto) ---
caso("prosa-sin-raw", "El mate es", " es", 0, False, "")

# --- escapes partidos al medio no salen rotos ---
BARRA = chr(92)
got, _ = nv_stream.trozo_para_juan('{"answer":"linea1' + BARRA + 'nlinea2', 'x', 0, True)
if got != 'linea1' + chr(10) + 'linea2':
    fallos.append('escape-salto: dio %r' % (got,))
got, _ = nv_stream.trozo_para_juan('{"answer":"caf' + BARRA + 'u00e', 'x', 0, True)
if BARRA + 'u' in got:
    fallos.append('escape-unicode-partido: se filtro un escape a medias: %r' % (got,))

# --- lo ya emitido no se repite ---
prim, n = nv_stream.trozo_para_juan('{"answer":"Hola', "x", 0, False)
seg, _ = nv_stream.trozo_para_juan('{"answer":"Hola mundo', "x", n, False)
if prim + seg != "Hola mundo":
    fallos.append("incremental: %r + %r != 'Hola mundo'" % (prim, seg))

if fallos:
    for f in fallos:
        print("MAL " + f)
    sys.exit(1)
print("casos: 10")
