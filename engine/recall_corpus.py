#!/usr/bin/env python3
"""recall_corpus.py -- traduce las conversaciones a texto legible para poder indexarlas.

Las conversaciones se guardan como JSONL ({"role","text","ts"}). Indexar ese crudo pondria
comillas, llaves y nombres de campo dentro de los embeddings: ruido que compite con las palabras
que importan. Aca se convierte cada conversacion a un.txt con forma de dialogo, que es lo que
despues indexa nv-index.sh.

Efecto secundario buscado: como cada turno queda con su fecha al principio de la linea, los
pasajes que devuelve la busqueda YA vienen fechados y con el hablante, sin postprocesar nada.

Incremental: una conversacion solo se reescribe si cambio despues de la ultima vez.
"""
import argparse
import json
import os
import sys
from datetime import datetime

# Los turnos muy cortos ("ok", "dale", "si") no aportan nada a una busqueda semantica y solo
# ensucian el indice con fragmentos que hacen ruido en cualquier consulta.
MINIMO_UTIL = 12


def fecha_legible(ts):
    if not ts:
        return "?"
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "")).strftime("%Y-%m-%d %H:%M")
    except (ValueError, TypeError):
        return str(ts)[:16]


def convertir(ruta_jsonl):
    """Devuelve el texto de dialogo de una conversacion, o '' si no tiene nada util."""
    lineas = []
    # errors="replace": la leccion de ERR-080 -- un byte mal codificado en un historial viejo no
    # puede tumbar el indexado entero. Se degrada ese caracter y se sigue.
    with open(ruta_jsonl, "r", encoding="utf-8", errors="replace") as f:
        for linea in f:
            linea = linea.strip()
            if not linea:
                continue
            try:
                e = json.loads(linea)
            except json.JSONDecodeError:
                continue          # una linea corrupta no invalida la conversacion entera
            texto = (e.get("text") or "").strip()
            if len(texto) < MINIMO_UTIL:
                continue
            quien = "el usuario" if e.get("role") == "usuario" else "Mentis"
            lineas.append("[%s] %s: %s" % (fecha_legible(e.get("ts")), quien, texto))
    return "\n\n".join(lineas)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entrada", required=True, help="directorio con las conversaciones.jsonl")
    ap.add_argument("--salida", required=True, help="directorio donde dejar los.txt")
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    escritas = salteadas = vacias = 0

    for nombre in sorted(os.listdir(args.entrada)):
        if not nombre.endswith(".jsonl"):
            continue
        origen = os.path.join(args.entrada, nombre)
        destino = os.path.join(args.salida, nombre[:-6] + ".txt")

        # Incremental: si el.txt es mas nuevo que la conversacion, no hay nada que hacer.
        if os.path.exists(destino) and os.path.getmtime(destino) >= os.path.getmtime(origen):
            salteadas += 1
            continue

        try:
            texto = convertir(origen)
        except OSError as e:
            print("aviso: no se pudo leer %s (%s)" % (nombre, e), file=sys.stderr)
            continue

        if not texto:
            vacias += 1
            # Si quedo un.txt de una version anterior que ahora no aporta nada, se saca: dejarlo
            # mantendria en el indice fragmentos de algo que ya no existe.
            if os.path.exists(destino):
                os.remove(destino)
            continue

        with open(destino, "w", encoding="utf-8") as f:
            f.write(texto)
        escritas += 1

    # Conversaciones borradas: su.txt tiene que irse tambien, o la busqueda seguiria citando
    # charlas que el usuario ya elimino.
    vivos = {n[:-6] + ".txt" for n in os.listdir(args.entrada) if n.endswith(".jsonl")}
    huerfanos = 0
    for nombre in os.listdir(args.salida):
        if nombre.endswith(".txt") and nombre not in vivos:
            os.remove(os.path.join(args.salida, nombre))
            huerfanos += 1

    print("corpus: %d nuevas o cambiadas, %d sin cambios, %d vacias, %d borradas"
          % (escritas, salteadas, vacias, huerfanos))
    return 0


if __name__ == "__main__":
    sys.exit(main())
