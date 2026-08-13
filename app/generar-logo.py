#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generar-logo.py -- construye el isotipo "M" de Mentis y el icono de la app.

VUELTA A LA M (decisión del usuario, 2026-08-12). Ese mismo día se probó un isotipo de planeta con
anillo y se descartó: vuelve la variante "M3 Editorial", una M serif itálica de alto contraste.

POR QUE NO ES TEXTO: en la guía de identidad esa M estaba escrita como un <text> de SVG con
font-family="Playfair Display" -- y eso NO es un logo, es una instrucción para que la máquina que
lo abra use una fuente que puede no tener instalada. En cualquier computadora sin Playfair se veía
una M cualquiera. Este script la convierte en TRAZO, que se ve igual en todos lados.

EL SEGUNDO PROBLEMA, QUE NO SE VE HASTA QUE ES TARDE: una serif de alto contraste tiene trazos
finísimos. A 16 px -- el tamaño real del ícono en la barra de tareas -- esos trazos caen por
debajo de un píxel y desaparecen: la M se ve partida o directamente sucia. Por eso los tamaños
chicos se dibujan con un engrosado que compensa. Es la misma M, no otra: sólo se le devuelve el
peso que el tamaño le quita. Los grandes NO se engrosan, porque ahí el trazo fino es justamente
lo que le da la elegancia.

DOS VARIANTES, UNA POR TEMA: la baldosa terracota con la M crema va con el tema claro; la baldosa
carbón con filo terracota y la M terracota, con el oscuro. Un ícono terracota sobre una barra de
tareas oscura se ve como un parche pegado.

SE CORRE A MANO:  python3 app/generar-logo.py
"""

import io
import os
import sys

# Rutas en formato Windows a propósito: el python de la Store no entiende rutas MSYS (/c/...).
AQUI = os.path.dirname(os.path.abspath(__file__))
FUENTES = os.path.join(AQUI, 'renderer', 'assets', 'fonts')
DESTINO = os.path.join(AQUI, 'renderer', 'assets')
WOFF2_M = os.path.join(FUENTES, 'playfair-display-800-italic-latin.woff2')

# Los colores de la marca.
CRAIL = (217, 119, 87)        # #d97757 -- acento del tema oscuro
JAPONICA = (193, 95, 60)      # #c15f3c -- acento del tema claro
CREMA = (250, 249, 245)       # #faf9f5
CARBON = (31, 30, 29)         # #1f1e1d

VARIANTES = {
    'claro':  {'fondo': (JAPONICA, CRAIL), 'letra': CREMA, 'borde': None},
    'oscuro': {'fondo': (CARBON, (20, 20, 19)), 'letra': CRAIL, 'borde': CRAIL},
}

# Tamaños que Windows busca dentro de un.ico. Si falta el de 16, el sistema reduce el de 256 por
# su cuenta y el resultado es una mancha: por eso se dibuja cada uno a su tamaño real.
TAMANOS = [16, 24, 32, 48, 64, 128, 256]
# Debajo de este tamaño la serif necesita ayuda. Medido mirando el resultado, no adivinado.
TAMANOS_ENGROSADOS = {16: 0.055, 24: 0.040, 32: 0.030, 48: 0.015}


def cargar_fuente_ttf():
    """Devuelve Playfair como TTF en memoria. Pillow no lee woff2; fontTools sí.

    HACEN FALTA DOS PAQUETES, NO UNO: fontTools para abrir la fuente, y **brotli** para
    descomprimir el woff2 -- que es el formato en el que están todas las fuentes de Mentis.
    El 2026-08-12 desinstalé brotli creyendo que sólo lo usaba fontTools "por las dudas", y este
    script dejó de funcionar. El aviso de abajo existe para que la próxima vez el error diga qué
    instalar en vez de un ImportError crudo tres niveles adentro de una librería.
    """
    try:
        import brotli  # noqa: F401
    except ImportError:
        sys.exit('falta el paquete brotli, que fontTools necesita para leer.woff2.\n'
                 'Instalalo con:  python3 -m pip install brotli fonttools')
    from fontTools.ttLib import TTFont
    f = TTFont(WOFF2_M)
    buf = io.BytesIO()
    f.save(buf)
    buf.seek(0)
    return buf.read(), f


def escribir_svg(ttfont):
    """Saca el contorno de la 'M' de la fuente y lo escribe como path SVG."""
    from fontTools.pens.svgPathPen import SVGPathPen

    glyphset = ttfont.getGlyphSet()
    nombre = ttfont.getBestCmap()[ord('M')]
    pen = SVGPathPen(glyphset)
    glyphset[nombre].draw(pen)
    d = pen.getCommands()

    upem = ttfont['head'].unitsPerEm
    ancho = glyphset[nombre].width
    ty = ttfont['hhea'].ascent

    # Las fuentes crecen hacia ARRIBA desde la línea de base; SVG crece hacia abajo. Sin este
    # volteo la M sale cabeza abajo -- es el error clásico de exportar glifos a SVG.
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {ancho} {upem}" role="img" aria-label="Mentis">
  <title>Mentis</title>
  <!-- Isotipo M3 Editorial. Es un TRAZO, no texto: no depende de tener Playfair Display
       instalada. Generado por app/generar-logo.py a partir de Playfair Display Italic 800 (OFL). -->
  <path transform="translate(0, {ty}) scale(1, -1)" d="{d}" fill="currentColor"/>
</svg>
'''
    ruta = os.path.join(DESTINO, 'mentis-m.svg')
    io.open(ruta, 'w', encoding='utf-8').write(svg)
    return ruta, len(d)


def squircle(tam, variante='claro', radio_rel=0.225):
    """El fondo redondeado del ícono, con degradado como en la guía de identidad."""
    from PIL import Image, ImageDraw

    # Se dibuja al cuádruple y se reduce: única forma barata de que la curva de la esquina no
    # salga dentada a 16 px.
    f = 4
    desde, hasta = VARIANTES[variante]['fondo']
    g = Image.new('RGBA', (tam * f, tam * f), (0, 0, 0, 0))
    grad = Image.new('RGBA', (tam * f, tam * f))
    px = grad.load()
    n = tam * f
    for y in range(n):
        for x in range(n):
            t = (x + y) / (2.0 * (n - 1))   # degradado diagonal 135°, como la guía
            px[x, y] = (int(desde[0] + (hasta[0] - desde[0]) * t),
                        int(desde[1] + (hasta[1] - desde[1]) * t),
                        int(desde[2] + (hasta[2] - desde[2]) * t), 255)
    mascara = Image.new('L', (n, n), 0)
    ImageDraw.Draw(mascara).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * radio_rel), fill=255)
    g.paste(grad, (0, 0), mascara)
    # La variante oscura lleva un filo terracota: sin él, una baldosa casi negra sobre una barra de
    # tareas casi negra desaparece y sólo se ve la M flotando.
    borde = VARIANTES[variante]['borde']
    if borde:
        ImageDraw.Draw(g).rounded_rectangle([1, 1, n - 2, n - 2], radius=int(n * radio_rel),
                                            outline=borde + (255,), width=max(2, int(n * 0.012)))
    return g.resize((tam, tam), Image.LANCZOS)


def dibujar_icono(tam, ttf_bytes, variante='claro'):
    from PIL import Image, ImageDraw, ImageFont

    fondo = squircle(tam, variante)
    f = 4
    capa = Image.new('RGBA', (tam * f, tam * f), (0, 0, 0, 0))
    draw = ImageDraw.Draw(capa)

    # 0.72 del alto: el aire de margen que tiene el squircle de la guía.
    #
    # EL ENGROSADO SE DESCUENTA DEL TAMAÑO, no se suma encima: stroke_width agranda la letra hacia
    # afuera en las dos direcciones, así que a 16 px la M engrosada terminaba tocando los bordes.
    # Se le achica el cuerpo lo mismo que le va a crecer el trazo (el 1.6 es empírico: crece más
    # en vertical por la inclinación de la itálica).
    engrosado = TAMANOS_ENGROSADOS.get(tam, 0)
    puntos = int(tam * f * (0.72 - engrosado * 1.6))
    fuente = ImageFont.truetype(io.BytesIO(ttf_bytes), puntos)
    ancho_trazo = int(tam * f * engrosado)

    # anchor='mm' centra por el medio real del glifo. Sin esto la M itálica queda corrida a la
    # izquierda, porque su caja incluye el espacio de la inclinación.
    tinta = VARIANTES[variante]['letra']
    draw.text((tam * f / 2, tam * f / 2), 'M', font=fuente, fill=tinta + (255,),
              anchor='mm', stroke_width=ancho_trazo, stroke_fill=tinta + (255,))

    letra = capa.resize((tam, tam), Image.LANCZOS)
    fondo.alpha_composite(letra)
    return fondo


def main():
    if not os.path.exists(WOFF2_M):
        sys.exit(f'falta {WOFF2_M} -- corré antes: node app/bajar-fuentes.js')

    ttf_bytes, ttfont = cargar_fuente_ttf()
    ruta_svg, largo = escribir_svg(ttfont)
    print(f'SVG vectorial: {ruta_svg}  ({largo} caracteres de trazo, cero dependencia de fuentes)')

    for variante in ('claro', 'oscuro'):
        suf = '' if variante == 'claro' else '-oscuro'
        imgs = [dibujar_icono(t, ttf_bytes, variante) for t in TAMANOS]
        ruta_ico = os.path.join(DESTINO, f'mentis-app{suf}.ico')
        # Se pasan las imágenes ya dibujadas una por una: si Pillow generara los tamaños solo,
        # reduciría el de 256 y se perdería el engrosado de los chicos, que es todo el punto.
        imgs[-1].save(ruta_ico, format='ICO', sizes=[(t, t) for t in TAMANOS], append_images=imgs[:-1])
        imgs[-1].save(os.path.join(DESTINO, f'mentis-app{suf}-256.png'))
        # El de 16 va aparte y NO se saca del.ico: Windows elige mal el tamaño cuando usa un.ico
        # multi-resolución para la bandeja (fix del 2026-07-15).
        imgs[TAMANOS.index(16)].save(os.path.join(DESTINO, f'mentis-app{suf}-16.png'))
        print(f'  {variante:7s} -> mentis-app{suf}.ico ({len(TAMANOS)} tamaños)')


if __name__ == '__main__':
    main()
