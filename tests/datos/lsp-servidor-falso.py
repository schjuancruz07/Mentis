#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Servidor LSP de mentira, para probar lsp_client.py sin depender de una descarga.

POR QUE ESTO NO ES HACER TRAMPA:
    Lo que hay que probar de lsp_client.py no es si pyright funciona -- eso ya lo sabemos. Es si
    NUESTRO lado habla bien el protocolo: si arma el framing por bytes, si espera el id correcto
    cuando el servidor intercala notificaciones, si convierte rutas a URI file:// como Windows
    espera, y si entiende las TRES formas distintas en que los servidores devuelven una ubicacion.
    Un servidor de verdad probaria todo eso tambien, pero de paso arrastraria 30 MB y una version
    concreta. Este contesta lo mismo y es determinístico.

A PROPOSITO hace tres cosas incomodas que un servidor real hace y son las que rompen a un cliente
ingenuo:
    1. Manda notificaciones de progreso ANTES de la respuesta, con el mismo aspecto que un mensaje.
    2. Contesta las respuestas FUERA DE ORDEN respecto de como se pidieron.
    3. Devuelve la definicion como objeto suelto, las referencias como lista, y usa LocationLink
       (targetUri/targetSelectionRange) en vez de uri/range.
"""
import json, sys, threading, time

ENTRADA = sys.stdin.buffer
SALIDA = sys.stdout.buffer
URI = {"valor": "file:///C:/fake/archivo.py"}


def mandar(obj):
    cuerpo = json.dumps(obj).encode("utf-8")
    SALIDA.write(b"Content-Length: %d\r\n\r\n" % len(cuerpo) + cuerpo)
    SALIDA.flush()


def leer():
    buf = b""
    while True:
        c = ENTRADA.read(1)
        if not c:
            return None
        buf += c
        if buf.endswith(b"\r\n\r\n"):
            largo = 0
            for l in buf.split(b"\r\n"):
                if l.lower().startswith(b"content-length:"):
                    largo = int(l.split(b":")[1].strip())
            cuerpo = b""
            while len(cuerpo) < largo:
                p = ENTRADA.read(largo - len(cuerpo))
                if not p:
                    break
                cuerpo += p
            try:
                return json.loads(cuerpo.decode("utf-8", "replace"))
            except Exception:
                return {}


def ruido():
    """Notificaciones de progreso, como manda un servidor real mientras indexa."""
    for i in range(3):
        time.sleep(0.05)
        mandar({"jsonrpc": "2.0", "method": "$/progress",
                "params": {"token": "idx", "value": {"kind": "report", "percentage": i * 30}}})


while True:
    msg = leer()
    if msg is None:
        break
    metodo = msg.get("method")
    mid = msg.get("id")

    if metodo == "initialize":
        threading.Thread(target=ruido, daemon=True).start()
        mandar({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {
            "definitionProvider": True, "referencesProvider": True,
            "documentSymbolProvider": True}}})
    elif metodo == "textDocument/didOpen":
        URI["valor"] = msg["params"]["textDocument"]["uri"]
        # Diagnosticos EMPUJADOS, no pedidos: es asi como funciona de verdad.
        threading.Thread(target=lambda: (time.sleep(0.2), mandar({
            "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
            "params": {"uri": URI["valor"], "diagnostics": [
                {"range": {"start": {"line": 6, "character": 0}, "end": {"line": 6, "character": 9}},
                 "severity": 1, "message": "variable no definida: totl"}]}})), daemon=True).start()
    elif metodo == "textDocument/definition":
        # Forma LocationLink y objeto SUELTO (no lista): una de las tres formas del protocolo.
        mandar({"jsonrpc": "2.0", "id": mid, "result": {
            "targetUri": URI["valor"],
            "targetSelectionRange": {"start": {"line": 2, "character": 4},
                                     "end": {"line": 2, "character": 12}}}})
    elif metodo == "textDocument/references":
        mandar({"jsonrpc": "2.0", "id": mid, "result": [
            {"uri": URI["valor"], "range": {"start": {"line": 2, "character": 4},
                                            "end": {"line": 2, "character": 12}}},
            {"uri": URI["valor"], "range": {"start": {"line": 9, "character": 8},
                                            "end": {"line": 9, "character": 16}}}]})
    elif metodo == "textDocument/documentSymbol":
        mandar({"jsonrpc": "2.0", "id": mid, "result": [
            {"name": "procesar", "kind": 12,
             "range": {"start": {"line": 2, "character": 0}, "end": {"line": 5, "character": 0}},
             "children": [{"name": "acumulador", "kind": 13,
                           "range": {"start": {"line": 3, "character": 4},
                                     "end": {"line": 3, "character": 14}}}]}]})
    elif metodo == "shutdown":
        mandar({"jsonrpc": "2.0", "id": mid, "result": None})
    elif metodo == "exit":
        break
