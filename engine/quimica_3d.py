"""quimica_3d.py -- geometria REAL de moleculas y cristales para el modo Mentis Science.

POR QUE EXISTE (2026-08-12): el usuario pidio que Science dibuje en 3D lo que esta explicando. El motor
3D que ya tenia Mentis es TripoSR (imagen -> malla), y para quimica NO sirve: produce una forma
"parecida" a partir de una foto, o sea una masa deforme con cara de molecula. En el unico modo que
promete no inventar nada, eso es lo peor que se podia hacer.

DE DONDE SALEN LOS DATOS:
  * Moleculas: PubChem (NIH). Se pide el SDF 3D y se leen las coordenadas tal cual vienen. Si
    PubChem no tiene conformero 3D de ese compuesto, se dice -- no se inventa una geometria.
  * Cristales: parametros de celda publicados, en la tabla CRISTALES de abajo. El calcio metalico
    NO es una molecula: es una red FCC, y dibujarlo como "molecula de calcio" seria un error
    conceptual. Por eso son dos caminos distintos y el script elige segun lo que se pida.

QUE DEVUELVE: un JSON con atomos (elemento + x,y,z en angstroms) y enlaces. No genera una imagen
ni un GLB: la geometria viaja como datos y la dibuja el visor de la app con three.js. Asi lo que
se ve en pantalla son las coordenadas reales y no el render que hizo otro programa.

Uso:
    quimica_3d.py molecula "agua"          -> busca en PubChem por nombre
    quimica_3d.py cristal "calcio"         -> celda unidad desde la tabla
    quimica_3d.py auto "<texto>"           -> decide cual de los dos, o falla diciendo por que
"""
import io
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

PUBCHEM = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{}/SDF?record_type=3d"

# Radio covalente (A) y color CPK. Es la convencion de toda la quimica: el oxigeno rojo y el
# nitrogeno azul no son decoracion, son como se lee una estructura de un vistazo.
ELEMENTOS = {
    "H":  (0.31, "#FFFFFF"), "C":  (0.76, "#909090"), "N":  (0.71, "#3050F8"),
    "O":  (0.66, "#FF0D0D"), "F":  (0.57, "#90E050"), "P":  (1.07, "#FF8000"),
    "S":  (1.05, "#FFFF30"), "Cl": (1.02, "#1FF01F"), "Br": (1.20, "#A62929"),
    "I":  (1.39, "#940094"), "Na": (1.66, "#AB5CF2"), "Mg": (1.41, "#8AFF00"),
    "K":  (2.03, "#8F40D4"), "Ca": (1.76, "#3DFF00"), "Fe": (1.32, "#E06633"),
    "Cu": (1.32, "#C88033"), "Zn": (1.22, "#7D80B0"), "Al": (1.21, "#BFA6A6"),
    "Si": (1.11, "#F0C8A0"), "Au": (1.36, "#FFD123"), "Ag": (1.45, "#C0C0C0"),
    "He": (0.28, "#D9FFFF"), "Ne": (0.58, "#B3E3F5"), "Ar": (1.06, "#80D1E3"),
    "Li": (1.28, "#CC80FF"), "Be": (0.96, "#C2FF00"), "B":  (0.84, "#FFB5B5"),
    "Ti": (1.60, "#BFC2C7"), "Ni": (1.24, "#50D050"), "Pb": (1.46, "#575961"),
}

# Estructuras cristalinas de metales y sales comunes. 'a' en angstroms, medido, no estimado.
# Fuente: parametros de red estandar (CRC Handbook). Se listan solo los que se pueden afirmar.
CRISTALES = {
    "calcio":   {"simbolo": "Ca", "tipo": "FCC", "a": 5.588, "nombre": "Calcio metalico"},
    "aluminio": {"simbolo": "Al", "tipo": "FCC", "a": 4.050, "nombre": "Aluminio"},
    "cobre":    {"simbolo": "Cu", "tipo": "FCC", "a": 3.615, "nombre": "Cobre"},
    "oro":      {"simbolo": "Au", "tipo": "FCC", "a": 4.078, "nombre": "Oro"},
    "plata":    {"simbolo": "Ag", "tipo": "FCC", "a": 4.085, "nombre": "Plata"},
    "plomo":    {"simbolo": "Pb", "tipo": "FCC", "a": 4.950, "nombre": "Plomo"},
    "niquel":   {"simbolo": "Ni", "tipo": "FCC", "a": 3.524, "nombre": "Niquel"},
    "hierro":   {"simbolo": "Fe", "tipo": "BCC", "a": 2.866, "nombre": "Hierro alfa"},
    "sodio":    {"simbolo": "Na", "tipo": "BCC", "a": 4.291, "nombre": "Sodio metalico"},
    "potasio":  {"simbolo": "K",  "tipo": "BCC", "a": 5.328, "nombre": "Potasio metalico"},
    "litio":    {"simbolo": "Li", "tipo": "BCC", "a": 3.510, "nombre": "Litio"},
    "sal":      {"simbolo": None, "tipo": "NaCl", "a": 5.640, "nombre": "Cloruro de sodio (sal de mesa)"},
    "cloruro de sodio": {"simbolo": None, "tipo": "NaCl", "a": 5.640, "nombre": "Cloruro de sodio"},
}

# Posiciones fraccionarias de cada red. Son la definicion de la estructura, no una aproximacion.
BASES = {
    "FCC": [(0, 0, 0), (0.5, 0.5, 0), (0.5, 0, 0.5), (0, 0.5, 0.5)],
    "BCC": [(0, 0, 0), (0.5, 0.5, 0.5)],
}


def _pedir(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mentis/1.0 (asistente personal)"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", errors="replace")


def leer_sdf(texto):
    """Lee un SDF V2000. El formato es de ancho fijo por columnas, no separado por espacios --
    pero PubChem lo emite alineado, asi que split() alcanza y evita romperse si cambia el padding.
    Devuelve None si el archivo no tiene la linea de conteo donde corresponde."""
    lineas = texto.splitlines()
    if len(lineas) < 4:
        return None
    conteo = lineas[3].split()
    try:
        n_at, n_en = int(conteo[0]), int(conteo[1])
    except (ValueError, IndexError):
        return None

    atomos = []
    for i in range(4, 4 + n_at):
        p = lineas[i].split()
        if len(p) < 4:
            return None
        atomos.append({"el": p[3], "x": float(p[0]), "y": float(p[1]), "z": float(p[2])})

    enlaces = []
    for i in range(4 + n_at, 4 + n_at + n_en):
        p = lineas[i].split()
        if len(p) < 3:
            continue
        # En SDF los indices arrancan en 1; el visor los quiere en 0.
        enlaces.append([int(p[0]) - 1, int(p[1]) - 1, int(p[2])])
    return atomos, enlaces


# PubChem indexa en INGLES. Algunos nombres coinciden ("agua", "cafeina" resuelven por sinonimos),
# pero muchos no: "glucosa" devuelve 404 y "glucose" funciona. Sin esta tabla, Mentis le dice a
# el usuario "ese compuesto no existe" sobre cosas que si existen -- un error que suena a dato duro.
# La lista cubre lo que se pide al estudiar; para el resto se prueba igual el nombre tal cual.
ES_EN = {
    "glucosa": "glucose", "sacarosa": "sucrose", "fructosa": "fructose",
    "etanol": "ethanol", "metano": "methane", "etano": "ethane", "propano": "propane",
    "butano": "butane", "benceno": "benzene", "tolueno": "toluene", "acetona": "acetone",
    "amoniaco": "ammonia", "amoniaco ": "ammonia", "acido sulfurico": "sulfuric acid",
    "acido clorhidrico": "hydrochloric acid", "acido acetico": "acetic acid",
    "acido citrico": "citric acid", "acido ascorbico": "ascorbic acid",
    "vitamina c": "ascorbic acid", "aspirina": "aspirin", "ibuprofeno": "ibuprofen",
    "paracetamol": "acetaminophen", "colesterol": "cholesterol", "glicina": "glycine",
    "alanina": "alanine", "urea": "urea", "nicotina": "nicotine", "morfina": "morphine",
    "penicilina": "penicillin", "adrenalina": "adrenaline", "dopamina": "dopamine",
    "serotonina": "serotonin", "testosterona": "testosterone", "estrogeno": "estradiol",
    "clorofila": "chlorophyll",
    # LAS PROTEINAS GRANDES NO VAN EN ESTA TABLA. PubChem no publica conformero 3D para ellas
    # (devuelven 404), asi que la entrada no habria servido de nada. Ademas, dos de las que
    # estaban aca hacian saltar el control de privacidad del repositorio publico -- que busca
    # terminos de salud para que no se filtre la condicion medica del usuario -- y una tabla de
    # quimica no es motivo para aflojar ese control.
    # Si alguna vez hace falta dibujar una proteina, el camino es el PDB (RCSB), no PubChem.
    "dioxido de carbono": "carbon dioxide", "monoxido de carbono": "carbon monoxide",
    "peroxido de hidrogeno": "hydrogen peroxide", "agua oxigenada": "hydrogen peroxide",
    "metanol": "methanol", "acetileno": "acetylene", "ozono": "ozone",
    "bicarbonato de sodio": "sodium bicarbonate", "carbonato de calcio": "calcium carbonate",
}


def _sin_tildes(t):
    tabla = str.maketrans("áéíóúüñÁÉÍÓÚÜÑ", "aeiouunAEIOUUN")
    return t.translate(tabla)


def molecula(nombre):
    # Se prueba el nombre tal cual primero: si PubChem ya lo entiende (pasa con "agua" y
    # "cafeina"), no hace falta traducir nada.
    clave = _sin_tildes(nombre.lower().strip())
    if clave in ES_EN:
        nombre = ES_EN[clave]
    try:
        sdf = _pedir(PUBCHEM.format(urllib.parse.quote(nombre)))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {"ok": False, "error": f"PubChem no tiene ningun compuesto llamado '{nombre}'."}
        return {"ok": False, "error": f"PubChem respondio {e.code}."}
    except Exception as e:  # red caida, DNS, timeout
        return {"ok": False, "error": f"no se pudo consultar PubChem: {e}"}

    leido = leer_sdf(sdf)
    if not leido:
        # Pasa con compuestos que solo tienen estructura 2D cargada. Decirlo es la respuesta
        # correcta: dibujar algo plano como si fuera la geometria real seria inventar.
        return {"ok": False, "error": f"PubChem no tiene conformero 3D para '{nombre}'."}
    atomos, enlaces = leido

    cid = ""
    m = re.search(r"<PUBCHEM_COMPOUND_CID>\s*\n(\d+)", sdf)
    if m:
        cid = m.group(1)
    return {"ok": True, "clase": "molecula", "nombre": nombre, "atomos": atomos,
            "enlaces": enlaces,
            "fuente": f"PubChem CID {cid}" if cid else "PubChem",
            "url": f"https://pubchem.ncbi.nlm.nih.gov/compound/{cid}" if cid else ""}


def cristal(clave, celdas=2):
    """Celda unidad repetida `celdas` veces por eje. Se dibuja mas de una porque una sola no deja
    ver el empaquetamiento, que es justamente lo que distingue FCC de BCC."""
    d = CRISTALES.get(clave.lower().strip())
    if not d:
        return {"ok": False, "error": f"no tengo los parametros de red de '{clave}'."}
    a = d["a"]
    atomos = []

    if d["tipo"] == "NaCl":
        # Dos subredes FCC desplazadas media celda: es lo que hace que cada ion este rodeado por
        # seis del otro tipo. Dibujarlo como una sola red seria otra estructura.
        for i in range(celdas):
            for j in range(celdas):
                for k in range(celdas):
                    for (fx, fy, fz) in BASES["FCC"]:
                        atomos.append({"el": "Na", "x": (i + fx) * a, "y": (j + fy) * a, "z": (k + fz) * a})
                        atomos.append({"el": "Cl", "x": (i + fx + 0.5) * a, "y": (j + fy) * a, "z": (k + fz) * a})
    else:
        base = BASES[d["tipo"]]
        for i in range(celdas):
            for j in range(celdas):
                for k in range(celdas):
                    for (fx, fy, fz) in base:
                        atomos.append({"el": d["simbolo"], "x": (i + fx) * a,
                                       "y": (j + fy) * a, "z": (k + fz) * a})

    # Los enlaces se calculan por cercania y NO se declaran: en un metal no hay enlaces
    # localizados, las lineas son una ayuda visual para ver la red. Va dicho en 'nota'.
    enlaces = []
    lim = a * 0.75
    for i in range(len(atomos)):
        for j in range(i + 1, len(atomos)):
            dx = atomos[i]["x"] - atomos[j]["x"]
            dy = atomos[i]["y"] - atomos[j]["y"]
            dz = atomos[i]["z"] - atomos[j]["z"]
            if math.sqrt(dx * dx + dy * dy + dz * dz) <= lim:
                enlaces.append([i, j, 1])

    return {"ok": True, "clase": "cristal", "nombre": d["nombre"], "atomos": atomos,
            "enlaces": enlaces, "tipo_red": d["tipo"], "parametro_a": a,
            "fuente": f"parametro de red a = {a} A ({d['tipo']})",
            "nota": ("Las lineas marcan atomos vecinos para que se vea el empaquetamiento: "
                     "en un metal no hay enlaces localizados como en una molecula.")
            if d["tipo"] in ("FCC", "BCC") else
            ("Cada ion queda rodeado por seis del otro tipo; las lineas muestran esa vecindad, "
             "no enlaces covalentes.")}


def auto(texto):
    """Decide si lo pedido es un cristal o una molecula. Primero cristales: 'calcio' esta en las
    dos bases y la respuesta correcta para el calcio metalico es la red, no un 'atomo suelto'."""
    t = texto.lower().strip()
    for clave in CRISTALES:
        if re.search(r"\b" + re.escape(clave) + r"\b", t):
            return cristal(clave)
    limpio = re.sub(r"^(la |el |estructura |molecula |molécula |de |del )+", "", t).strip()
    return molecula(limpio or t)


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "uso: quimica_3d.py molecula|cristal|auto <que>"}))
        return 2
    modo, que = sys.argv[1], sys.argv[2]
    if modo == "molecula":
        r = molecula(que)
    elif modo == "cristal":
        r = cristal(que)
    elif modo == "auto":
        r = auto(que)
    else:
        r = {"ok": False, "error": f"modo desconocido: {modo}"}

    if r.get("ok"):
        # El visor necesita radio y color de cada elemento presente. Van con la geometria en vez
        # de duplicar la tabla en el JavaScript: una sola fuente para la convencion CPK.
        usados = {a["el"] for a in r["atomos"]}
        r["elementos"] = {e: {"radio": ELEMENTOS.get(e, (1.0, "#CCCCCC"))[0],
                              "color": ELEMENTOS.get(e, (1.0, "#CCCCCC"))[1]} for e in usados}
    print(json.dumps(r, ensure_ascii=False))
    return 0 if r.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
