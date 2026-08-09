#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lsp_client.py -- cliente LSP minimo para Mentis (2026-08-02, revision total).

POR QUE EXISTE
    Era el ultimo hueco del inventario contra Claude Code. Sin conocimiento del lenguaje, la
    herramienta `search` de Mentis es texto plano: buscar "def procesar" encuentra la definicion y
    tambien cada comentario que menciona la palabra, y no encuentra nada si la funcion se llama
    distinto de como el modelo supuso. Con LSP se puede preguntar "donde se DEFINE este simbolo" y
    "quien lo USA", que son preguntas sobre el codigo y no sobre el texto.

QUE HACE Y QUE NO
    Habla el protocolo LSP por stdio con un servidor de lenguaje: handshake, abrir el archivo, y
    cuatro consultas -- definicion, referencias, simbolos del archivo y diagnosticos.
    NO es un editor: no aplica cambios, no renombra, no formatea. Solo pregunta.

POR QUE NO SE USO UNA LIBRERIA
    Las que hay traen un cliente asincrono completo con su propio bucle de eventos. Acá hace falta
    lo contrario: un proceso corto que arranca, pregunta una cosa y se muere, para que el agente lo
    invoque como cualquier otra herramienta. El protocolo que se usa son tres mensajes.

LAS TRAMPAS DE ESTE ENTORNO QUE YA ESTAN RESUELTAS ACA
    1. LSP identifica archivos por URI, no por ruta. En Windows la URI es file:///C:/Users/... con
       barras normales y letra de unidad -- una ruta MSYS (/c/Users/...) no sirve, y pasarla hace
       que el servidor conteste "no conozco ese archivo" sin ningun error visible.
    2. El framing es por bytes (Content-Length), no por lineas. Se lee del buffer binario: con
       texto, Windows traduce saltos de linea y el largo deja de coincidir.
    3. El servidor puede mandar mensajes propios (progreso, logs) intercalados con la respuesta.
       Hay que leer hasta encontrar el id que se pidio, no quedarse con el primero que llega.

Uso:
    python3 lsp_client.py definicion  --archivo X.py --linea 10 --columna 4 [--raiz DIR]
    python3 lsp_client.py referencias --archivo X.py --linea 10 --columna 4
    python3 lsp_client.py simbolos    --archivo X.py
    python3 lsp_client.py diagnosticos --archivo X.py
    python3 lsp_client.py servidores   (dice que hay configurado y que esta instalado)
"""
import argparse, json, os, shutil, subprocess, sys, threading, time

AQUI = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(AQUI, "lsp-servidores.json")

# Registro por defecto. Vive en un JSON aparte para que agregar un lenguaje no sea tocar codigo:
# es la misma idea que modelos-override.json, y por la misma razon (los datos cambian mas seguido
# que la logica). Lo de acá abajo se usa sólo si el JSON no existe.
POR_DEFECTO = {
    ".py":  {"cmd": ["pyright-langserver", "--stdio"], "lenguaje": "python",
             "instalar": "npm i -g pyright"},
    ".sh":  {"cmd": ["bash-language-server", "start"], "lenguaje": "shellscript",
             "instalar": "npm i -g bash-language-server"},
    ".bash": {"cmd": ["bash-language-server", "start"], "lenguaje": "shellscript",
              "instalar": "npm i -g bash-language-server"},
    ".js":  {"cmd": ["typescript-language-server", "--stdio"], "lenguaje": "javascript",
             "instalar": "npm i -g typescript typescript-language-server"},
    ".mjs": {"cmd": ["typescript-language-server", "--stdio"], "lenguaje": "javascript",
             "instalar": "npm i -g typescript typescript-language-server"},
    ".ts":  {"cmd": ["typescript-language-server", "--stdio"], "lenguaje": "typescript",
             "instalar": "npm i -g typescript typescript-language-server"},
}


def registro():
    if os.path.exists(CONFIG):
        try:
            with open(CONFIG, encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict) and d:
                return d
        except Exception:
            pass
    return POR_DEFECTO


def a_uri(ruta):
    """Ruta del sistema -> URI file://. En Windows: file:///C:/Users/...

    Es el punto donde mas facil se rompe todo en esta maquina: el agente maneja rutas MSYS
    (/c/Users/...) y el servidor de lenguaje espera una ruta de Windows. Si se le manda la MSYS,
    responde "no conozco ese archivo" sin decir que la ruta estaba mal.
    """
    p = os.path.abspath(ruta)
    if os.name == "nt" or (len(p) > 1 and p[1] == ":"):
        return "file:///" + p.replace("\\", "/")
    return "file://" + p


def de_uri(uri):
    if not uri:
        return ""
    p = uri[len("file://"):] if uri.startswith("file://") else uri
    if p.startswith("/") and len(p) > 2 and p[2] == ":":
        p = p[1:]
    return p.replace("/", os.sep) if os.name == "nt" else p


def resolver_cmd(cmd):
    """Convierte el comando configurado en algo que Popen pueda lanzar EN ESTA MAQUINA.

    Dos trampas de Windows que hacen fallar esto justo cuando empieza a servir de verdad:

    1. Los servidores de lenguaje instalados con npm quedan como **.cmd**, no como.exe
       (bash-language-server.cmd, typescript-language-server.cmd). Popen sin shell no puede
       lanzar un.cmd: tira WinError 216 o ENOENT. Es el mismo problema que ya estaba documentado
       en app/main.js para el comando 'code' de VS Code.
    2. 'python3' en esta maquina es un shim de bash (~/bin/python3 -> py -3), no un ejecutable
       nativo; desde Python hay que usar sys.executable. Es ERR-011 + ERR-101.

    Sin esto, todo el cliente anda perfecto contra un servidor de prueba y explota el dia que se
    instala uno real -- que es el peor momento posible para descubrirlo.
    """
    if not cmd:
        return cmd
    prog, resto = cmd[0], list(cmd[1:])
    if prog in ("python3", "python"):
        return [sys.executable] + resto
    ruta = shutil.which(prog)
    if not ruta:
        return cmd
    if os.name == "nt" and ruta.lower().endswith((".cmd", ".bat")):
        # cmd /c es la unica forma de arrancar un.cmd sin shell=True (que ademas concatena los
        # argumentos sin escapar, justo lo que el aviso DEP0190 de Node advierte).
        return ["cmd", "/c", ruta] + resto
    return [ruta] + resto


class Servidor:
    def __init__(self, cmd, raiz):
        self.proc = subprocess.Popen(
            resolver_cmd(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd=raiz)
        self.id = 0
        self.pendientes = {}
        self.notificaciones = []
        self.vivo = True
        self.hilo = threading.Thread(target=self._leer, daemon=True)
        self.hilo.start()

    def _leer(self):
        """Lee frames del servidor. En BINARIO: el largo del header cuenta bytes, y leer en modo
        texto en Windows traduce saltos de linea y desalinea todo."""
        buf = b""
        while self.vivo:
            try:
                trozo = self.proc.stdout.read(1)
            except Exception:
                break
            if not trozo:
                break
            buf += trozo
            if buf.endswith(b"\r\n\r\n"):
                largo = 0
                for linea in buf.split(b"\r\n"):
                    if linea.lower().startswith(b"content-length:"):
                        largo = int(linea.split(b":")[1].strip())
                cuerpo = b""
                while len(cuerpo) < largo:
                    parte = self.proc.stdout.read(largo - len(cuerpo))
                    if not parte:
                        break
                    cuerpo += parte
                buf = b""
                try:
                    msg = json.loads(cuerpo.decode("utf-8", "replace"))
                except Exception:
                    continue
                if "id" in msg and ("result" in msg or "error" in msg):
                    self.pendientes[msg["id"]] = msg
                else:
                    self.notificaciones.append(msg)

    def _mandar(self, obj):
        cuerpo = json.dumps(obj).encode("utf-8")
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(cuerpo) + cuerpo)
        self.proc.stdin.flush()

    def pedir(self, metodo, params, espera=20):
        self.id += 1
        mio = self.id
        self._mandar({"jsonrpc": "2.0", "id": mio, "method": metodo, "params": params})
        # Se espera EL id propio: el servidor intercala notificaciones de progreso y logs, y
        # quedarse con el primer mensaje que llega devuelve cualquier cosa.
        limite = time.time() + espera
        while time.time() < limite:
            if mio in self.pendientes:
                return self.pendientes.pop(mio)
            time.sleep(0.02)
        return {"error": {"message": "el servidor de lenguaje no contesto en %ss" % espera}}

    def avisar(self, metodo, params):
        self._mandar({"jsonrpc": "2.0", "method": metodo, "params": params})

    def cerrar(self):
        try:
            self.pedir("shutdown", None, espera=3)
            self.avisar("exit", None)
        except Exception:
            pass
        self.vivo = False
        try:
            self.proc.terminate()
        except Exception:
            pass


def abrir(servidor, raiz, archivo, lenguaje):
    servidor.pedir("initialize", {
        "processId": os.getpid(),
        "rootUri": a_uri(raiz),
        "capabilities": {"textDocument": {
            "definition": {}, "references": {}, "documentSymbol": {},
            "publishDiagnostics": {},
        }},
    }, espera=30)
    servidor.avisar("initialized", {})
    with open(archivo, encoding="utf-8", errors="replace") as f:
        texto = f.read()
    servidor.avisar("textDocument/didOpen", {"textDocument": {
        "uri": a_uri(archivo), "languageId": lenguaje, "version": 1, "text": texto}})
    return texto


def formatear_lugares(res):
    """Las respuestas de definicion/referencias vienen en tres formas distintas segun el servidor
    (una ubicacion, una lista, o LocationLink). Se normalizan las tres."""
    if not res:
        return []
    if isinstance(res, dict):
        res = [res]
    salida = []
    for x in res:
        if not isinstance(x, dict):
            continue
        uri = x.get("uri") or x.get("targetUri") or ""
        rango = x.get("range") or x.get("targetSelectionRange") or x.get("targetRange") or {}
        ini = (rango.get("start") or {})
        salida.append({"archivo": de_uri(uri),
                       "linea": ini.get("line", 0) + 1,
                       "columna": ini.get("character", 0) + 1})
    return salida


CLASES = {1: "archivo", 2: "modulo", 5: "clase", 6: "metodo", 12: "funcion", 13: "variable",
          14: "constante"}


def aplanar_simbolos(res, nivel=0):
    out = []
    for s in (res or []):
        if not isinstance(s, dict):
            continue
        loc = s.get("location") or {}
        rango = s.get("range") or (loc.get("range") or {})
        out.append({"nombre": s.get("name", ""),
                    "clase": CLASES.get(s.get("kind"), str(s.get("kind", ""))),
                    "linea": ((rango.get("start") or {}).get("line", 0)) + 1,
                    "nivel": nivel})
        out.extend(aplanar_simbolos(s.get("children"), nivel + 1))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("accion", choices=["definicion", "referencias", "simbolos", "diagnosticos", "servidores"])
    p.add_argument("--archivo")
    p.add_argument("--linea", type=int, default=1)
    p.add_argument("--columna", type=int, default=1)
    p.add_argument("--raiz")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()

    reg = registro()

    if a.accion == "servidores":
        print("Servidores de lenguaje configurados:")
        vistos = {}
        for ext, cfg in reg.items():
            clave = cfg["cmd"][0]
            vistos.setdefault(clave, {"exts": [], "cfg": cfg})["exts"].append(ext)
        for clave, v in vistos.items():
            hay = shutil.which(clave) is not None
            print("  %-32s %s   (%s)" % (clave, "INSTALADO" if hay else "no instalado",
                                         " ".join(v["exts"])))
            if not hay:
                print("      para instalarlo: %s" % v["cfg"].get("instalar", "?"))
        return 0

    if not a.archivo:
        print("Falta --archivo", file=sys.stderr)
        return 2
    archivo = os.path.abspath(a.archivo)
    if not os.path.isfile(archivo):
        print("No existe el archivo: %s" % a.archivo, file=sys.stderr)
        return 2
    ext = os.path.splitext(archivo)[1].lower()
    cfg = reg.get(ext)
    if not cfg:
        print("No hay servidor de lenguaje configurado para '%s'. Configurados: %s"
              % (ext, ", ".join(sorted(reg))), file=sys.stderr)
        return 3
    if shutil.which(cfg["cmd"][0]) is None:
        # Mensaje util, no un traceback: el modelo tiene que poder decirle al usuario que instalar.
        print("El servidor de lenguaje '%s' no esta instalado. Para instalarlo: %s"
              % (cfg["cmd"][0], cfg.get("instalar", "(sin instrucciones)")), file=sys.stderr)
        return 4

    raiz = os.path.abspath(a.raiz or os.path.dirname(archivo))
    srv = Servidor(cfg["cmd"], raiz)
    try:
        abrir(srv, raiz, archivo, cfg["lenguaje"])
        pos = {"textDocument": {"uri": a_uri(archivo)},
               "position": {"line": max(a.linea - 1, 0), "character": max(a.columna - 1, 0)}}
        if a.accion == "definicion":
            r = srv.pedir("textDocument/definition", pos)
            datos = formatear_lugares(r.get("result"))
            if a.json:
                print(json.dumps(datos, ensure_ascii=False))
            elif not datos:
                print("Sin definicion encontrada en %s:%s:%s" % (a.archivo, a.linea, a.columna))
            else:
                for d in datos:
                    print("%s:%s:%s" % (d["archivo"], d["linea"], d["columna"]))
        elif a.accion == "referencias":
            pos["context"] = {"includeDeclaration": True}
            r = srv.pedir("textDocument/references", pos)
            datos = formatear_lugares(r.get("result"))
            if a.json:
                print(json.dumps(datos, ensure_ascii=False))
            elif not datos:
                print("Sin referencias en %s:%s:%s" % (a.archivo, a.linea, a.columna))
            else:
                print("%d referencia(s):" % len(datos))
                for d in datos:
                    print("  %s:%s:%s" % (d["archivo"], d["linea"], d["columna"]))
        elif a.accion == "simbolos":
            r = srv.pedir("textDocument/documentSymbol", {"textDocument": {"uri": a_uri(archivo)}})
            datos = aplanar_simbolos(r.get("result"))
            if a.json:
                print(json.dumps(datos, ensure_ascii=False))
            elif not datos:
                print("Sin simbolos en %s" % a.archivo)
            else:
                for d in datos:
                    print("%s%s  %s  (linea %s)" % ("  " * d["nivel"], d["clase"], d["nombre"], d["linea"]))
        elif a.accion == "diagnosticos":
            # Los diagnosticos NO se piden: el servidor los EMPUJA cuando termina de analizar. Por
            # eso se espera un rato mirando las notificaciones, en vez de hacer un request.
            limite = time.time() + 12
            diags = None
            while time.time() < limite:
                for n in list(srv.notificaciones):
                    if n.get("method") == "textDocument/publishDiagnostics" \
                       and de_uri((n.get("params") or {}).get("uri", "")).lower() == archivo.lower():
                        diags = (n.get("params") or {}).get("diagnostics") or []
                if diags is not None:
                    break
                time.sleep(0.1)
            if diags is None:
                print("El servidor no publico diagnosticos para %s (puede que siga analizando)." % a.archivo)
            elif a.json:
                print(json.dumps([{"linea": (d.get("range", {}).get("start", {}).get("line", 0)) + 1,
                                   "mensaje": d.get("message", ""),
                                   "severidad": d.get("severity", 0)} for d in diags], ensure_ascii=False))
            elif not diags:
                print("Sin problemas detectados en %s" % a.archivo)
            else:
                sev = {1: "ERROR", 2: "aviso", 3: "info", 4: "pista"}
                for d in diags:
                    ln = (d.get("range", {}).get("start", {}).get("line", 0)) + 1
                    print("  linea %-5s %-6s %s" % (ln, sev.get(d.get("severity"), "?"), d.get("message", "")))
    finally:
        srv.cerrar()
    return 0


if __name__ == "__main__":
    sys.exit(main())
