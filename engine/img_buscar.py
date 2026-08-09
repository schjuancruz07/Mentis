"""img_buscar.py -- busca una imagen LIBRE en la web y la baja (2026-08-03, B2 del plan).

PARA QUE: cuando Mentis genera un documento, poder ilustrarlo. el usuario pidio que las imagenes salgan
preferentemente de la web y no de generarlas, "para no gastar recursos innecesarios" -- y tiene
razon por partida doble: generar una imagen cuesta una llamada y varios segundos, y para "una foto
de un panel solar" una foto real es mejor que una inventada.

DE DONDE: Wikimedia Commons. Se eligio por una razon concreta y no por costumbre: **todo lo que
hay ahi es de licencia libre y la API devuelve el autor y la licencia de cada archivo**, que es lo
que permite poner la atribucion. Una busqueda de imagenes comun devuelve cosas con derechos y sin
forma de saber de quien son -- meter eso en un documento del usuario seria crearle un problema, no
resolverle uno.

SE BAJA LOCALMENTE, no se enlaza. Un documento con imagenes enlazadas se rompe solo: si el sitio
cambia la URL, el archivo queda con un recuadro roto meses despues, cuando ya nadie se acuerda.

Uso:  img_buscar.py "<que buscar>" --dest <carpeta> [--ancho 1024] [--json]
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

API = "https://commons.wikimedia.org/w/api.php"
# La API de Wikimedia pide un User-Agent que identifique a quien llama; con el generico contesta
# 403. Esta documentado en su politica de uso.
UA = "Mentis/1.0 (asistente personal de escritorio; uso no comercial)"

# Formatos que python-docx / reportlab / python-pptx saben insertar. Un.svg o un.tif entra en
# los resultados de Commons y despues revienta al armar el documento.
EXT_OK = (".jpg", ".jpeg", ".png", ".gif")


def _limpiar(html):
    return re.sub(r"\s+", " ", re.sub("<[^>]+>", "", html or "")).strip()


def buscar(consulta, limite=6):
    url = (API + "?action=query&format=json&generator=search&gsrnamespace=6"
           "&gsrlimit=%d&gsrsearch=%s&prop=imageinfo&iiprop=url|extmetadata|size&iiurlwidth=1024"
           % (limite, urllib.parse.quote(consulta)))
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=25) as r:
        d = json.load(r)
    paginas = (d.get("query") or {}).get("pages") or {}
    salida = []
    for p in paginas.values():
        ii = (p.get("imageinfo") or [{}])[0]
        em = ii.get("extmetadata") or {}
        directa = ii.get("thumburl") or ii.get("url") or ""
        if not directa:
            continue
        if not any(directa.lower().split("?")[0].endswith(e) for e in EXT_OK):
            continue
        salida.append({
            "titulo": _limpiar(p.get("title", "")).replace("File:", ""),
            "url": directa,
            "pagina": ii.get("descriptionurl") or "",
            "autor": _limpiar((em.get("Artist") or {}).get("value")) or "autor no indicado",
            "licencia": _limpiar((em.get("LicenseShortName") or {}).get("value")) or "ver la pagina del archivo",
            "indice": p.get("index", 99),
        })
    salida.sort(key=lambda x: x["indice"])
    return salida


def bajar(cand, dest, nombre):
    os.makedirs(dest, exist_ok=True)
    ext = os.path.splitext(cand["url"].split("?")[0])[1].lower() or ".jpg"
    ruta = dest.replace("\\", "/").rstrip("/") + "/" + nombre + ext
    req = urllib.request.Request(cand["url"], headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=45) as r:
        datos = r.read()
    if len(datos) < 1500:
        raise ValueError("la descarga vino vacia o demasiado chica (%d bytes)" % len(datos))
    with open(ruta, "wb") as f:
        f.write(datos)

    # NORMALIZAR SIEMPRE, aunque el archivo ya sea un JPEG valido.
    #
    # Medido con un caso real: una foto de Commons que PIL abre sin chistar (JPEG 500x707 RGB)
    # hacia estallar a python-docx con UnrecognizedImageError **y mensaje de error vacio**.
    # python-docx no usa PIL: trae su propio lector de encabezados, mas estricto, y rechaza
    # JPEGs progresivos, en CMYK o con segmentos APP raros -- que en un banco de fotos de
    # internet son moneda corriente.
    #
    # Reescribir la imagen con PIL la deja en linea base, RGB y sin metadatos exoticos, que es lo
    # que entienden por igual python-docx, reportlab y python-pptx. Sale casi gratis y evita que
    # el documento salga con un "[no se pudo insertar la imagen]" en el medio.
    try:
        from PIL import Image
        with Image.open(ruta) as im:
            im = im.convert("RGB")
            # Ademas se acota el tamaño: una foto de 6000 px de Commons infla el documento a
            # decenas de MB sin que se vea mejor en una hoja A4.
            im.thumbnail((1600, 1600))
            limpia = dest.replace("\\", "/").rstrip("/") + "/" + nombre + ".jpg"
            im.save(limpia, "JPEG", quality=88)
        if limpia != ruta and os.path.exists(ruta):
            os.remove(ruta)
        ruta = limpia
    except Exception:
        # Si PIL no puede, se deja el original: puede que igual sirva. Peor seria quedarse sin
        # imagen por no haber podido limpiarla.
        pass
    return ruta, os.path.getsize(ruta)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("consulta")
    ap.add_argument("--dest", required=True)
    ap.add_argument("--nombre", default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        cands = buscar(args.consulta)
    except Exception as e:
        sys.stderr.write("no pude buscar: %s: %s\n" % (type(e).__name__, str(e)[:150]))
        return 1
    if not cands:
        sys.stderr.write("sin resultados usables para: %s\n" % args.consulta)
        return 2

    base = args.nombre or re.sub(r"[^a-z0-9]+", "-", args.consulta.lower()).strip("-")[:40] or "img"

    # Se prueban varios candidatos: el primero puede fallar la descarga (archivo movido, tamaño
    # raro) y no tiene sentido rendirse con cinco alternativas esperando.
    ultimo = ""
    for i, c in enumerate(cands[:4]):
        try:
            ruta, bytes_ = bajar(c, args.dest, base)
        except Exception as e:
            ultimo = "%s: %s" % (type(e).__name__, str(e)[:80])
            continue
        res = {"ruta": ruta, "bytes": bytes_, "titulo": c["titulo"], "autor": c["autor"],
               "licencia": c["licencia"], "pagina": c["pagina"],
               "atribucion": "%s -- %s (%s), via Wikimedia Commons" % (c["titulo"], c["autor"], c["licencia"])}
        if args.json:
            print(json.dumps(res, ensure_ascii=False))
        else:
            print(res["ruta"])
            sys.stderr.write("ATRIBUCION=%s\n" % res["atribucion"])
        return 0

    sys.stderr.write("encontre %d candidatos pero ninguno se pudo bajar. Ultimo error: %s\n"
                     % (len(cands), ultimo))
    return 3


if __name__ == "__main__":
    sys.exit(main())
