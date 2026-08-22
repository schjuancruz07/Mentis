#!/usr/bin/env python3
"""tavily_buscar.py -- busca en la web con Tavily y devuelve texto plano. (2026-08-15)

    TAVILY_API_KEY=... tavily_buscar.py "que quiero buscar"

POR QUE EXISTE ESTE ARCHIVO Y NO UN python3 -c ADENTRO DE nv-agent.sh:
    La primera version iba embebida como `python3 -c '...'` en el bash. Los "\\n" de los formatos
    se convirtieron en saltos de linea REALES al escribir el archivo, el string de Python quedo
    partido a la mitad y el codigo no compilaba -- o sea que Tavily nunca habria funcionado dentro
    del motor, y encima en silencio: el `2>/dev/null` se comia el error de sintaxis y el bash veia
    una respuesta vacia, indistinguible de "Tavily no encontro nada".
    Un archivo propio no tiene ese problema, se puede correr a mano para probarlo, y se puede leer.

POR QUE TAVILY:
    Desde esta red, Bing, DuckDuckGo y Mojeek devuelven CAPTCHA (esta medido en _urls_de_busqueda).
    Quedaban Marginalia -- indice independiente y chico -- y Wikipedia. Tavily es una API pensada
    para agentes: uno se identifica con una clave en vez de disimular ser un navegador.

SALIDA: un bloque de texto por resultado (titulo, url, extracto). Si algo falla -- no hay clave, no
hay red, la respuesta no es JSON -- imprime NADA y sale con 0. Quien llama interpreta "vacio" como
"no hubo resultados" y sigue con la escalera de buscadores de siempre. Fallar ruidosamente aca
cortaria una busqueda que igual podria resolverse por el camino viejo.
"""
import json
import os
import sys as _sys

# LA SALIDA VA EN UTF-8, SIEMPRE (2026-08-20). Sin esto, el archivo funcionaba y moria al final:
# la busqueda salia bien, y al IMPRIMIR el resultado, python en Windows usa cp1252 por defecto y
# tiraba UnicodeEncodeError con cualquier acento, comilla curva o emoji -- o sea, con casi todo
# resultado real, en español mas todavia.
#
# Y no se veia: nv-agent.sh llama a este archivo con 2>/dev/null, asi que el error se perdia y el
# motor recibia una salida VACIA, indistinguible de "no encontre nada". Medido en una tarea real:
# el modelo pidio buscar 25 VECES SEGUIDAS -- gasto el presupuesto entero del turno y no entrego
# nada -- porque cada busqueda le devolvia el vacio y volvia a intentar.
#
# Es la misma clase de error que el comentario de arriba ya documenta para el `python3 -c`: el
# archivo propio arreglo aquella causa, y esta entro por la puerta de al lado.
for _f in (_sys.stdout, _sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
import sys
import urllib.error
import urllib.request

MAX_RESULTADOS = 5


def buscar(consulta, clave):
    pedido = {"query": consulta, "max_results": MAX_RESULTADOS, "search_depth": "basic"}
    req = urllib.request.Request(
        "https://api.tavily.com/search",
        data=json.dumps(pedido).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": "Bearer " + clave,
            "Content-Type": "application/json",
            # User-Agent propio: el default de urllib ("Python-urllib/3.x") lo rechazan varios
            # proveedores detras de Cloudflare con un 403. Ver ERR-157.
            "User-Agent": "Mentis/1.0 (+https://github.com/usuario/Mentis)",
        },
    )
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def main():
    consulta = " ".join(sys.argv[1:]).strip()
    clave = (os.environ.get("TAVILY_API_KEY") or "").strip()
    if not consulta or not clave:
        return 0
    try:
        datos = buscar(consulta, clave)
    except Exception:
        return 0

    partes = []
    for r in (datos.get("results") or [])[:MAX_RESULTADOS]:
        titulo = (r.get("title") or "")[:120]
        url = r.get("url") or ""
        extracto = (r.get("content") or "")[:300].replace("\n", " ")
        partes.append("- %s\n  %s\n  %s" % (titulo, url, extracto))

    # La respuesta directa de Tavily, cuando la trae, va primero: suele contestar la pregunta sin
    # que haya que abrir ninguna de las paginas.
    respuesta = (datos.get("answer") or "").strip()
    if respuesta:
        partes.insert(0, "Respuesta corta: " + respuesta[:400])

    if partes:
        sys.stdout.write("\n".join(partes) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
