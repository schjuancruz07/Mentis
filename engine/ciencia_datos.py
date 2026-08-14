"""ciencia_datos.py -- datos cientificos REALES para el modo Mentis Science (2026-08-13).

POR QUE EXISTE: Science ya sabia dibujar moleculas y cristales con geometria medida (quimica_3d.py),
pero para todo lo demas -- una constante fisica, una proteina, un gen -- dependia de lo que el
modelo recordara. Y "lo que el modelo recuerda" es exactamente lo que este modo promete no usar:
una cifra con cara de precision y sin fuente es peor que no responder.

DE DONDE SALEN LOS DATOS:
  * FISICA: tabla CODATA 2022 incluida aca abajo, con valor, unidad e incertidumbre. Es dato
    publicado por el CODATA/NIST, no una estimacion. Va como tabla y no como consulta a una API
    porque NIST no publica un JSON oficial, y scipy (que si las trae) no esta instalado en esta
    maquina -- meter una dependencia de 50 MB para leer 50 numeros que no cambian seria peor.
  * BIOLOGIA: UniProt (consorcio EMBL-EBI/SIB/PIR), en vivo. Devuelve accession, gen, longitud y
    funcion, y cada respuesta trae su identificador para poder ir a verificarla.
  * QUIMICA: ya la cubre engine/quimica_3d.py (PubChem). No se duplica aca.

LO QUE NO HACE: no inventa. Si no encuentra el dato, lo dice. Un "no lo tengo" es una respuesta
util en un modo cientifico; un numero aproximado presentado como exacto, no.

Uso:
    ciencia_datos.py constante "velocidad de la luz"
    ciencia_datos.py proteina "hemoglobina"
    ciencia_datos.py gen "BRCA1"
"""
import io
import json
import sys
import unicodedata
import urllib.parse
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

UNIPROT = ("https://rest.uniprot.org/uniprotkb/search?query={}&format=json&size=3"
           "&fields=accession,protein_name,gene_names,length,organism_name,cc_function")

# CODATA 2022. Valor, unidad, incertidumbre estandar ("exacta" = definida, sin incertidumbre desde
# la redefinicion del SI de 2019). Los alias en espaniol estan porque el usuario pregunta en espaniol y
# los nombres oficiales estan en ingles.
CONSTANTES = {
    "c":       (299792458.0, "m/s", "exacta (define el metro)", ["velocidad de la luz", "speed of light", "luz"]),
    "h":       (6.62607015e-34, "J·s", "exacta (define el kilogramo)", ["constante de planck", "planck"]),
    "hbar":    (1.054571817e-34, "J·s", "exacta (derivada de h)", ["planck reducida", "h barra"]),
    "e":       (1.602176634e-19, "C", "exacta (define el amperio)", ["carga elemental", "carga del electron"]),
    "k":       (1.380649e-23, "J/K", "exacta (define el kelvin)", ["constante de boltzmann", "boltzmann"]),
    "N_A":     (6.02214076e23, "1/mol", "exacta (define el mol)", ["numero de avogadro", "avogadro", "constante de avogadro"]),
    "R":       (8.31446261815324, "J/(mol·K)", "exacta (N_A · k)", ["constante de los gases", "gases ideales", "constante universal"]),
    "G":       (6.67430e-11, "m³/(kg·s²)", "±0.00015e-11 (la peor medida de la fisica)", ["constante gravitacional", "gravitacion universal", "newton"]),
    "g":       (9.80665, "m/s²", "exacta (valor estandar convenido)", ["gravedad", "aceleracion de la gravedad"]),
    "m_e":     (9.1093837139e-31, "kg", "±0.0000000028e-31", ["masa del electron", "electron"]),
    "m_p":     (1.67262192595e-27, "kg", "±0.00000000052e-27", ["masa del proton", "proton"]),
    "m_n":     (1.67492750056e-27, "kg", "±0.00000000085e-27", ["masa del neutron", "neutron"]),
    "u":       (1.66053906892e-27, "kg", "±0.00000000052e-27", ["unidad de masa atomica", "uma", "dalton"]),
    "epsilon_0": (8.8541878188e-12, "F/m", "±0.0000000014e-12", ["permitividad del vacio", "constante electrica"]),
    "mu_0":    (1.25663706127e-6, "N/A²", "±0.00000000020e-6", ["permeabilidad del vacio", "constante magnetica"]),
    "sigma":   (5.670374419e-8, "W/(m²·K⁴)", "exacta (derivada)", ["stefan boltzmann", "constante de stefan"]),
    "F":       (96485.33212, "C/mol", "exacta (N_A · e)", ["constante de faraday", "faraday"]),
    "alpha":   (7.2973525643e-3, "adimensional", "±0.0000000011e-3", ["constante de estructura fina", "estructura fina"]),
    "a_0":     (5.29177210544e-11, "m", "±0.00000000082e-11", ["radio de bohr", "bohr"]),
    "Ry":      (10973731.568157, "1/m", "±0.000012", ["constante de rydberg", "rydberg"]),
    "atm":     (101325.0, "Pa", "exacta (definida)", ["atmosfera estandar", "presion atmosferica"]),
    "eV":      (1.602176634e-19, "J", "exacta (= e · 1 V)", ["electronvoltio", "electron volt"]),
}


def _sin_tildes(t):
    return "".join(c for c in unicodedata.normalize("NFD", t.lower())
                   if unicodedata.category(c) != "Mn")


def constante(consulta):
    q = _sin_tildes(consulta).strip()
    # Primero el simbolo exacto (c, h, G): son una o dos letras y buscarlas por parecido daria
    # cualquier cosa.
    for simbolo, (val, uni, inc, alias) in CONSTANTES.items():
        if q == simbolo.lower():
            return {"ok": True, "simbolo": simbolo, "valor": val, "unidad": uni,
                    "incertidumbre": inc, "fuente": "CODATA 2022 (NIST)"}
    for simbolo, (val, uni, inc, alias) in CONSTANTES.items():
        if any(q in _sin_tildes(a) or _sin_tildes(a) in q for a in alias):
            return {"ok": True, "simbolo": simbolo, "valor": val, "unidad": uni,
                    "incertidumbre": inc, "fuente": "CODATA 2022 (NIST)"}
    return {"ok": False,
            "error": f"no tengo la constante '{consulta}' en la tabla CODATA que traigo.",
            "disponibles": sorted(CONSTANTES.keys())}


def _uniprot(consulta, extra=""):
    url = UNIPROT.format(urllib.parse.quote(consulta + extra))
    req = urllib.request.Request(url, headers={"User-Agent": "Mentis/1.0 (asistente personal)"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read().decode("utf-8", errors="replace"))
    except Exception as e:
        return {"_error": str(e)}


def _formatear_uniprot(d, consulta):
    if "_error" in d:
        return {"ok": False, "error": f"no se pudo consultar UniProt: {d['_error']}"}
    res = d.get("results") or []
    if not res:
        return {"ok": False, "error": f"UniProt no tiene nada para '{consulta}'."}
    salida = []
    for r in res:
        nombre = ""
        try:
            nombre = r["proteinDescription"]["recommendedName"]["fullName"]["value"]
        except Exception:
            nombre = (r.get("proteinDescription", {}).get("submissionNames") or [{}])[0] \
.get("fullName", {}).get("value", "")
        genes = [g.get("geneName", {}).get("value") for g in (r.get("genes") or [])]
        funcion = ""
        for c in (r.get("comments") or []):
            if c.get("commentType") == "FUNCTION":
                textos = c.get("texts") or []
                if textos:
                    funcion = textos[0].get("value", "")[:400]
                break
        salida.append({
            "accession": r.get("primaryAccession"),
            "proteina": nombre,
            "genes": [g for g in genes if g],
            "aminoacidos": (r.get("sequence") or {}).get("length"),
            "organismo": (r.get("organism") or {}).get("scientificName"),
            "funcion": funcion,
            "ficha": f"https://www.uniprot.org/uniprotkb/{r.get('primaryAccession')}",
        })
    return {"ok": True, "resultados": salida, "fuente": "UniProt (EMBL-EBI / SIB / PIR)"}


def _variantes(nombre):
    """UniProt indexa en INGLES. En vez de una tabla de traducciones (que ademas obligaria a
    escribir terminos medicos que el control de privacidad del repositorio publico rechaza, ver
    ERR-148), se aplican las tres correspondencias morfologicas que cubren casi toda la biologia:
        -ina  -> -in    (hemoglobina -> hemoglobin, miosina -> myosin)
        -asa  -> -ase   (amilasa -> amylase, lipasa -> lipase)
        -ico  -> -ic    (citocromo cromico...)
    Es generico: funciona con palabras que nadie escribio en ninguna lista."""
    base = _sin_tildes(nombre).strip()
    v = [nombre, base]
    for suf, reemplazo in (("ina", "in"), ("asa", "ase"), ("ico", "ic"),
                           ("ano", "ane"), ("eno", "en"), ("osa", "ose")):
        if base.endswith(suf):
            v.append(base[: -len(suf)] + reemplazo)
    # Correspondencias de letras entre los dos idiomas, medidas contra casos reales (2026-08-13):
    #   qu- -> k-   queratina -> keratin
    #   -i- -> -y-  miosina -> myosin, amilasa -> amylase
    #   -l- -> -ll- colageno -> collagen
    # Se aplican SOBRE las variantes de sufijo ya generadas, no en vez de ellas: la mayoria de los
    # nombres necesita las dos cosas a la vez (amilasa pide -asa->-ase Y i->y para dar amylase).
    extra = []
    for x in list(v):
        if x.startswith("qu"):
            extra.append("k" + x[2:])
        if "i" in x:
            extra.append(x.replace("i", "y", 1))
        if "l" in x and "ll" not in x:
            extra.append(x.replace("l", "ll", 1))
    v += extra
    vistos, salida = set(), []
    for x in v:
        if x and x not in vistos:
            vistos.add(x); salida.append(x)
    return salida


def proteina(nombre):
    # Se prioriza humano y revisado: es lo que se pregunta al estudiar biologia. Se prueban las
    # variantes en orden y se devuelve la primera que da algo, en vez de decir que no existe.
    for cand in _variantes(nombre):
        r = _formatear_uniprot(_uniprot(cand, " AND organism_id:9606 AND reviewed:true"), cand)
        if r.get("ok"):
            return r
    for cand in _variantes(nombre):
        r = _formatear_uniprot(_uniprot(cand, " AND reviewed:true"), cand)
        if r.get("ok"):
            return r
    return {"ok": False, "error": f"UniProt no tiene nada para '{nombre}' ni sus variantes."}


def gen(simbolo):
    d = _uniprot(f"gene:{simbolo} AND organism_id:9606 AND reviewed:true")
    return _formatear_uniprot(d, simbolo)


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "uso: ciencia_datos.py constante|proteina|gen <que>"},
                         ensure_ascii=False))
        return 2
    modo, que = sys.argv[1], " ".join(sys.argv[2:])
    r = {"constante": constante, "proteina": proteina, "gen": gen}.get(modo)
    if not r:
        print(json.dumps({"ok": False, "error": f"modo desconocido: {modo}"}, ensure_ascii=False))
        return 2
    salida = r(que)
    print(json.dumps(salida, ensure_ascii=False))
    return 0 if salida.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
