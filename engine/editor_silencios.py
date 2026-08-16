# -*- coding: utf-8 -*-
"""editor_silencios.py -- convierte los silencios detectados en la lista de tramos que se quedan.

DONDE ENCAJA. La receta 'limpiar' del modo Editor no puede compilarse sola: hay que saber DONDE
estan los silencios. El flujo es:

    ffmpeg -af silencedetect  ->  [(desde, hasta),...]   (los silencios)
    nv_stt_server /segmentos  ->  [(desde, hasta, texto)] (donde hay voz, con lo que se dice)
                              ->  ESTE ARCHIVO
                              ->  paso 'cortar' con los tramos concretos
                              ->  editor_guion.py compila

POR QUE NO SE USA SOLO silencedetect. Porque detecta silencio ACUSTICO, y una respiracion antes de
una palabra no es silencio para quien mira: es el arranque de la frase. Cortar por el nivel de
audio pelado produce videos que suenan atropellados y, peor, cortan el principio de las palabras.
Por eso los silencios se cruzan con los tiempos de la transcripcion, que dicen donde hay VOZ.

Este archivo no ejecuta ffmpeg ni Whisper: recibe los datos ya medidos. Asi se puede probar entero
con numeros escritos a mano.
"""
import json
import re
import sys

# Salida de ffmpeg -af silencedetect, tal cual la imprime por stderr.
RE_INICIO = re.compile(r'silence_start:\s*(-?[\d.]+)')
RE_FIN = re.compile(r'silence_end:\s*(-?[\d.]+)')


def parsear_silencedetect(texto):
    """De la salida cruda de ffmpeg a [(desde, hasta),...] en segundos.

    Un silencio que empieza y no termina (porque el video termina en silencio) se cierra con None:
    quien llama sabe la duracion total y lo resuelve. Descartarlo aca perderia justo el silencio
    mas comun de todos, que es la cola muerta al final de una grabacion.
    """
    silencios = []
    abierto = None
    for linea in texto.split('\n'):
        mi = RE_INICIO.search(linea)
        if mi:
            abierto = float(mi.group(1))
            continue
        mf = RE_FIN.search(linea)
        if mf and abierto is not None:
            silencios.append((max(0.0, abierto), float(mf.group(1))))
            abierto = None
    if abierto is not None:
        silencios.append((max(0.0, abierto), None))
    return silencios


def hay_voz(desde, hasta, segmentos, margen=0.15):
    """¿Se pisa este tramo con algun segmento de voz de la transcripcion?

    El margen existe porque Whisper marca el inicio de la palabra, no el de la respiracion previa.
    Sin el, el corte se come el primer fonema y queda 'ola' en vez de 'hola'.
    """
    for s in segmentos:
        ini = float(s.get('desde', s.get('start', 0))) - margen
        fin = float(s.get('hasta', s.get('end', 0))) + margen
        if fin > desde and ini < hasta:
            return True
    return False


def _fin_voz_antes(t, segmentos):
    """Donde termina la ultima voz que termina antes (o justo en) t. 0 si no hay ninguna."""
    fines = [float(s.get('hasta', s.get('end', 0))) for s in segmentos
             if float(s.get('hasta', s.get('end', 0))) <= t + 0.001]
    return max(fines) if fines else 0.0


def _ini_voz_despues(t, segmentos):
    """Donde empieza la primera voz que empieza despues (o justo en) t. Infinito si no hay."""
    inicios = [float(s.get('desde', s.get('start', 0))) for s in segmentos
               if float(s.get('desde', s.get('start', 0))) >= t - 0.001]
    return min(inicios) if inicios else float('inf')


def decidir_cortes(silencios, segmentos, duracion, umbral_s=0.7, respiro_s=0.15):
    """Decide QUE TRAMOS SE QUEDAN en el video final.

    Recibe:
      silencios  -- [(desde, hasta|None),...] de parsear_silencedetect()
      segmentos  -- [{'desde': s, 'hasta': s, 'texto': str},...] de la transcripcion
      duracion   -- duracion total del video en segundos
      umbral_s   -- un silencio mas corto que esto no se toca
      respiro_s  -- cuanto silencio se deja a cada lado de un corte

    Devuelve [(desde, hasta),...]: los tramos que SE QUEDAN, en orden y sin superponerse.

    LA POLITICA, decidida con el usuario el 2026-08-15:

      1. RESPIRO de 0,15 s a cada lado. Cortar seco da el video mas corto posible y suena
         atropellado, como si le faltaran pedazos.
      2. SILENCIO LARGO (>= 10 s, del tipo "me fui a buscar algo"): se corta pero se deja una
         PAUSA MARCADA de 0,6 s. Se evaluo acelerarlo en vez de cortarlo y se descarto: obliga a
         partir el video en tramos con velocidades distintas y volver a pegarlos, que es la forma
         mas comun de desincronizar el audio, a cambio de un detalle que en un screencast casi no
         se nota. El paso 'velocidad' del guion queda disponible por si algun dia se quiere.
      3. LA COLA DEL FINAL se corta entera: es tiempo muerto despues de haber terminado de hablar.
         El silencio del PRINCIPIO se trata como cualquier otro (a veces es la intro).

    Nunca se corta donde hay voz: aunque silencedetect diga silencio, si la transcripcion pone una
    palabra ahi, gana la transcripcion. Un silencio acustico con voz encima es una voz baja, y
    cortarla se come una palabra entera.
    """
    LARGO_S = 10.0        # de aca en adelante, "se fue a buscar algo"
    PAUSA_LARGA_S = 0.6   # lo que queda de un silencio largo: se nota que hubo un corte

    # Los silencios se ordenan y se recortan a algo que valga la pena sacar.
    a_sacar = []
    for desde, hasta in sorted(silencios, key=lambda s: s[0]):
        fin = duracion if hasta is None else min(float(hasta), duracion)
        ini = max(0.0, float(desde))
        if fin - ini < umbral_s:
            continue

        # EL RESPIRO SE APLICA RECORTANDO EL SILENCIO CONTRA LA VOZ, no descartandolo.
        # Primera version de esto: si algun segmento de voz se pisaba con el silencio, se
        # descartaba el silencio entero. Con el margen de 0,15 s, un segmento que TERMINA justo
        # donde arranca el silencio (lo normal: se deja de hablar y empieza la pausa) contaba como
        # pisada, y el silencio de 12 segundos no se cortaba nunca. Lo agarro la prueba con
        # numeros a mano antes de tocar un solo video.
        arranca_el_video = ini <= 0.05
        ini = max(ini, _fin_voz_antes(ini, segmentos) + respiro_s)
        fin = min(fin, _ini_voz_despues(fin, segmentos) - respiro_s)
        # Si el silencio es el arranque del video, se saca desde 0: no hay nada antes que empalmar
        # y el respiro dejaria un parpadeo de 0,15 s antes de que empiece todo. Es el espejo de la
        # cola del final. (Salio de la prueba con numeros a mano: el primer tramo daba (0, 0.15).)
        if arranca_el_video:
            ini = 0.0
        if fin - ini < 0.05:
            continue

        if fin >= duracion - 0.05:
            # La cola: todo lo que sigue al ultimo sonido se va. No hay nada despues que empalmar.
            a_sacar.append((ini, duracion))
            continue

        if (fin - ini) >= LARGO_S:
            # Se deja una pausa marcada justo antes de que vuelva a hablar: se lee como una
            # edicion hecha a proposito y no como un salto.
            fin = fin - PAUSA_LARGA_S
        if fin - ini > 0.05:
            a_sacar.append((ini, fin))

    # De "lo que se saca" a "lo que se queda": el complemento sobre la duracion total.
    tramos = []
    cursor = 0.0
    for ini, fin in a_sacar:
        if ini > cursor + 0.05:
            tramos.append((round(cursor, 3), round(ini, 3)))
        cursor = max(cursor, fin)
    if duracion - cursor > 0.05:
        tramos.append((round(cursor, 3), round(duracion, 3)))
    return tramos


def tramos_a_guion(tramos):
    """Envuelve los tramos en el paso 'cortar' que entiende editor_guion.py."""
    return {'tipo': 'cortar', 'tramos': [{'desde_s': round(a, 3), 'hasta_s': round(b, 3)} for a, b in tramos]}


def _main(argv):
    """Uso: editor_silencios.py <salida-silencedetect.txt> <segmentos.json> <duracion>"""
    if len(argv) < 4:
        sys.stderr.write(_main.__doc__ + '\n')
        return 64
    with open(argv[1], encoding='utf-8') as f:
        silencios = parsear_silencedetect(f.read())
    with open(argv[2], encoding='utf-8') as f:
        segmentos = json.load(f).get('segmentos', [])
    tramos = decidir_cortes(silencios, segmentos, float(argv[3]))
    print(json.dumps(tramos_a_guion(tramos), ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(_main(sys.argv))
