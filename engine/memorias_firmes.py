#!/usr/bin/env python3
"""memorias_firmes.py -- filtra el indice de memorias dejando solo las que Mentis puede creer.

Regla 5 del learning loop: una memoria recien destilada nace PROVISIONAL y no influye en nada
hasta confirmarse. Este filtro es donde esa regla se vuelve efectiva -- sin el, una observacion
suelta seguiria pesando igual que un hecho establecido.

Criterio:
    estado: firme        -> entra
    estado: provisional  -> NO entra (existe, se puede ver y confirmar, pero no influye)
    sin campo 'estado'   -> entra (memorias anteriores a este sistema; son las que el usuario ya
                            venia usando y no corresponde degradarlas de golpe)
"""
import argparse
import os
import re
import sys

RE_LINEA = re.compile(r"^- \[([a-z0-9_-]+)\]")


def estado_de(directorio, slug):
    ruta = os.path.join(directorio, slug + ".md")
    if not os.path.exists(ruta):
        # Una linea del indice sin archivo detras es basura del indice, no una memoria.
        return None
    # Se leen las lineas a mano en vez de iterar el archivo: mezclar `for linea in f` con
    # f.tell() lanza OSError en Python 3 ("telling position disabled by next() call"), y el
    # except devolvia "firme" para TODAS -- el filtro dejaba pasar hasta las provisionales,
    # que es exactamente lo que tenia que impedir. Un error que se disfrazaba de "todo bien".
    try:
        with open(ruta, "r", encoding="utf-8", errors="replace") as f:
            lineas = f.read().split("\n")
    except OSError:
        return "firme"      # no poder leerla no es motivo para ocultarla
    if not lineas or lineas[0].strip() != "---":
        return "firme"      # sin frontmatter = anterior a este sistema
    for linea in lineas[1:]:
        if linea.strip() == "---":
            break           # se termino el frontmatter y no habia campo 'estado'
        if linea.startswith("estado:"):
            return linea.split(":", 1)[1].strip()
    return "firme"          # sin campo estado = anterior a este sistema


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indice", required=True)
    ap.add_argument("--memorias", required=True)
    args = ap.parse_args()

    if not os.path.exists(args.indice):
        return 1

    with open(args.indice, "r", encoding="utf-8", errors="replace") as f:
        lineas = f.readlines()

    salida, ocultas = [], 0
    for linea in lineas:
        m = RE_LINEA.match(linea)
        if not m:
            salida.append(linea)          # encabezados y texto suelto del indice se conservan
            continue
        est = estado_de(args.memorias, m.group(1))
        if est is None:
            continue                      # linea huerfana
        if est == "provisional":
            ocultas += 1
            continue
        salida.append(linea)

    sys.stdout.write("".join(salida))
    if ocultas:
        # Que Mentis SEPA que hay algo en cuarentena, sin decirle que dice: si supiera el
        # contenido, la regla no serviria de nada.
        sys.stdout.write("\n(%d observacion(es) provisional(es) sin confirmar todavia -- "
                         "no se toman como ciertas)\n" % ocultas)
    return 0


if __name__ == "__main__":
    sys.exit(main())
