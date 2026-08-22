# -*- coding: utf-8 -*-
"""Cuenta cuantos identificadores de la fuente aparecen en el entregable.

POR QUE (2026-08-20): la guarda del entregable miraba el TAMAÑO. Presupuestos dejo un archivo de
222 bytes -- por encima del umbral de 200 -- que no mencionaba ninguna de las tres consultas, y la
corrida se dio por buena. El peso de un archivo no dice nada sobre si el trabajo esta hecho.

Uso:  depto_cobertura.py <fuente.json> <entregable> <lista> <campo>
Imprime: "<cuantos aparecen> <cuantos hay>"
"""
import io
import json
import sys

for _f in (sys.stdout, sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def main():
    if len(sys.argv) < 5:
        print("0 0")
        return 2
    fuente, entregable, lista, campo = sys.argv[1:5]
    try:
        datos = json.load(io.open(fuente, encoding="utf-8"))
        texto = io.open(entregable, encoding="utf-8", errors="replace").read()
    except Exception:
        print("0 0")
        return 1
    items = datos.get(lista) or []
    ids = [str(it.get(campo, "")) for it in items if isinstance(it, dict) and it.get(campo)]
    presentes = [i for i in ids if i in texto]
    print("%d %d" % (len(presentes), len(ids)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
