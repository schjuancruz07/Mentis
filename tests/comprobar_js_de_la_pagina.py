#!/usr/bin/env python3
"""Extrae el JavaScript de la pagina del celular y lo deja en un archivo para validarlo.

POR QUE EXISTE (2026-08-06): la pagina se sirve desde un string de Python en nv_web_server.py.
Ese string estuvo sin el prefijo r, asi que Python se comia los '\\n' escritos PARA JavaScript y
los convertia en saltos de linea de verdad -- adentro de una cadena entre comillas simples, que en
JS no admite saltos literales. Resultado: SyntaxError, y un SyntaxError no rompe una funcion, corta
el script ENTERO. La pagina cargaba con su HTML y su CSS perfectos y no se inicializaba nada: en el
celular se veian dos botones y abajo negro.

Nada lo detectaba porque el HTML estaba bien formado y el servidor respondia 200. Por eso el test
no mira el codigo fuente: extrae el JS TAL COMO LLEGA AL NAVEGADOR y lo hace parsear de verdad.
"""
import io
import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "engine"))

destino = sys.argv[1]

import nv_web_server  # noqa: E402

pagina = nv_web_server.PAGINA
bloques = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", pagina, re.S)
if not bloques:
    sys.stderr.write("no encontre ningun <script> embebido en la pagina\n")
    sys.exit(2)

with io.open(destino, "w", encoding="utf-8") as f:
    # La envoltura es ASYNC a proposito: la pagina usa `await import(...)` en el nivel superior del
    # script, que es valido en un <script type="module"> del navegador pero no dentro de una
    # funcion comun. Con la envoltura equivocada, el test fallaba por la envoltura y no por la
    # pagina -- un falso positivo que habria mandado a buscar un bug inexistente.
    # No se ejecuta nada: a `node --check` solo le importa que PARSEE.
    f.write("(async function(){\n")
    for b in bloques:
        f.write(b)
        f.write("\n")
    f.write("\n})();\n")

print("%d bloque(s) de script, %d caracteres" % (len(bloques), sum(len(b) for b in bloques)))
