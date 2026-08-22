# -*- coding: utf-8 -*-
"""Analiza un modelo 3D y dice si sirve para FABRICAR, no solo para mirarlo.

POR QUE EXISTE (2026-08-18): Mentis genera modelos con TripoSR a partir de una imagen. Eso da una
malla organica: se ve bien en pantalla y no dice NADA sobre si se puede imprimir o mandar a un
taller. Un modelo que se ve perfecto puede tener la malla abierta, las normales al reves o estar
hecho de veinte pedazos sueltos, y eso recien se descubre cuando la impresora falla.

Lo que se mide es lo que decide si una pieza es fabricable:
  - cerrada (watertight): si tiene agujeros, no encierra un volumen y no hay nada que imprimir.
  - volumen positivo: si da negativo, las normales apuntan para adentro.
  - un solo cuerpo: veinte pedazos sueltos no son una pieza, son veinte.
  - manifold: aristas compartidas por mas de dos caras rompen cualquier laminador.
  - tamaño real: sin escala conocida, "grande" no quiere decir nada.

Uso:  python3 modelo3d_analizar.py <archivo> [--json]
"""
import json
import os
import sys

# Sin esto, python en Windows escribe con el codepage de la consola (cp1252 aca) y cualquier
# acento sale roto. Es la misma razon por la que nv-agent.sh exporta PYTHONIOENCODING.
for _f in (sys.stdout, sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

def _aristas_abiertas(m):
    """Aristas de borde: las que pertenecen a UNA sola cara.

    No se usa m.edges_open: en trimesh 5 devolvio 0 sobre una malla a la que le falta una cara
    (probado). Contar a mano es de una linea y no depende de que la propiedad signifique lo
    mismo entre versiones -- que es justo lo que rompe callado al actualizar.
    """
    from collections import Counter
    try:
        c = Counter(tuple(e) for e in m.edges_sorted)
        return int(sum(1 for n in c.values() if n == 1))
    except Exception:
        return 0

def analizar(ruta):
    import trimesh
    escena = trimesh.load(ruta, force="scene")
    mallas = [g for g in escena.geometry.values() if hasattr(g, "faces")]
    if not mallas:
        return {"error": "el archivo no tiene ninguna malla adentro"}

    m = trimesh.util.concatenate(mallas) if len(mallas) > 1 else mallas[0]
    ext = m.bounding_box.extents
    cuerpos = m.split(only_watertight=False)

    r = {
        "archivo": os.path.basename(ruta),
        "piezas_en_el_archivo": len(mallas),
        "cuerpos_sueltos": len(cuerpos),
        "vertices": int(len(m.vertices)),
        "caras": int(len(m.faces)),
        "tamano": {"x": round(float(ext[0]), 4), "y": round(float(ext[1]), 4), "z": round(float(ext[2]), 4)},
        "cerrada": bool(m.is_watertight),
        "volumen": round(float(m.volume), 6) if m.is_watertight else None,
        "area": round(float(m.area), 4),
        "manifold": bool(m.is_winding_consistent),
        "aristas_abiertas": _aristas_abiertas(m),
    }

    problemas = []
    if not r["cerrada"]:
        problemas.append("la malla NO esta cerrada (%d aristas abiertas): no encierra un volumen, "
                         "asi que no se puede imprimir ni mecanizar tal como esta" % r["aristas_abiertas"])
    if r["volumen"] is not None and r["volumen"] <= 0:
        problemas.append("el volumen da %s: las normales apuntan para adentro, la pieza esta dada vuelta"
                         % r["volumen"])
    if not r["manifold"]:
        problemas.append("las caras no tienen orientacion consistente: la mayoria de los laminadores "
                         "van a rechazarla o rellenar cualquier cosa")
    if r["cuerpos_sueltos"] > 1:
        problemas.append("son %d cuerpos sueltos, no una pieza: para fabricar hay que separarlos en "
                         "archivos distintos o unirlos" % r["cuerpos_sueltos"])
    if min(ext) <= 0:
        problemas.append("una de las dimensiones es cero: la pieza es plana y no tiene espesor")

    r["problemas"] = problemas
    r["fabricable"] = len(problemas) == 0
    # La escala NO se puede deducir de la geometria: un cubo de lado 1 puede ser 1 mm o 1 m. Se dice
    # explicitamente en vez de inventar milimetros, que es justo el numero que arruinaria una pieza.
    r["nota_escala"] = ("El tamaño esta en las unidades del archivo, que casi nunca vienen declaradas. "
                        "Antes de mandar a fabricar hay que fijar la escala a mano.")
    return r

def texto(r):
    if "error" in r:
        return "No pude analizarlo: " + r["error"]
    L = []
    L.append("Modelo: %s" % r["archivo"])
    t = r["tamano"]
    L.append("  Tamaño: %s x %s x %s (unidades del archivo)" % (t["x"], t["y"], t["z"]))
    L.append("  Malla: %d vertices, %d caras, %d cuerpo(s)" % (r["vertices"], r["caras"], r["cuerpos_sueltos"]))
    if r["volumen"] is not None:
        L.append("  Volumen: %s   Area: %s" % (r["volumen"], r["area"]))
    else:
        L.append("  Volumen: no se puede calcular (la malla esta abierta)   Area: %s" % r["area"])
    L.append("")
    if r["fabricable"]:
        L.append("SIRVE PARA FABRICAR: la malla esta cerrada, es un solo cuerpo y las caras estan bien orientadas.")
    else:
        L.append("NO SIRVE PARA FABRICAR TODAVIA:")
        for p in r["problemas"]:
            L.append("  - " + p)
    L.append("")
    L.append(r["nota_escala"])
    return "\n".join(L)

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--json"]
    if not args:
        print("uso: modelo3d_analizar.py <archivo.glb|obj|stl> [--json]", file=sys.stderr)
        sys.exit(2)
    try:
        res = analizar(args[0])
    except Exception as e:
        print("No pude analizarlo: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)
    print(json.dumps(res, ensure_ascii=False, indent=2) if "--json" in sys.argv else texto(res))
    sys.exit(0 if res.get("fabricable") else 3)
