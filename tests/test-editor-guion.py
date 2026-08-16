# -*- coding: utf-8 -*-
"""test-editor-guion.py -- el compilador de guiones del modo Editor.

POR QUE SE PUEDE TESTEAR ASI: editor_guion.py NO ejecuta nada, devuelve la lista de comandos. Eso
permite probar el compilador entero sin ffmpeg, sin un video y sin esperar un render -- que es
justamente lo que hace posible tener casos de verdad en vez de mirar el resultado a ver si salio.

LO QUE SE BUSCA ACA no es que "compile": es que un guion INVALIDO se queje ANTES de tocar un
cuadro. Un filter_complex mal armado no falla, escribe un archivo silenciosamente distinto del
pedido, y eso se descubre mirando el video veinte minutos despues.
"""
import importlib.util
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
spec = importlib.util.spec_from_file_location('eg', os.path.join(RAIZ, 'engine', 'editor_guion.py'))
eg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eg)

# Carpeta con los archivos que los guiones nombran. Compilar SI comprueba que existan -- lo que
# se separo es la validacion de estructura, que no toca el disco.
import tempfile
TMP = tempfile.mkdtemp()
for _n in ('clase.mp4', 'm.mp3'):
    with open(os.path.join(TMP, _n), 'wb') as _f:
        _f.write(b'0')

ok = fallo = 0


def _ok(m):
    global ok
    ok += 1
    print('  ok    %s' % m)


def _mal(m, d):
    global fallo
    fallo += 1
    print('  FALLA %s -- %s' % (m, d))


def rechaza(nombre, guion, esperado_en_mensaje=None):
    try:
        eg.validar(guion)
    except eg.GuionInvalido as e:
        if esperado_en_mensaje and esperado_en_mensaje not in str(e):
            _mal(nombre, 'se quejo pero con otro motivo: %s' % e)
        else:
            _ok(nombre)
        return
    except Exception as e:
        _mal(nombre, 'reviento con %s en vez de quejarse bien' % type(e).__name__)
        return
    _mal(nombre, 'lo acepto siendo invalido')


BASE = {'fuente': ['clase.mp4'], 'salida': {'nombre': 'salida.mp4'}, 'pasos': []}


def con(**kw):
    g = {'fuente': ['clase.mp4'], 'salida': {'nombre': 'salida.mp4'}, 'pasos': []}
    g.update(kw)
    return g


print('== un guion invalido se queja ANTES de tocar un cuadro ==')
rechaza('sin fuente', {'salida': {'nombre': 'x.mp4'}}, 'fuente')
rechaza('sin nombre de salida', {'fuente': ['a.mp4'], 'salida': {}}, 'salida.nombre')
rechaza('salida con ruta absoluta', con(salida={'nombre': 'C:/afuera/x.mp4'}), 'absoluta')
rechaza('salida sin extension de video', con(salida={'nombre': 'salida.txt'}), 'terminar en')
rechaza('formato inventado', con(salida={'nombre': 'x.mp4', 'formato': '21:9'}), 'formato desconocido')
rechaza('calidad inventada', con(salida={'nombre': 'x.mp4', 'calidad': 'ultra'}), 'calidad desconocida')
rechaza('paso inventado', con(pasos=[{'tipo': 'rotar'}]), 'tipo desconocido')
rechaza('cortar sin tramos', con(pasos=[{'tipo': 'cortar'}]), 'tramos')
rechaza('un tramo que termina antes de empezar', con(pasos=[{'tipo': 'cortar', 'tramos': [{'desde_s': 10, 'hasta_s': 4}]}]), 'antes de empezar')
rechaza('musica sin archivo', con(pasos=[{'tipo': 'musica'}]), 'archivo')
rechaza('titulo sin texto', con(pasos=[{'tipo': 'titulo'}]), 'texto')
rechaza('velocidad imposible', con(pasos=[{'tipo': 'velocidad', 'factor': 12}]), 'entre 0.5 y 4.0')
rechaza('unir con una sola fuente', con(pasos=[{'tipo': 'unir'}]), 'mas de una')

# cortar_silencios NO se puede compilar solo: necesita los silencios ya medidos. Tiene que decirlo
# claro, no producir un video sin cortar.
try:
    eg.compilar(con(pasos=[{'tipo': 'cortar_silencios'}]), raiz=TMP)
    _mal('cortar_silencios sin resolver', 'compilo igual: el video saldria sin cortar')
except eg.GuionInvalido as e:
    if 'antes de compilar' in str(e):
        _ok('cortar_silencios avisa que hay que resolverlo antes')
    else:
        _mal('cortar_silencios', 'motivo raro: %s' % e)

print('== compila lo que tiene que compilar ==')
g = con(salida={'nombre': 'final.mp4', 'formato': '9:16', 'calidad': 'alta'}, pasos=[
    {'tipo': 'cortar', 'tramos': [{'desde_s': 0, 'hasta_s': 10}, {'desde_s': 20, 'hasta_s': 30}]},
    {'tipo': 'formato'},
    {'tipo': 'titulo', 'texto': 'Hola', 'desde_s': 0, 'dura_s': 3},
])
comandos, final = eg.compilar(g, raiz=TMP, salida_dir=TMP)
if len(comandos) == 3:
    _ok('un guion de 3 pasos da 3 comandos')
else:
    _mal('cantidad de comandos', 'dio %d' % len(comandos))

if final.endswith('final.mp4') and comandos[-1][1][-1] == final:
    _ok('el ultimo comando escribe la salida final (y no un intermedio)')
else:
    _mal('salida final', 'el ultimo comando termina en %r' % comandos[-1][1][-1])

# Cada paso tiene que leer lo que escribio el anterior. Si no, el guion se compila pero cada paso
# trabaja sobre el video ORIGINAL y se pierden los cambios de los pasos previos.
entradas = [c[1][c[1].index('-i') + 1] for c in comandos]
salidas = [c[1][-1] for c in comandos]
if entradas[1] == salidas[0] and entradas[2] == salidas[1]:
    _ok('cada paso toma como entrada la salida del anterior')
else:
    _mal('encadenado', 'entradas=%r salidas=%r' % (entradas, salidas))

if any('1080' in a and '1920' in a for c in comandos for a in c[1]):
    _ok('el formato 9:16 sale como 1080x1920')
else:
    _mal('formato vertical', 'no encontre la escala 1080x1920')

print('== los escapes, que es donde esto se rompe ==')
# EL TEXTO DEL TITULO NO VIAJA EN EL COMANDO. Medido el 2026-08-15: con text='Precio: 5 'pesos''
# ffmpeg fallaba con "No such filter: '0.0'" -- las comillas del texto desbalancean el valor y la
# coma de enable='between(t,0,2)' se lee como separador de filtros. Y no se arregla escapando:
# dentro de comillas simples ffmpeg NO interpreta escapes. Se saca el texto del comando y listo.
g2 = con(pasos=[{'tipo': 'titulo', 'texto': "Precio: 5 'pesos' \ hoy"}])
comandos2, _ = eg.compilar(g2, raiz=TMP, salida_dir=TMP)
vf = [a for a in comandos2[0][1] if 'drawtext' in a][0]
if "Precio" not in ' '.join(comandos2[0][1]):
    _ok('el texto del titulo NO aparece en el comando (va por archivo)')
else:
    _mal('texto fuera del comando', 'el texto sigue viajando en el filtro: %s' % vf[:100])

aux = comandos2[0][2].get('escribir') or {}
if aux and list(aux.values())[0] == "Precio: 5 'pesos' \ hoy":
    _ok('el texto se entrega aparte, tal cual, sin escapar nada')
else:
    _mal('el texto auxiliar', repr(aux)[:120])

# La ruta del.srt viaja adentro de un filtro: en Windows trae backslashes y "C:".
g3 = con(pasos=[{'tipo': 'subtitulos', 'archivo': 'C:\\Users\\el usuario\\subs.srt'}])
comandos3, _ = eg.compilar(g3, raiz=TMP, salida_dir=TMP)
vfs = [a for a in comandos3[0][1] if 'subtitles' in a][0]
if '\\:' in vfs and '\\\\' not in vfs.split('force_style')[0].replace('\\:', ''):
    _ok('la ruta del srt va con las barras dadas vuelta y los dos puntos escapados')
else:
    _mal('ruta del srt', vfs[:140])

# EL SEGFAULT (2026-08-15): sin fontfile explicito, drawtext no falla -- CRASHEA ffmpeg con
# "Fontconfig error" + "Segmentation fault", dejando el video a medio escribir. En Windows no hay
# fontconfig, asi que la fuente hay que decirsela siempre.
if eg.fuente_disponible():
    vf_t = [a for a in comandos2[0][1] if 'drawtext' in a][0]
    if 'fontfile=' in vf_t:
        _ok('el titulo pasa la fuente explicita (sin eso, ffmpeg segfaultea)')
    else:
        _mal('fontfile', 'el filtro no dice que fuente usar: va a crashear')
    if 'textfile=' in vf_t and ':text=' not in vf_t:
        _ok('el texto va por ARCHIVO y no adentro del comando')
    else:
        _mal('textfile', 'el texto viaja en el comando: las comillas rompen el filtro')
else:
    _mal('fuente del sistema', 'no encontre ninguna de las fuentes buscadas')

print('== la musica ==')
g4 = con(pasos=[{'tipo': 'musica', 'archivo': 'm.mp3', 'volumen': 0.2, 'ducking': True}])
c4, _ = eg.compilar(g4, raiz=TMP, salida_dir=TMP)
fc = [a for a in c4[0][1] if 'sidechain' in a]
if fc:
    _ok('con ducking, la musica baja cuando hay voz (sidechaincompress)')
else:
    _mal('ducking', 'no aparece sidechaincompress')
g5 = con(pasos=[{'tipo': 'musica', 'archivo': 'm.mp3', 'ducking': False}])
c5, _ = eg.compilar(g5, raiz=TMP, salida_dir=TMP)
if not [a for a in c5[0][1] if 'sidechain' in a]:
    _ok('sin ducking, mezcla directa')
else:
    _mal('sin ducking', 'metio sidechain igual')

print('== un guion sin pasos ==')
c6, f6 = eg.compilar(con(pasos=[]), raiz=TMP, salida_dir=TMP)
if len(c6) == 1 and '-c' in c6[0][1]:
    _ok('un guion sin pasos copia sin recodificar')
else:
    _mal('sin pasos', repr(c6)[:120])

print('')
print('test-editor-guion: %d ok, %d fallas' % (ok, fallo))
sys.exit(1 if fallo else 0)
