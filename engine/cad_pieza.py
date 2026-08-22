# -*- coding: utf-8 -*-
"""Genera piezas para FABRICAR a partir de una descripcion, y las exporta en STEP.

POR QUE ESTO Y NO TripoSR (2026-08-18): lo que Mentis generaba hasta hoy es una malla organica
sacada de una imagen. Se ve bien y no sirve para fabricar: un taller no acepta un.glb, acepta un
STEP -- geometria exacta, no triangulos aproximados. Y una pieza real tiene medidas que se piden,
no que se estiman de una foto.

Aca la pieza se DESCRIBE con numeros (una caja de 80x60x10 con dos agujeros de 5 mm) y sale
exacta. Un ensamblaje es varias piezas, cada una en su archivo, como las manda una fabrica.

Formato de entrada (JSON):
  {
    "unidades": "mm",
    "piezas": [
      {"nombre":"base", "forma":"caja", "x":80, "y":60, "z":10,
       "agujeros":[{"diametro":5, "en":[15,15]}, {"diametro":5, "en":[-15,-15]}],
       "redondeo":2},
      {"nombre":"eje", "forma":"cilindro", "diametro":12, "alto":40}
    ]
  }

Uso:  python3 cad_pieza.py <guion.json> <carpeta_salida>
"""
import io
import json
import os
import sys

for _f in (sys.stdout, sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def _validar(guion):
    """Se valida ANTES de construir nada: un error de medidas descubierto a mitad del ensamblaje
    deja archivos a medias, y con piezas para fabricar eso es peor que no generar nada."""
    problemas = []
    piezas = guion.get("piezas")
    if not isinstance(piezas, list) or not piezas:
        return ["el guion no tiene una lista 'piezas' con al menos una pieza"]
    vistos = set()
    for i, p in enumerate(piezas):
        n = p.get("nombre") or "pieza%d" % (i + 1)
        if n in vistos:
            problemas.append("hay dos piezas con el nombre '%s': se pisarian los archivos" % n)
        vistos.add(n)
        forma = p.get("forma")
        if forma == "caja":
            faltan = [k for k in ("x", "y", "z") if not isinstance(p.get(k), (int, float)) or p.get(k) <= 0]
            if faltan:
                problemas.append("'%s' es una caja y le faltan medidas positivas: %s" % (n, ", ".join(faltan)))
        elif forma == "cilindro":
            if not isinstance(p.get("diametro"), (int, float)) or p["diametro"] <= 0:
                problemas.append("'%s' es un cilindro sin diametro valido" % n)
            if not isinstance(p.get("alto"), (int, float)) or p["alto"] <= 0:
                problemas.append("'%s' es un cilindro sin alto valido" % n)
        else:
            problemas.append("'%s' tiene forma '%s', que no conozco (uso: caja, cilindro)" % (n, forma))
        for a in p.get("agujeros", []) or []:
            d = a.get("diametro")
            if not isinstance(d, (int, float)) or d <= 0:
                problemas.append("'%s' tiene un agujero sin diametro valido" % n)
            elif forma == "caja" and d >= min(p.get("x", 0), p.get("y", 0)):
                problemas.append("'%s': el agujero de %s mm no entra en una pieza de %sx%s"
                                 % (n, d, p.get("x"), p.get("y")))
    return problemas


def construir(guion, salida):
    from build123d import (BuildPart, BuildSketch, Box, Cylinder, Circle, Locations,
                           extrude, Mode, export_step, export_stl, fillet)
    os.makedirs(salida, exist_ok=True)
    hechas = []
    for i, p in enumerate(guion["piezas"]):
        nombre = p.get("nombre") or "pieza%d" % (i + 1)
        with BuildPart() as bp:
            if p["forma"] == "caja":
                Box(float(p["x"]), float(p["y"]), float(p["z"]))
                r = p.get("redondeo")
                if isinstance(r, (int, float)) and r > 0:
                    # Solo las aristas verticales: redondear todo deja una pieza con forma de jabon
                    # y en general no es lo que se quiere de una pieza mecanica.
                    try:
                        fillet(bp.edges().filter_by(lambda e: True).group_by()[0], radius=float(r))
                    except Exception:
                        pass
            else:
                Cylinder(radius=float(p["diametro"]) / 2.0, height=float(p["alto"]))
            for a in p.get("agujeros", []) or []:
                en = a.get("en", [0, 0])
                with BuildSketch():
                    with Locations((float(en[0]), float(en[1]))):
                        Circle(float(a["diametro"]) / 2.0)
                extrude(amount=float(p.get("z", p.get("alto", 10))) * 2, both=True, mode=Mode.SUBTRACT)
        step = os.path.join(salida, nombre + ".step")
        stl = os.path.join(salida, nombre + ".stl")
        export_step(bp.part, step)
        export_stl(bp.part, stl)
        hechas.append({"nombre": nombre, "step": step, "stl": stl,
                       "volumen": round(float(bp.part.volume), 3)})
    return hechas


def main():
    if len(sys.argv) < 3:
        print("uso: cad_pieza.py <guion.json> <carpeta_salida>", file=sys.stderr)
        return 2
    guion = json.load(io.open(sys.argv[1], encoding="utf-8"))
    problemas = _validar(guion)
    if problemas:
        print("El guion tiene problemas y no genere nada:")
        for p in problemas:
            print("  - " + p)
        return 3
    try:
        hechas = construir(guion, sys.argv[2])
    except ImportError:
        print("Falta build123d. Instalalo con:  python3 -m pip install build123d", file=sys.stderr)
        return 4
    u = guion.get("unidades", "mm")
    print("Genere %d pieza(s) en %s:" % (len(hechas), u))
    for h in hechas:
        print("  - %s  volumen %s %s3" % (h["nombre"], h["volumen"], u))
        print("      STEP (para el taller): %s" % h["step"])
        print("      STL  (para imprimir):  %s" % h["stl"])
    print("")
    print("El STEP es el que se manda a fabricar: lleva la geometria exacta, no una malla.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
