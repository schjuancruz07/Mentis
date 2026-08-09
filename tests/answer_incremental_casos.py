#!/usr/bin/env python3
# Casos de answer_incremental (nv_stream.py): reconstruir la respuesta final desde un JSON que
# todavia esta llegando. Lo usa tests/test-stream.sh.
#
# EL CASO PELIGROSO es el chunk que corta un escape al medio: "\n", "\"" o "\uXXXX" partidos en
# dos trozos. Por eso se simula la llegada con trozos de 3, de tamano al azar, y de UN caracter
# (el peor caso posible: cada escape queda cortado si o si).
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))
import nv_stream

CASOS = [
    "Hola, todo bien.",
    "Linea uno\nlinea dos\nlinea tres",
    'Dijo "hola" y se fue',
    "Acentos: canción, mañana, ñandú, ¿sí?",
    "Mixto:\n\t\"comillas\" y \\barras\\ y emoji \U0001f642 y ñ",
    "x" * 500 + "\nfinal",
]

fallas = []

for caso in CASOS:
    entero = json.dumps({"tool": "done", "answer": caso}, ensure_ascii=False)
    for modo in ("de3", "azar", "de1"):
        if modo == "de1":
            trozos = list(entero)
        elif modo == "de3":
            trozos = [entero[i:i + 3] for i in range(0, len(entero), 3)]
        else:
            trozos, i = [], 0
            random.seed(7)
            while i < len(entero):
                n = random.randint(1, 9)
                trozos.append(entero[i:i + n])
                i += n
        acc, emitido, salida = "", 0, []
        for t in trozos:
            acc += t
            nuevo, emitido = nv_stream.answer_incremental(acc, emitido)
            if nuevo:
                salida.append(nuevo)
        recon = "".join(salida)
        if recon != caso:
            fallas.append("[%s] esperado %r, obtenido %r" % (modo, caso[:40], recon[:40]))

# No puede emitir nada antes de que aparezca el campo answer: si lo hiciera, la app pintaria
# pedazos del JSON ({"tool":"do...) como si fueran la respuesta.
nuevo, _ = nv_stream.answer_incremental('{"tool":"do', 0)
if nuevo:
    fallas.append("emitio %r sin haber llegado al campo answer" % nuevo)

# Ni puede seguir de largo hacia el campo siguiente cuando answer ya cerro.
acc, em, out = "", 0, []
for c in '{"tool":"done","answer":"listo","extra":"NO DEBE SALIR"}':
    acc += c
    nuevo, em = nv_stream.answer_incremental(acc, em)
    out.append(nuevo)
if "".join(out) != "listo":
    fallas.append("se paso al campo siguiente: %r" % "".join(out))

for f in fallas:
    print("FALLA: %s" % f)
print("casos: %d" % (len(CASOS) * 3 + 2))
sys.exit(1 if fallas else 0)
