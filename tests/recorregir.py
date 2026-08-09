#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""recorregir.py -- vuelve a corregir roles.jsonl con el criterio arreglado, sin gastar llamadas.

POR QUE EXISTE
    El 2026-08-02, ya con la medición corrida, se descubrió que el verificador de tipo 'numero'
    tomaba el PRIMER número de la respuesta. Pedimos "responde solo el numero" y varios modelos
    igual muestran el procedimiento: "20% de descuento sobre 100 pesos es 20 pesos. 100 - 20 = 80.
    80". El primero es 20, así que una respuesta CORRECTA se contaba como error -- y el sesgo caía
    justo sobre los modelos que razonan mejor, que son los que más explican.

    Como cada corrida guardó la respuesta cruda, se puede volver a corregir sin pedir nada de
    nuevo. Eso es exactamente para lo que se guardaban.

OJO: las respuestas se guardaron recortadas a 300 caracteres. Si una respuesta se cortó antes de
    llegar a su conclusión, el último número puede no ser la respuesta final. Se informa cuántas
    llegaron al tope para poder desconfiar de ésas.

Uso: python3 recorregir.py <archivo.jsonl>
"""
import json, re, sys, unicodedata

NUM = re.compile(r"[0-9]+(?:[.,][0-9]+)?")


def norm(s):
    """Saca tildes comparando por caracteres, no por bytes (ERR-100)."""
    return "".join(c for c in unicodedata.normalize("NFD", s.lower())
                   if unicodedata.category(c) != "Mn")


def aprueba(resp, tipo, esp):
    if tipo == "contiene":
        return norm(esp) in norm(resp)
    if tipo == "numero":
        mn, mx = esp.split("-")
        nums = NUM.findall(resp)
        if not nums:
            return False
        # El ULTIMO: en una respuesta razonada la conclusión está al final.
        v = nums[-1].replace(",", ".").split(".")[0]
        try:
            return int(mn) <= int(v) <= int(mx)
        except ValueError:
            return False
    if tipo == "json":
        t = resp.strip()
        m = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
        if m:
            t = m.group(1).strip()
        else:
            a, b = t.find("{"), t.rfind("}")
            if a >= 0 and b > a:
                t = t[a:b + 1]
        try:
            d = json.loads(t)
        except Exception:
            return False
        if not isinstance(d, dict):
            return False
        claves = [c.strip().lower() for c in esp.split(",") if c.strip()]
        tiene = {k.lower() for k in d}
        return all(c in tiene for c in claves)
    return False


def main():
    ruta = sys.argv[1]
    filas, cambios, recortadas = [], 0, 0
    with open(ruta, encoding="utf-8") as f:
        for l in f:
            l = l.strip()
            if not l:
                continue
            d = json.loads(l)
            if d.get("ok") is not None and d.get("resp"):
                nuevo = int(aprueba(d["resp"], d["tipo"], d["esperado"]))
                if nuevo != d["ok"]:
                    cambios += 1
                    print("  %s / %s / caso %s: %s -> %s   (esperado %s, dio %r)" % (
                        d["rol"], d["modelo"].split("/")[-1], d["caso"],
                        d["ok"], nuevo, d["esperado"], d["resp"][:70].replace("\n", " ")))
                    d["ok"] = nuevo
                if len(d["resp"]) >= 300:
                    recortadas += 1
            filas.append(d)
    with open(ruta, "w", encoding="utf-8") as f:
        for d in filas:
            f.write(json.dumps(d, ensure_ascii=False, separators=(",", ":")) + "\n")
    print("\n%d casos recorregidos, %d cambiaron de veredicto." % (len(filas), cambios))
    print("%d respuestas llegaron al tope de 300 caracteres (su último número puede no ser la conclusión)." % recortadas)


if __name__ == "__main__":
    main()
