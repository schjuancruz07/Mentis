#!/usr/bin/env python3
"""nv_tts_server.py -- servidor de voz siempre encendido (2026-07-27).

POR QUE EXISTE (medido, no supuesto):
    mentis-tts.sh armaba TODO de cero en cada llamada: arrancar python, importar riva.client,
    autenticar y abrir la conexion gRPC. Medido en esta maquina:

        "Hola."                  -> 2,70 s      <- costo FIJO, casi todo antes de sintetizar
        frase mediana            -> 3,34 s
        respuesta de 4 frases    -> 4,87 s

        arrancar python.......... 0,33 s
        importar la libreria..... 0,54 s
        resto (auth + gRPC + red)  ~1,8 s

    Ese costo fijo es el que impedia que Mentis hablara por frases: partir una respuesta en
    cuatro y pagar 2,7 s por cada una daba huecos audibles entre oracion y oracion. Con la
    conexion ya abierta el costo por frase baja lo suficiente como para que la siguiente este
    lista ANTES de que termine la que esta sonando -- que es la unica forma de que hablar por
    partes suene natural en vez de entrecortado.

    Es el mismo patron que arreglo la transcripcion (nv_stt_server.py, 59 s -> 1,4 s): lo caro
    no era el trabajo, era prepararse para hacerlo.

Uso:
    nv_tts_server.py --puerto 0 --estado ruta/estado.json
    POST /decir   {"texto": "...", "salida": "C:\\...\\x.wav"}  -> {"ok": true, "ruta": "..."}
    GET  /salud                                                  -> {"ok": true,...}
    POST /apagar                                                 -> se apaga
"""
import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICIO = None          # SpeechSynthesisService, creado una sola vez
LISTO_EN = None
SINTESIS = 0
LOCK = threading.Lock()
CFG = {}


def preparar():
    """Autentica y abre la conexion gRPC UNA vez. Esto es lo que se pagaba en cada llamada."""
    global SERVICIO, LISTO_EN
    import riva.client
    t0 = time.time()
    auth = riva.client.Auth(
        None, True, CFG["servidor"],
        [["function-id", CFG["function_id"]], ["authorization", "Bearer " + CFG["api_key"]]],
    )
    SERVICIO = riva.client.SpeechSynthesisService(auth)
    LISTO_EN = time.time() - t0
    print("voz lista en %.1fs" % LISTO_EN, file=sys.stderr, flush=True)


def decir(texto, ruta_salida):
    import riva.client
    import wave
    if SERVICIO is None:
        return {"ok": False, "error": "el servicio de voz todavia no termino de conectar"}
    if not (texto or "").strip():
        return {"ok": False, "error": "no hay texto para decir"}
    global SINTESIS
    t0 = time.time()
    # Una sintesis a la vez: el servicio gRPC es uno solo y dos pedidos simultaneos sobre la
    # misma conexion se estorban.
    with LOCK:
        resp = SERVICIO.synthesize(
            text=texto,
            voice_name=CFG["voz"],
            language_code=CFG["idioma"],
            encoding=riva.client.AudioEncoding.LINEAR_PCM,
            sample_rate_hz=CFG["sample_rate"],
        )
        os.makedirs(os.path.dirname(ruta_salida) or ".", exist_ok=True)
        with wave.open(ruta_salida, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(CFG["sample_rate"])
            w.writeframes(resp.audio)
    SINTESIS += 1
    return {"ok": True, "ruta": ruta_salida, "segundos": round(time.time() - t0, 2),
            "bytes": len(resp.audio)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _responder(self, codigo, cuerpo):
        datos = json.dumps(cuerpo, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def do_GET(self):
        if self.path == "/salud":
            self._responder(200, {"ok": SERVICIO is not None, "voz": CFG.get("voz"),
                                  "listo_segundos": round(LISTO_EN or 0, 1), "sintesis": SINTESIS})
            return
        self._responder(404, {"ok": False, "error": "ruta desconocida"})

    def do_POST(self):
        largo = int(self.headers.get("Content-Length") or 0)
        crudo = self.rfile.read(largo) if largo else b"{}"
        if self.path == "/apagar":
            self._responder(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        # /decir-plano: el cuerpo es la RUTA DE SALIDA en la primera linea y el texto en el
        # resto. Sin JSON a proposito -- armar el JSON del pedido obligaba a arrancar python en
        # el cliente, y en Windows cada arranque del interprete cuesta cerca de 1,5 s. Es la
        # misma leccion que ya se habia aprendido en mentis-transcribe.sh: de nada sirve un
        # servidor rapido si para hablarle hay que pagar un interprete.
        if self.path == "/decir-plano":
            texto_crudo = crudo.decode("utf-8", errors="replace")
            salida, _, texto = texto_crudo.partition("\n")
            try:
                self._responder(200, decir(texto, salida.strip()))
            except Exception as e:
                self._responder(500, {"ok": False, "error": str(e)[:300]})
            return
        if self.path != "/decir":
            self._responder(404, {"ok": False, "error": "ruta desconocida"})
            return
        try:
            pedido = json.loads(crudo.decode("utf-8", errors="replace"))
        except Exception:
            self._responder(400, {"ok": False, "error": "cuerpo JSON invalido"})
            return
        try:
            self._responder(200, decir(pedido.get("texto") or "", pedido.get("salida") or ""))
        except Exception as e:
            self._responder(500, {"ok": False, "error": str(e)[:300]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--puerto", type=int, default=0)
    ap.add_argument("--estado", required=True)
    ap.add_argument("--api-key", required=True)
    ap.add_argument("--function-id", required=True)
    ap.add_argument("--servidor", default="grpc.nvcf.nvidia.com:443")
    ap.add_argument("--voz", required=True)
    ap.add_argument("--idioma", default="es-US")
    ap.add_argument("--sample-rate", type=int, default=44100)
    args = ap.parse_args()

    CFG.update(api_key=args.api_key, function_id=args.function_id, servidor=args.servidor,
               voz=args.voz, idioma=args.idioma, sample_rate=args.sample_rate)

    servidor = ThreadingHTTPServer(("127.0.0.1", args.puerto), Handler)
    puerto = servidor.server_address[1]
    with open(args.estado, "w", encoding="utf-8") as f:
        json.dump({"puerto": puerto, "pid": os.getpid(), "voz": args.voz, "iniciado": time.time()}, f)
    print("escuchando en 127.0.0.1:%d" % puerto, file=sys.stderr, flush=True)

    # Conectar en segundo plano: /salud tiene que contestar desde el primer instante para que
    # quien espera sepa que el puerto ya existe aunque la voz todavia no este lista.
    threading.Thread(target=preparar, daemon=True).start()

    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.remove(args.estado)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
