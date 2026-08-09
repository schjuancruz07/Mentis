#!/usr/bin/env python3
"""memoria_estado.py -- edita el frontmatter de una memoria sin tocar su contenido.

Existe porque el ciclo provisional -> firme necesita escribir tres campos nuevos (`estado`,
`visto`, `origen`) en archivos que ya existen, y hacerlo con sed sobre YAML es la clase de cosa
que funciona hasta que un valor trae un ':' o una tilde.

Las memorias viejas (anteriores a este sistema) no tienen `estado`. No se les inventa uno: se
las trata como firmes, que es lo que venian siendo. Solo lo nuevo pasa por la cuarentena.
"""
import argparse
import os
import sys


def leer(ruta):
    # errors="replace", leccion de ERR-080: un byte raro en una memoria vieja no puede romper
    # el ciclo de aprendizaje entero.
    with open(ruta, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def partir(texto):
    """Devuelve (lineas_frontmatter, cuerpo). Si no hay frontmatter, ([], texto)."""
    if not texto.startswith("---"):
        return [], texto
    fin = texto.find("\n---", 3)
    if fin == -1:
        return [], texto
    cabecera = texto[3:fin].strip("\n").split("\n")
    cuerpo = texto[fin + 4:].lstrip("\n")
    return cabecera, cuerpo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--archivo", required=True)
    ap.add_argument("--estado", choices=["provisional", "firme"])
    ap.add_argument("--visto", type=int)
    ap.add_argument("--origen")
    ap.add_argument("--limitacion", choices=["si", "no"])
    args = ap.parse_args()

    if not os.path.exists(args.archivo):
        print("ERROR: no existe %s" % args.archivo, file=sys.stderr)
        return 1

    cabecera, cuerpo = partir(leer(args.archivo))
    campos, orden = {}, []
    for linea in cabecera:
        if ":" in linea:
            k, v = linea.split(":", 1)
            k = k.strip()
            if k not in campos:
                orden.append(k)
            campos[k] = v.strip()

    for clave, valor in (("estado", args.estado), ("visto", args.visto),
                         ("origen", args.origen), ("limitacion", args.limitacion)):
        if valor is not None:
            if clave not in campos:
                orden.append(clave)
            campos[clave] = str(valor)

    with open(args.archivo, "w", encoding="utf-8") as f:
        f.write("---\n")
        for k in orden:
            f.write("%s: %s\n" % (k, campos[k]))
        f.write("---\n\n")
        f.write(cuerpo.rstrip("\n") + "\n")

    print("%s -> estado=%s visto=%s" % (os.path.basename(args.archivo),
                                        campos.get("estado", "?"), campos.get("visto", "?")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
