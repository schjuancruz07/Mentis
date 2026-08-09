#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""resumir_bench.py -- convierte los JSONL de la medición en las tablas del informe.

POR QUE DEDUPLICA
    Porque la primera corrida del 2026-08-02 escribió casos repetidos: la marca de reanudación de
    bench-roles.sh buscaba la cadena '"clave":"...' y json.dumps escribe '"clave": "...' -- con un
    espacio. El grep nunca encontraba nada y ningún caso se salteaba. Está arreglado, pero los
    datos ya escritos tienen repetidos, y contar dos veces el mismo caso inflaría el total.
    Se queda con la ULTIMA aparición de cada clave: es la más reciente.

Uso: python3 resumir_bench.py <archivo.jsonl> [--campo bench|rol]
"""
import argparse, json, sys
from collections import OrderedDict


def cargar(ruta):
    filas = OrderedDict()
    with open(ruta, encoding="utf-8") as f:
        for l in f:
            l = l.strip()
            if not l:
                continue
            try:
                d = json.loads(l)
            except Exception:
                continue
            filas[d.get("clave", id(d))] = d
    return list(filas.values())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("archivo")
    p.add_argument("--campo", default="rol", help="rol (bench-roles) o bench (datasets/vision)")
    args = p.parse_args()

    filas = cargar(args.archivo)
    if not filas:
        print("(sin datos)")
        return 0

    grupos = {}
    for d in filas:
        g = d.get(args.campo, "?")
        m = d.get("modelo", "?")
        k = (g, m)
        acc = grupos.setdefault(k, {"ok": 0, "tot": 0, "err": 0, "ms": 0})
        acc["tot"] += 1
        acc["ms"] += d.get("ms", 0)
        if d.get("ok") is None:
            acc["err"] += 1
        elif d.get("ok"):
            acc["ok"] += 1

    ancho = max(len(m) for _, m in grupos) + 2
    actual = None
    for (g, m) in sorted(grupos):
        if g != actual:
            actual = g
            print("\n== %s ==" % g)
            print("%-*s %8s %8s %10s %8s" % (ancho, "MODELO", "ACIERTO", "%", "ms/caso", "ERRORES"))
        a = grupos[(g, m)]
        # Los ERRORES (429, timeout, red) NO son reprobaciones del modelo: salen del denominador.
        # Mezclarlos haría que un mal día del free tier se lea como un modelo malo.
        util = a["tot"] - a["err"]
        pct = (100.0 * a["ok"] / util) if util else 0.0
        print("%-*s %8s %7.1f%% %10d %8d" % (
            ancho, m, "%d/%d" % (a["ok"], util), pct, a["ms"] // max(a["tot"], 1), a["err"]))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
