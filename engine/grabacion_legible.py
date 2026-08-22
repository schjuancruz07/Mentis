# -*- coding: utf-8 -*-
"""grabacion_legible.py <archivo.jsonl> -- convierte una grabacion de acciones en pasos leibles.

POR QUE EXISTE: el jsonl crudo tiene una linea por evento y hasta un minuto de trabajo son cientos.
Lo que sirve -- para una persona y para un modelo -- es la secuencia AGRUPADA: "en tal ventana,
hizo 3 clics y escribio 20 caracteres, despues Enter". Sin agrupar, el modelo que escribe la skill
se ahoga en ruido y termina describiendo el mouse en vez de la tarea.
"""
import io
import json
import sys


def main():
    if len(sys.argv) < 2:
        print("uso: grabacion_legible.py <archivo.jsonl>")
        return 2
    eventos = []
    # utf-8-sig y no utf-8: Add-Content de PowerShell 5.1 escribe un BOM al principio del archivo,
    # y ese BOM se pega a la primera linea. json.loads la rechaza, el try/except la descarta en
    # silencio, y el PRIMER evento de cada grabacion se perdia sin que nada lo dijera.
    with io.open(sys.argv[1], encoding="utf-8-sig", errors="replace") as f:
        for linea in f:
            linea = linea.strip()
            if not linea:
                continue
            try:
                eventos.append(json.loads(linea))
            except Exception:
                continue
    if not eventos:
        print("(la grabacion esta vacia)")
        return 0

    estado = {"paso": 0, "clics": 0, "escrito": 0}
    ventana = None

    def volcar():
        # Los clics y el texto se acumulan y se sueltan juntos: veinte clics seguidos en la misma
        # ventana son UN paso ("hizo 20 clics"), no veinte pasos.
        if estado["clics"] or estado["escrito"]:
            partes = []
            if estado["clics"]:
                partes.append("%d clic%s" % (estado["clics"], "s" if estado["clics"] > 1 else ""))
            if estado["escrito"]:
                partes.append("escribio %d caracteres" % estado["escrito"])
            estado["paso"] += 1
            print("%2d. %s" % (estado["paso"], " y ".join(partes)))
            estado["clics"] = 0
            estado["escrito"] = 0

    for e in eventos:
        tipo = e.get("tipo")
        if tipo in ("ventana", "inicio"):
            volcar()
            v = (e.get("ventana") or "").strip()
            if v and v != ventana:
                ventana = v
                estado["paso"] += 1
                print("%2d. paso a la ventana: %s" % (estado["paso"], v[:90]))
        elif tipo == "clic":
            estado["clics"] += 1
        elif tipo == "escribio":
            estado["escrito"] += int(e.get("caracteres") or 0)
        elif tipo in ("tecla", "atajo"):
            volcar()
            estado["paso"] += 1
            print("%2d. apreto %s" % (estado["paso"], e.get("tecla")))
        elif tipo == "fin":
            volcar()
    volcar()
    dur = eventos[-1].get("t", 0) / 1000.0
    print("")
    print("(la tarea entera duro %.0f segundos)" % dur)
    return 0


if __name__ == "__main__":
    sys.exit(main())
