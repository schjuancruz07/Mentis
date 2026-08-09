#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_multimodal.py -- examen de VISION real para el rol 'multimodal' (2026-08-02).

POR QUE EXISTE
    Hasta hoy el rol 'multimodal' tenía UN fixture, y era de texto: "responde listo". O sea que
    el rol que existe para MIRAR nunca se probó mirando. Un modelo puede sacar 1/1 en ese examen
    y describir una foto en negro como si hubiera visto algo (que es exactamente el bug que
    mentis-webcam.sh tuvo que empezar a detectar midiendo el brillo).

POR QUE LAS IMAGENES SE GENERAN Y NO SE DESCARGAN
    Porque hace falta saber la respuesta con certeza. Una foto de internet se puede interpretar
    de diez maneras y el que corrige termina siendo el que decide. Un círculo rojo dibujado por
    este script es rojo, redondo y uno solo: no hay nada que discutir. Es la misma idea de los
    fixtures por rol -- respuesta verificable sola.

    Incluye a propósito una imagen COMPLETAMENTE NEGRA. Un modelo honesto dice que está negra;
    uno que alucina describe una escena. Ese caso vale por sí solo.

Uso: NVIDIA_API_KEY=... python3 bench_multimodal.py -o salida.jsonl -m mod1,mod2
"""
import argparse, base64, json, os, re, sys, time
import urllib.request, urllib.error
from PIL import Image, ImageDraw, ImageFont

URL = os.environ.get("NV_URL", "https://integrate.api.nvidia.com/v1/chat/completions")
AQUI = os.path.dirname(os.path.abspath(__file__))
IMGDIR = os.path.join(AQUI, "datos", "vision")
PAUSA = float(os.environ.get("BM_PAUSA", "2.0"))

BLANCO = (255, 255, 255)


def _fuente(tam):
    """Una fuente que se vea. Sin esto el texto sale de 11px y ni un humano lo lee."""
    for n in ("arial.ttf", "DejaVuSans.ttf", "segoeui.ttf"):
        try:
            return ImageFont.truetype(n, tam)
        except Exception:
            continue
    return ImageFont.load_default()


def generar():
    """Dibuja las 10 imágenes. Devuelve [(archivo, pregunta, tipo, esperado)]."""
    os.makedirs(IMGDIR, exist_ok=True)
    casos = []

    def nueva(nombre, color=BLANCO, tam=(400, 400)):
        im = Image.new("RGB", tam, color)
        return im, ImageDraw.Draw(im), os.path.join(IMGDIR, nombre)

    im, d, r = nueva("01-circulo-rojo.png")
    d.ellipse([100, 100, 300, 300], fill=(220, 20, 20))
    im.save(r)
    casos.append((r, "De que color es la figura que se ve en la imagen? Responde con una sola palabra.", "contiene", "rojo"))

    im, d, r = nueva("02-numero-42.png")
    d.text((110, 140), "42", fill=(0, 0, 0), font=_fuente(160))
    im.save(r)
    casos.append((r, "Que numero se ve en la imagen? Responde solo el numero.", "numero", "42-42"))

    im, d, r = nueva("03-tres-cuadrados.png")
    for i in range(3):
        d.rectangle([40 + i * 120, 160, 140 + i * 120, 260], fill=(30, 60, 200))
    im.save(r)
    casos.append((r, "Cuantos cuadrados hay en la imagen? Responde solo el numero.", "numero", "3-3"))

    im, d, r = nueva("04-palabra-mentis.png")
    d.text((40, 160), "MENTIS", fill=(0, 0, 0), font=_fuente(90))
    im.save(r)
    casos.append((r, "Que palabra esta escrita en la imagen? Responde solo la palabra.", "contiene", "mentis"))

    im, d, r = nueva("05-triangulo-verde.png")
    d.polygon([(200, 80), (330, 320), (70, 320)], fill=(20, 160, 60))
    im.save(r)
    casos.append((r, "Que figura geometrica se ve en la imagen? Responde con una sola palabra.", "contiene", "triangul"))

    im, d, r = nueva("06-barras.png")
    for i, alto in enumerate((80, 160, 280)):
        d.rectangle([60 + i * 110, 340 - alto, 150 + i * 110, 340], fill=(80, 80, 80))
    im.save(r)
    casos.append((r, "En este grafico de barras, cual barra es la mas alta: la izquierda, la del medio o la derecha? Responde con una sola palabra.", "contiene", "derecha"))

    im, d, r = nueva("07-todo-negro.png", color=(0, 0, 0))
    im.save(r)
    casos.append((r, "Que se ve en esta imagen? Si esta completamente vacia o en negro, responde exactamente: negro", "contiene", "negro"))

    im, d, r = nueva("08-dos-figuras.png")
    d.ellipse([40, 150, 180, 290], fill=(220, 20, 20))
    d.rectangle([230, 150, 370, 290], fill=(30, 60, 200))
    im.save(r)
    casos.append((r, "De que color es la figura que esta a la DERECHA de la imagen? Responde con una sola palabra.", "contiene", "azul"))

    im, d, r = nueva("09-total-1234.png")
    d.text((40, 170), "TOTAL: 1234", fill=(0, 0, 0), font=_fuente(60))
    im.save(r)
    casos.append((r, "Que numero aparece escrito en la imagen? Responde solo el numero.", "numero", "1234-1234"))

    im, d, r = nueva("10-cinco-puntos.png")
    for i in range(5):
        d.ellipse([40 + i * 70, 180, 80 + i * 70, 220], fill=(0, 0, 0))
    im.save(r)
    casos.append((r, "Cuantos puntos negros hay en la imagen? Responde solo el numero.", "numero", "5-5"))

    return casos


NORM = str.maketrans("áàäâéèëêíìïîóòöôúùüûñ", "aaaaeeeeiiiioooouuuun")


def aprueba(resp, tipo, esp):
    if tipo == "contiene":
        return esp.lower().translate(NORM) in resp.lower().translate(NORM)
    if tipo == "numero":
        mn, mx = esp.split("-")
        nums = re.findall(r"-?\d+", resp)
        if not nums:
            return False
        # El PRIMER numero: se pide "responde solo el numero", asi que el primero es la respuesta.
        # (En GSM8K se toma el ultimo, porque ahi si se pide razonar paso a paso. No es lo mismo.)
        return int(mn) <= int(nums[0]) <= int(mx)
    return False


def pedir(modelo, key, pregunta, ruta):
    with open(ruta, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    cuerpo = json.dumps({
        "model": modelo,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": pregunta},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
        ]}],
        "max_tokens": 512,
        "temperature": 0,
    }).encode("utf-8")
    req = urllib.request.Request(URL, data=cuerpo, method="POST", headers={
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return "", "HTTP %s" % e.code
    except Exception as e:
        return "", type(e).__name__
    msg = ((d.get("choices") or [{}])[0].get("message") or {})
    return ((msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()), None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("-o", "--salida", required=True)
    p.add_argument("-m", "--modelos", required=True)
    args = p.parse_args()

    key = os.environ.get("NVIDIA_API_KEY", "")
    if not key:
        print("Sin NVIDIA_API_KEY.", file=sys.stderr)
        return 1

    casos = generar()
    print("[multimodal] %d imagenes generadas en %s" % (len(casos), IMGDIR), file=sys.stderr)

    hechas = set()
    if os.path.exists(args.salida):
        with open(args.salida, encoding="utf-8") as f:
            for l in f:
                try:
                    hechas.add(json.loads(l)["clave"])
                except Exception:
                    pass

    for modelo in [m.strip() for m in args.modelos.split(",") if m.strip()]:
        bien = tot = 0
        for i, (ruta, preg, tipo, esp) in enumerate(casos):
            clave = "vision|%s|%d" % (modelo, i)
            if clave in hechas:
                continue
            t0 = time.time()
            txt, err = pedir(modelo, key, preg, ruta)
            ms = int((time.time() - t0) * 1000)
            ok = None if err else int(aprueba(txt, tipo, esp))
            tot += 1
            if ok:
                bien += 1
            with open(args.salida, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "clave": clave, "bench": "vision", "modelo": modelo, "caso": i,
                    "imagen": os.path.basename(ruta), "ok": ok, "ms": ms,
                    "esperado": esp, "detalle": err or "", "resp": (txt or "")[:300],
                }, ensure_ascii=False) + "\n")
            estado = "ERROR" if ok is None else ("OK" if ok else "FALLO")
            print("[vision] %s / %s -> %s (%dms) %s" % (modelo, os.path.basename(ruta), estado, ms, (err or txt)[:60]),
                  file=sys.stderr, flush=True)
            time.sleep(PAUSA)
        if tot:
            print("[vision] == %s: %d/%d ==" % (modelo, bien, tot), file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
