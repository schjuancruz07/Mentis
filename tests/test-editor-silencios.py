# -*- coding: utf-8 -*-
"""test-editor-silencios.py -- la politica de corte de silencios del modo Editor.

POR QUE ESTOS CASOS Y NO OTROS: los tres primeros son bugs que aparecieron probando la funcion con
numeros escritos a mano, antes de tocar un solo video. Ninguno se habria visto mirando el
resultado: un corte que se come el principio de una palabra o un parpadeo de 0,15 s al arrancar
pasan por "el video quedo raro" y no por "hay un bug aca".

Se corre solo, sin ffmpeg y sin Whisper: recibe numeros y devuelve numeros.
"""
import importlib.util
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
spec = importlib.util.spec_from_file_location('es', os.path.join(RAIZ, 'engine', 'editor_silencios.py'))
es = importlib.util.module_from_spec(spec)
spec.loader.exec_module(es)

ok = fallo = 0


def _ok(m):
    global ok
    ok += 1
    print('  ok    %s' % m)


def _mal(m, d):
    global fallo
    fallo += 1
    print('  FALLA %s -- %s' % (m, d))


def dura(tramos):
    return sum(b - a for a, b in tramos)


print('== parsear la salida de ffmpeg ==')
CRUDO = """
[silencedetect @ 000] silence_start: 8.0
[silencedetect @ 000] silence_end: 20.04 | silence_duration: 12.04
[silencedetect @ 000] silence_start: 44.0
"""
sil = es.parsear_silencedetect(CRUDO)
if sil == [(8.0, 20.04), (44.0, None)]:
    _ok('lee los silencios, y el que no cierra queda abierto (None)')
else:
    _mal('parsear silencedetect', 'obtuvo: %r' % (sil,))

print('== la politica ==')
SEG = [{'desde': 2.0, 'hasta': 8.0}, {'desde': 20.0, 'hasta': 26.0}, {'desde': 40.0, 'hasta': 44.0}]
SIL = [(0.0, 2.0), (8.0, 20.0), (26.2, 27.0), (44.0, 60.0)]
t = es.decidir_cortes(SIL, SEG, duracion=60.0)

# BUG 1: el silencio de 12 s no se cortaba nunca. Un segmento de voz que TERMINA justo donde
# arranca el silencio (o sea: lo normal) contaba como pisada y anulaba el silencio entero.
if dura(t) < 40:
    _ok('el silencio largo se corta (60 s -> %.1f s)' % dura(t))
else:
    _mal('cortar el silencio largo', 'el video quedo en %.1f s: no corto casi nada' % dura(t))

# BUG 2: quedaba un tramo inicial de 0,15 s -- un parpadeo antes de que empiece el video.
if not t or (t[0][1] - t[0][0]) > 0.3:
    _ok('no deja un parpadeo al arrancar')
else:
    _mal('parpadeo inicial', 'el primer tramo dura %.2f s' % (t[0][1] - t[0][0]))

# BUG 3 (el que importa de verdad): ningun corte puede caer sobre una palabra.
partidos = [s for s in SEG
            if not any(a <= float(s['desde']) + 0.01 and b >= float(s['hasta']) - 0.01 for a, b in t)]
if not partidos:
    _ok('ningun segmento de voz queda partido por un corte')
else:
    _mal('cortar sobre la voz', 'quedaron partidos: %r' % (partidos,))

# La cola muerta del final se va entera.
if t and t[-1][1] < 45:
    _ok('la cola muerta del final se corta (termina en %.2f, no en 60)' % t[-1][1])
else:
    _mal('cortar la cola', 'el ultimo tramo termina en %.2f' % (t[-1][1] if t else -1))

# Un silencio corto no se toca: cortar cada pausa de medio segundo suena a metralleta.
t2 = es.decidir_cortes([(8.0, 8.4)], SEG, duracion=60.0)
if len(t2) == 1 and abs(dura(t2) - 60.0) < 0.1:
    _ok('un silencio mas corto que el umbral no se toca')
else:
    _mal('umbral', 'obtuvo: %r' % (t2,))

# Sin transcripcion tiene que seguir andando (video sin voz reconocible).
t3 = es.decidir_cortes([(10.0, 25.0)], [], duracion=60.0)
if dura(t3) < 50:
    _ok('sin transcripcion igual corta (video sin voz)')
else:
    _mal('sin transcripcion', 'no corto nada: %r' % (t3,))

# Y el resultado tiene que servirle al compilador tal cual.
paso = es.tramos_a_guion(t)
if paso['tipo'] == 'cortar' and paso['tramos'] and 'desde_s' in paso['tramos'][0]:
    _ok('sale en el formato que espera editor_guion.py')
else:
    _mal('formato de salida', repr(paso)[:120])

print('')
print('test-editor-silencios: %d ok, %d fallas' % (ok, fallo))
sys.exit(1 if fallo else 0)
