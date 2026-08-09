"""medir-linea-base.py -- foto del estado ANTES de tocar nada (Bloque 0.1 del plan 2026-08-03).

POR QUE EXISTE: sin una foto previa no se puede probar que algo mejoro, y "me parece que anda
mas rapido" no es un resultado. Lee la telemetria que Mentis ya escribe (engine/logs/nv.jsonl),
no gasta una sola llamada, y guarda el resultado con fecha para poder comparar despues.

REGLA (revision 2026-08-02): los errores NO salen del denominador de la latencia -- una llamada
que tardo 300 s y ademas fallo cuenta como lenta, porque el usuario espero esos 300 s igual.
Pero se reportan aparte para no confundir "lento" con "roto".
"""
import json
import io
import os
import sys
import collections
from datetime import datetime

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
LOG = os.path.join(RAIZ, "engine", "logs", "nv.jsonl")


def cargar():
    xs = []
    if not os.path.exists(LOG):
        return xs
    for linea in io.open(LOG, encoding="utf-8", errors="replace"):
        linea = linea.strip()
        if not linea:
            continue
        try:
            d = json.loads(linea)
        except Exception:
            continue
        try:
            d["_t"] = datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except Exception:
            d["_t"] = None
        xs.append(d)
    return xs


def pct(valores, p):
    if not valores:
        return 0
    v = sorted(valores)
    i = min(int(len(v) * p), len(v) - 1)
    return v[i]


def agrupar_turnos(xs, hueco=90):
    """Un turno = llamadas separadas por menos de `hueco` segundos entre si."""
    con_hora = sorted((d for d in xs if d["_t"]), key=lambda d: d["_t"])
    if not con_hora:
        return []
    turnos = []
    actual = [con_hora[0]]
    for a, b in zip(con_hora, con_hora[1:]):
        if b["_t"] - a["_t"] <= hueco:
            actual.append(b)
        else:
            turnos.append(actual)
            actual = [b]
    turnos.append(actual)
    return turnos


def main():
    xs = cargar()
    if not xs:
        print("no hay telemetria en %s" % LOG, file=sys.stderr)
        return 1

    lat = [d["latencia_ms"] for d in xs if isinstance(d.get("latencia_ms"), int)]
    fallos = [d for d in xs if d.get("exit") not in (0, None)]
    turnos = agrupar_turnos(xs)
    tam = [len(t) for t in turnos]

    foto = {
        "cuando": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "llamadas": len(xs),
        "latencia_ms": {"p50": pct(lat, 0.50), "p90": pct(lat, 0.90),
                        "p99": pct(lat, 0.99), "max": max(lat) if lat else 0},
        "lentas_30s": sum(1 for x in lat if x >= 30000),
        "fallos": len(fallos),
        "tasa_fallo": round(len(fallos) / len(xs), 4),
        "turnos": len(turnos),
        "llamadas_por_turno": {"p50": pct(tam, 0.50),
                               "promedio": round(sum(tam) / len(tam), 2) if tam else 0,
                               "max": max(tam) if tam else 0},
        "por_rol": {},
        "por_modelo": {},
    }

    for clave, campo in (("por_rol", "rol"), ("por_modelo", "modelo")):
        grupos = collections.defaultdict(list)
        for d in xs:
            grupos[d.get(campo) or "?"].append(d)
        for nombre, ds in grupos.items():
            ls = [d["latencia_ms"] for d in ds if isinstance(d.get("latencia_ms"), int)]
            foto[clave][nombre] = {
                "llamadas": len(ds),
                "p50": pct(ls, 0.50), "p90": pct(ls, 0.90),
                "lentas_30s": sum(1 for x in ls if x >= 30000),
                "fallos": sum(1 for d in ds if d.get("exit") not in (0, None)),
            }

    salida = os.path.join(RAIZ, "docs", "linea-base-%s.json" % datetime.now().strftime("%Y%m%d-%H%M"))
    with io.open(salida, "w", encoding="utf-8") as f:
        json.dump(foto, f, ensure_ascii=False, indent=2)

    print("=== LINEA DE BASE (%d llamadas, %d turnos) ===" % (foto["llamadas"], foto["turnos"]))
    L = foto["latencia_ms"]
    print("  latencia  p50 %d ms | p90 %d ms | p99 %d ms | max %d ms"
          % (L["p50"], L["p90"], L["p99"], L["max"]))
    print("  lentas (>=30 s)... %d (%.1f%%)" % (foto["lentas_30s"], 100 * foto["lentas_30s"] / len(lat)))
    print("  fallos............ %d (%.1f%%)" % (foto["fallos"], 100 * foto["tasa_fallo"]))
    T = foto["llamadas_por_turno"]
    print("  llamadas por turno  mediana %d | promedio %.1f | max %d" % (T["p50"], T["promedio"], T["max"]))
    print()
    print("  %-42s %6s %8s %8s %7s" % ("MODELO", "llam.", "p50", "p90", "lentas"))
    for nombre, m in sorted(foto["por_modelo"].items(), key=lambda kv: -kv[1]["llamadas"]):
        print("  %-42s %6d %8d %8d %7d" % (nombre[:42], m["llamadas"], m["p50"], m["p90"], m["lentas_30s"]))
    print()
    print("  guardado en %s" % salida)
    return 0


if __name__ == "__main__":
    sys.exit(main())
