#!/usr/bin/env python3
"""archivos_pedidos.py -- que archivos NOMBRA una tarea como lugar donde dejar el resultado.

    archivos_pedidos.py            (el texto de la tarea entra por la variable NVA_TAREA)

Imprime las rutas encontradas, separadas por espacios. Si no hay ninguna, no imprime nada.

POR QUE EXISTE (2026-08-21): habia una guarda para "la tarea pide un documento y todavia no
generaste ninguno", pero solo miraba la herramienta 'gen'. Cuando el pedido nombra una RUTA
concreta -- "dejá el informe en 'docs/idea6-habilidades.md'" -- el camino es 'write', y ahi no
habia nada mirando. Paso de verdad en la primera tarea de la Fase 2: el turno buscó bien, encontro
lo que habia que encontrar, y CONTESTO POR CHAT sin escribir el archivo. Ninguna guarda lo noto --
la de completitud no aplica porque no afirmo que nada funcionara, y la de archivos-nombrados
tampoco porque la respuesta no menciona ningun archivo. El hueco es justo ese: no decir nada.

POR QUE UN ARCHIVO Y NO UN python3 -c ADENTRO DEL BASH: la primera version iba embebida, y las
barras invertidas de la expresion regular se rompieron al escribir el archivo -- el bash quedo con
un error de sintaxis. Es exactamente lo que ya documenta tavily_buscar.py sobre si mismo. Un
archivo propio se puede correr a mano y se puede leer.

SOLO ENTRE COMILLAS, a proposito: "docs/algo.md" es un pedido; "mira nv-agent.sh" es una
referencia a un archivo que ya existe. Sin esa condicion, cualquier mencion de un archivo se
convertiria en una exigencia de crearlo.
"""
import os
import re
import sys

for _f in (sys.stdout, sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Extensiones de cosas que un turno DEJA ESCRITAS. Nada de imagenes ni binarios: esos salen por
# 'gen' y ya tienen su propia guarda.
EXT = "md|txt|json|csv|html|py|sh|js|css|yml|yaml"
COMILLAS = "'\"“”‘’`"
RUTA = re.compile(
    "[" + COMILLAS + "]([\\w./-]+\\.(?:" + EXT + "))[" + COMILLAS + "]"
)


def buscar(texto):
    vistos, salida = set(), []
    for m in RUTA.finditer(texto or ""):
        ruta = m.group(1)
        # Una ruta que arranca con guion es una bandera de linea de comandos mal citada.
        if ruta.startswith("-") or ruta in vistos:
            continue
        vistos.add(ruta)
        salida.append(ruta)
    # Tope de 4: si un pedido nombra veinte archivos, la nota al modelo seria mas larga que la
    # tarea. Con los primeros alcanza para que entienda que tiene que escribirlos.
    return salida[:4]


# El prompt que recibe el agente trae TODO: la persona, la memoria, el historial de la charla y
# recién al final el pedido de ahora. Buscar rutas en todo eso devuelve los archivos de tareas
# ANTERIORES -- y como esos ya existen, la guarda no avisa nunca de lo que falta hoy.
#
# Paso de verdad (2026-08-21): se pidió modificar el Directorio y crear
# "tests/test-directorio-modos.sh"; la guarda reportó los informes de las dos tareas previas y se
# quedó tranquila. El turno cerró sin escribir una línea.
MARCADORES = ("MENSAJE NUEVO DE USUARIO:", "PEDIDO DE USUARIO:", "MENSAJE NUEVO:")


def solo_el_pedido(texto):
    """Se queda con lo que viene DESPUÉS del último marcador de mensaje nuevo."""
    corte = -1
    for m in MARCADORES:
        i = texto.rfind(m)
        if i > corte:
            corte = i + len(m)
    return texto[corte:] if corte >= 0 else texto


def main():
    texto = os.environ.get("NVA_TAREA", "")
    if not texto and len(sys.argv) > 1:
        texto = sys.argv[1]
    texto = solo_el_pedido(texto)
    encontrados = buscar(texto)
    if encontrados:
        sys.stdout.write(" ".join(encontrados) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
