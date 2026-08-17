# -*- coding: utf-8 -*-
"""editor_guion.py -- valida un guion de edicion y lo compila a comandos de ffmpeg.

POR QUE EXISTE (2026-08-15, modo Mentis Editor). El modelo NO escribe comandos de ffmpeg: escribe
un guion declarativo (que pasa, no como) y este archivo lo traduce. La razon es concreta y ya la
pagamos en otro lado: un filter_complex mal armado no falla, escribe un archivo silenciosamente
distinto del pedido. Un guion se valida antes de tocar un solo cuadro.

LO QUE ESTE ARCHIVO NO HACE: no ejecuta nada. Devuelve la lista de comandos. Asi se puede testear
entero sin ffmpeg y sin gastar un segundo de CPU -- que es lo que permite tener casos de prueba de
verdad en vez de mirar el video a ver si salio.

Uso:
    python3 editor_guion.py validar  <guion.json>
    python3 editor_guion.py compilar <guion.json>     -> imprime los comandos, uno por linea
"""
import json
import os
import shlex
import sys

# Los pasos que existen. Cualquier otro es un error explicito y no un no-op: un guion con un paso
# inventado tiene que quejarse, no producir un video al que le falta lo que se pidio.
PASOS = ('cortar', 'cortar_silencios', 'unir', 'formato', 'subtitulos', 'titulo', 'musica', 'velocidad')

FORMATOS = {
    '16:9': (1920, 1080),
    '9:16': (1080, 1920),
    '1:1': (1080, 1080),
    '4:5': (1080, 1350),
}

# CPU y no GPU, y esto se midio en la máquina del usuario el 2026-08-15: h264_nvenc falla
# (return code -22) y h264_amf tambien; h264_qsv anda pero deja el archivo 42% mas pesado
# (27 MB contra 19 MB) para ganar apenas 1,1 s en 30 s de 1080p. No vale.
CALIDADES = {
    'alta':  ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20'],
    'media': ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23'],
    'baja':  ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28'],
}


class GuionInvalido(Exception):
    """El guion no se puede compilar. El mensaje va al modelo, asi que dice como arreglarlo."""


def _pedir(cond, mensaje):
    if not cond:
        raise GuionInvalido(mensaje)


def validar_entradas(guion, raiz):
    """Comprueba que los archivos de entrada existan de verdad.

    VA SEPARADO DE validar() A PROPOSITO. Antes estaban juntos y traia dos problemas: (1) un guion
    con un paso imposible de compilar se quejaba de "no existe el archivo" en vez del paso, o sea
    el primer error que encontraba tapaba al de verdad; (2) no se podia revisar la estructura de un
    guion sin tener el video a mano -- ni para testear, ni para que el modelo valide un plan antes
    de que el usuario le pase el archivo.
    Estructura primero, disco despues: el mensaje que llega es siempre el del problema real.
    """
    fuentes = guion.get('fuente')
    if isinstance(fuentes, str):
        fuentes = [fuentes]
    for f in (fuentes or []):
        abs_f = f if os.path.isabs(f) else os.path.join(raiz, f)
        _pedir(os.path.isfile(abs_f), "no existe el archivo de entrada: %s" % f)


def validar(guion, raiz=None):
    """Revisa la ESTRUCTURA del guion y devuelve una copia normalizada. No toca el disco.

    Se valida TODO antes de compilar nada. Un guion que falla en el paso 4 despues de haber
    renderizado los tres primeros deja archivos a medio hacer y al usuario esperando de gusto.
    """
    _pedir(isinstance(guion, dict), 'el guion tiene que ser un objeto JSON')

    fuentes = guion.get('fuente')
    if isinstance(fuentes, str):
        fuentes = [fuentes]
    _pedir(isinstance(fuentes, list) and fuentes, "falta 'fuente': la ruta del video a editar")
    for f in fuentes:
        _pedir(isinstance(f, str) and f.strip(), "cada 'fuente' tiene que ser una ruta")

    salida = guion.get('salida') or {}
    _pedir(isinstance(salida, dict), "'salida' tiene que ser un objeto")
    nombre = salida.get('nombre')
    _pedir(isinstance(nombre, str) and nombre.strip(), "falta 'salida.nombre'")
    _pedir(not os.path.isabs(nombre), "'salida.nombre' tiene que ser un nombre, no una ruta absoluta")
    _pedir(nombre.lower().endswith(('.mp4', '.mov', '.webm')),
           "'salida.nombre' tiene que terminar en.mp4,.mov o.webm")

    formato = salida.get('formato', '16:9')
    _pedir(formato in FORMATOS, "formato desconocido: %s (hay: %s)" % (formato, ', '.join(FORMATOS)))
    calidad = salida.get('calidad', 'alta')
    _pedir(calidad in CALIDADES, "calidad desconocida: %s (hay: %s)" % (calidad, ', '.join(CALIDADES)))

    pasos = guion.get('pasos') or []
    _pedir(isinstance(pasos, list), "'pasos' tiene que ser una lista")
    for i, p in enumerate(pasos, 1):
        _pedir(isinstance(p, dict), 'el paso %d tiene que ser un objeto' % i)
        tipo = p.get('tipo')
        _pedir(tipo in PASOS, "paso %d: tipo desconocido '%s' (hay: %s)" % (i, tipo, ', '.join(PASOS)))
        if tipo == 'cortar':
            _pedir(isinstance(p.get('tramos'), list) and p['tramos'],
                   "paso %d: 'cortar' necesita 'tramos': [{desde_s, hasta_s},...]" % i)
            for t in p['tramos']:
                _pedir(isinstance(t, dict) and 'desde_s' in t and 'hasta_s' in t,
                       "paso %d: cada tramo necesita 'desde_s' y 'hasta_s'" % i)
                _pedir(_num(t['hasta_s']) > _num(t['desde_s']),
                       "paso %d: un tramo termina antes de empezar (%s -> %s)" % (i, t['desde_s'], t['hasta_s']))
        if tipo == 'musica':
            _pedir(isinstance(p.get('archivo'), str) and p['archivo'].strip(),
                   "paso %d: 'musica' necesita 'archivo'" % i)
        if tipo == 'titulo':
            _pedir(isinstance(p.get('texto'), str) and p['texto'].strip(),
                   "paso %d: 'titulo' necesita 'texto'" % i)
        if tipo == 'subtitulos':
            _pedir(p.get('archivo') or p.get('desde_transcripcion', True),
                   "paso %d: 'subtitulos' necesita 'archivo' o dejar 'desde_transcripcion' en true" % i)
        if tipo == 'velocidad':
            factor = _num(p.get('factor', 0))
            _pedir(0.5 <= factor <= 4.0, "paso %d: 'factor' de velocidad tiene que estar entre 0.5 y 4.0" % i)
        if tipo == 'unir':
            _pedir(len(fuentes) > 1, "paso %d: 'unir' necesita mas de una 'fuente'" % i)

    normal = dict(guion)
    normal['fuente'] = fuentes
    normal['salida'] = {'nombre': nombre, 'formato': formato, 'calidad': calidad}
    normal['pasos'] = pasos
    return normal


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        raise GuionInvalido('esperaba un numero y vino: %r' % (v,))


# FUENTES PARA drawtext, EN ORDEN DE PREFERENCIA.
#
# POR QUE HACE FALTA DECIRLE CUAL: en Windows no hay fontconfig, y drawtext sin 'fontfile' no
# falla con un error -- CRASHEA. Medido el 2026-08-15: "Fontconfig error: Cannot load default
# config file" seguido de "Segmentation fault", con el video a medio escribir. Un titulo sin
# fuente explicita reventaba ffmpeg entero.
FUENTES = [
    'C:/Windows/Fonts/segoeui.ttf',
    'C:/Windows/Fonts/arial.ttf',
    'C:/Windows/Fonts/calibri.ttf',
    'C:/Windows/Fonts/tahoma.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/System/Library/Fonts/Helvetica.ttc',
]


def fuente_disponible():
    """La primera fuente del sistema que exista de verdad, o None."""
    for f in FUENTES:
        if os.path.isfile(f):
            return f
    return None


def _esc_filtro(texto):
    """Escapa texto para meterlo en un filtro de ffmpeg (drawtext y parientes).

    El orden importa: primero la barra invertida, si no se re-escapan las barras que agregamos
    nosotros dos lineas mas abajo.
    """
    for de, a in (('\\', '\\\\'), (':', '\\:'), ("'", "\\'"), ('%', '\\%')):
        texto = texto.replace(de, a)
    return texto


def compilar(guion, raiz='.', salida_dir=None):
    """Devuelve [(descripcion, [argumentos de ffmpeg]),...] en orden.

    Cada comando escribe un archivo intermedio; el ultimo escribe la salida final. Se hace por
    pasos y no en un solo filter_complex gigante a proposito: cuando algo sale mal, hay que poder
    mirar en QUE paso se rompio y con que archivo entro.
    """
    # Estructura primero, disco despues: asi el mensaje que llega es el del problema real y no
    # "no existe el archivo" tapando un paso mal escrito.
    g = validar(guion)
    validar_entradas(g, raiz)
    salida_dir = salida_dir or raiz
    fuentes = [f if os.path.isabs(f) else os.path.join(raiz, f) for f in g['fuente']]
    ancho, alto = FORMATOS[g['salida']['formato']]
    calidad = CALIDADES[g['salida']['calidad']]
    final = os.path.join(salida_dir, g['salida']['nombre'])

    comandos = []
    actual = fuentes[0]
    paso_n = 0

    def intermedio():
        return os.path.join(salida_dir, '.editor-paso-%d.mp4' % paso_n)

    for p in g['pasos']:
        tipo = p['tipo']
        paso_n += 1
        destino = intermedio()

        if tipo == 'unir':
            lista = os.path.join(salida_dir, '.editor-unir.txt')
            args = ['ffmpeg', '-nostdin', '-y', '-f', 'concat', '-safe', '0', '-i', lista, '-c', 'copy', destino]
            comandos.append(('unir %d fuentes' % len(fuentes), args, {'lista': lista, 'archivos': fuentes}))

        elif tipo == 'cortar':
            # Se arma un filtro select con los tramos que SE QUEDAN. Un solo pase: cortar tramo por
            # tramo y despues concatenar cuesta un archivo temporal por tramo y una recodificacion
            # por cada uno.
            tramos = p['tramos']
            cond = '+'.join("between(t,%s,%s)" % (_num(t['desde_s']), _num(t['hasta_s'])) for t in tramos)
            fv = "select='%s',setpts=N/FRAME_RATE/TB" % cond
            fa = "aselect='%s',asetpts=N/SAMPLE_RATE/TB" % cond
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual, '-vf', fv, '-af', fa] + calidad + ['-c:a', 'aac', destino]
            comandos.append(('cortar: dejar %d tramo(s)' % len(tramos), args, {}))

        elif tipo == 'cortar_silencios':
            # Este paso NO se puede compilar solo: necesita saber DONDE estan los silencios, y eso
            # sale de correr ffmpeg con silencedetect y de la transcripcion. Lo resuelve
            # mentis-editar.sh antes de llamar aca, y lo reemplaza por un paso 'cortar' con los
            # tramos ya calculados. Si llega hasta aca es que ese paso previo no corrio.
            raise GuionInvalido(
                "'cortar_silencios' hay que resolverlo antes de compilar: mentis-editar.sh mide los "
                "silencios y lo reemplaza por un paso 'cortar' con los tramos concretos")

        elif tipo == 'formato':
            # Escala metiendo el video entero adentro del cuadro y rellena con barras, en vez de
            # recortar. Recortar decide por su cuenta que parte de la imagen se pierde.
            vf = ("scale=%d:%d:force_original_aspect_ratio=decrease,"
                  "pad=%d:%d:(ow-iw)/2:(oh-ih)/2" % (ancho, alto, ancho, alto))
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual, '-vf', vf] + calidad + ['-c:a', 'copy', destino]
            comandos.append(('formato %s' % g['salida']['formato'], args, {}))

        elif tipo == 'velocidad':
            f = _num(p['factor'])
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual,
                    '-filter_complex', '[0:v]setpts=%s*PTS[v];[0:a]atempo=%s[a]' % (round(1.0 / f, 6), f),
                    '-map', '[v]', '-map', '[a]'] + calidad + ['-c:a', 'aac', destino]
            comandos.append(('velocidad x%s' % f, args, {}))

        elif tipo == 'subtitulos':
            srt = p.get('archivo') or os.path.join(salida_dir, '.editor-subs.srt')
            estilo = p.get('estilo', 'sobrio')
            estilos = {
                'sobrio': 'FontName=Arial,FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H80000000,BorderStyle=3,Outline=1,MarginV=30',
                'grande': 'FontName=Arial,FontSize=28,Bold=1,PrimaryColour=&H00FFFFFF,OutlineColour=&HC0000000,BorderStyle=3,Outline=2,MarginV=80',
            }
            _pedir(estilo in estilos, "estilo de subtitulos desconocido: %s (hay: %s)" % (estilo, ', '.join(estilos)))
            # La ruta del.srt va adentro de un filtro: las barras invertidas de Windows y los dos
            # puntos de "C:" rompen el parser de filtros si no se escapan.
            vf = "subtitles='%s':force_style='%s'" % (_esc_filtro(srt.replace('\\', '/')), estilos[estilo])
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual, '-vf', vf] + calidad + ['-c:a', 'copy', destino]
            comandos.append(('subtitulos (%s)' % estilo, args, {'necesita_srt': srt}))

        elif tipo == 'titulo':
            desde = _num(p.get('desde_s', 0))
            dura = _num(p.get('dura_s', 3))
            # EL TEXTO VA POR ARCHIVO (textfile=), NO adentro del comando (text=).
            #
            # Medido: con text='Precio: 5 'pesos'' ffmpeg fallaba con "No such filter: '0.0'". Las
            # comillas del texto desbalancean el valor entrecomillado y, a partir de ahi, la coma
            # de enable='between(t,0,2)' se lee como separador de filtros. Y no se arregla
            # escapando mas: dentro de comillas simples ffmpeg NO interpreta escapes, asi que no
            # hay forma de meter una comilla ahi.
            #
            # textfile= saca el texto del comando entero. Es la misma leccion que ERR-159 y que
            # engine/textos/: el texto que atraviesa capas de escapes se corrompe, asi que no se
            # lo hace atravesar.
            tfile = os.path.join(salida_dir, '.editor-titulo-%d.txt' % paso_n)
            fuente = fuente_disponible()
            _pedir(fuente is not None,
                   'no encontre ninguna fuente para escribir el titulo. Sin fontfile, drawtext no '
                   'falla: crashea ffmpeg. Buscadas: %s' % ', '.join(FUENTES))
            vf = ("drawtext=fontfile='%s':textfile='%s':fontcolor=white:fontsize=%d:box=1:"
                  "boxcolor=black@0.5:boxborderw=12:x=(w-text_w)/2:y=h*0.78:enable='between(t,%s,%s)'"
                  % (_esc_filtro(fuente), _esc_filtro(tfile.replace('\\', '/')),
                     max(24, alto // 20), desde, desde + dura))
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual, '-vf', vf] + calidad + ['-c:a', 'copy', destino]
            comandos.append(('titulo: %s' % p['texto'][:40], args, {'escribir': {tfile: p['texto']}}))

        elif tipo == 'musica':
            archivo = p['archivo'] if os.path.isabs(p['archivo']) else os.path.join(raiz, p['archivo'])
            vol = _num(p.get('volumen', 0.15))
            if p.get('ducking', True):
                # sidechaincompress: la musica baja sola cuando alguien habla. Sin esto, "musica de
                # fondo" tapa la voz y hay que elegir entre musica inaudible o voz tapada.
                fc = ('[1:a]volume=%s[m];[0:a]asplit=2[voz][llave];'
                      '[m][llave]sidechaincompress=threshold=0.02:ratio=8:attack=5:release=300[mduck];'
                      '[voz][mduck]amix=inputs=2:duration=first[a]' % vol)
            else:
                fc = '[1:a]volume=%s[m];[0:a][m]amix=inputs=2:duration=first[a]' % vol
            args = ['ffmpeg', '-nostdin', '-y', '-i', actual, '-i', archivo, '-filter_complex', fc,
                    '-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', destino]
            comandos.append(('musica de fondo%s' % (' con ducking' if p.get('ducking', True) else ''), args,
                             {'necesita': archivo}))

        actual = destino

    # El ultimo paso escribe la salida final. Si no hubo ningun paso, se copia la fuente tal cual
    # (un guion sin pasos es raro pero no es un error: puede venir de convertir de formato).
    if comandos:
        comandos[-1][1][-1] = final
    else:
        comandos.append(('copiar sin cambios', ['ffmpeg', '-nostdin', '-y', '-i', actual, '-c', 'copy', final], {}))
    return comandos, final


def _main(argv):
    # SALIDA CON \n Y NO \r\n. En Windows Python traduce los saltos al escribir, y estas lineas las
    # ejecuta bash: el \r quedaba pegado al ULTIMO argumento, o sea al nombre del archivo de
    # salida, y ffmpeg intentaba escribir en "salida.mp4\r". Peor todavia para diagnosticarlo: el
    # \r hace que el mensaje de error se sobrescriba solo en la terminal y se lea otra cosa.
    try:
        sys.stdout.reconfigure(newline='')
    except Exception:
        pass
    if len(argv) < 3 or argv[1] not in ('validar', 'compilar'):
        sys.stderr.write(__doc__)
        return 64
    with open(argv[2], encoding='utf-8') as f:
        crudo = f.read()
    try:
        guion = json.loads(crudo)
    except ValueError as e:
        # UN TRACEBACK NO LE SIRVE A NADIE. Quien escribe estos guiones es el modelo, y el error
        # mas probable es tambien el mas silencioso: una ruta de Windows tal cual, "C:\Users\...",
        # donde cada barra invertida es un escape invalido de JSON. Se detecta y se dice como se
        # arregla, en vez de volcar la pila de Python.
        pista = ''
        if '\\' in crudo:
            pista = ("\nPISTA: el guion tiene barras invertidas. En JSON hay que escribirlas dobles "
                     "(C:\\\\Users\\\\...) o, mas simple, usar barras normales: C:/Users/... "
                     "ffmpeg las entiende igual en Windows.")
        sys.stderr.write('GUION INVALIDO: no es JSON valido (%s)%s\n' % (e, pista))
        return 1
    raiz = os.path.dirname(os.path.abspath(argv[2]))
    try:
        if argv[1] == 'validar':
            validar(guion, raiz=raiz)
            print('OK: el guion es valido')
            return 0
        comandos, final = compilar(guion, raiz=raiz)
        for desc, args, extra in comandos:
            # Los auxiliares (hoy: el texto de los titulos) se escriben ACA y no se emiten como
            # comandos. Meterlos en el script haria pasar el texto por bash, que es exactamente la
            # capa de escapes de la que se lo saco.
            for ruta, contenido in (extra.get('escribir') or {}).items():
                with open(ruta, 'w', encoding='utf-8') as fa:
                    fa.write(contenido)
            print('# %s' % desc)
            print(' '.join(shlex.quote(a) for a in args))
        print('# salida final: %s' % final)
        return 0
    except GuionInvalido as e:
        sys.stderr.write('GUION INVALIDO: %s\n' % e)
        return 1


if __name__ == '__main__':
    sys.exit(_main(sys.argv))
