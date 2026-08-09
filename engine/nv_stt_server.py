#!/usr/bin/env python3
"""nv_stt_server.py -- servidor de transcripcion siempre encendido (2026-07-26).

POR QUE EXISTE (medido, no supuesto):
    mentis-transcribe.sh hacia whisper.load_model("small") en CADA llamada. Medido sobre 5
    segundos de audio: 59 segundos de punta a punta. De eso, 27 s eran cargar el modelo desde
    disco -- otra vez, cada vez.

    Ademas el motor importaba: openai-whisper tarda 26 s en transcribir esos mismos 5 s con
    'small'. faster-whisper (el mismo modelo, otro runtime) tarda 4,2 s; con 'base', 1,4 s.

    Medicion completa (5 s de audio, esta maquina, sin GPU):
        modelo   openai-whisper   faster-whisper
        tiny         4,9 s            0,82 s
        base         9,5 s            1,42 s
        small       26,0 s            4,19 s

    Se eligio 'base' por una razon concreta, no por promedio: 'tiny' transcribe "Mentes" en vez
    de "Mentis", lo que lo vuelve inservible para una palabra de activacion.

Con el modelo cargado una sola vez, transcribir pasa de 59 s a ~1,4 s. Esa diferencia es lo que
separa un dictado incomodo de una conversacion.

Uso:
    nv_stt_server.py --puerto 0 --estado ruta/al/estado.json [--modelo base]
    POST /transcribir  {"ruta": "C:\\...\\audio.wav"}   -> {"ok": true, "texto": "..."}
    GET  /salud                                          -> {"ok": true, "modelo": "base",...}
    POST /apagar                                         -> se apaga
"""
import argparse
import ctypes
import json
import msvcrt
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELO = None
NOMBRE_MODELO = "base"
CARGADO_EN = None
TRANSCRIPCIONES = 0
LOCK = threading.Lock()

# CANDADO: se deja abierto a proposito mientras vive el proceso. Si se cierra, Windows suelta el
# bloqueo y otro servidor puede arrancar al lado de este. Ver asegurar_instancia_unica().
CANDADO = None
CANDADO_OFFSET = 4096   # el byte del candado vive lejos del PID, que va en el offset 0
CANDADO_CABECERA = 64   # bytes reservados para el PID en texto plano

# Contexto que se le da al modelo antes de escuchar (2026-07-27). Whisper usa initial_prompt como
# "de que se viene hablando", y eso inclina la balanza en las palabras dudosas: sabiendo que puede
# aparecer "Mentis" o "boveda", deja de escribir "Mentes" o "bodega".
#
# MEDIDO sobre 5 frases (no supuesto):
#     base  tal como estaba.............. 10,8% de error,  1,45 s
#     base  + este prompt + beam_size=5...  7,7% de error,  1,48 s   <- se eligio este
#     small tal como estaba.............. 10,2% de error,  3,75 s
#     small + este prompt + beam_size=5...  7,7% de error,  4,30 s
# small NO se justifica: da exactamente la misma calidad que base mejorado y tarda tres veces
# mas. La mejora que sirve salio de como se le pregunta al modelo, no de agrandarlo.
PROMPT_CONTEXTO = (
    "Conversacion en espanol rioplatense con Mentis, el asistente personal del usuario Cruz. "
    "Se habla de archivos, respaldos, la boveda, Windows, la calculadora, informes, "
    "el clima, la hora y tareas programadas."
)


# ---------------------------------------------------------------------------------------------
# INSTANCIA UNICA (2026-08-03, ERR-111)
#
# QUE PASO: habia DOS servidores corriendo a la vez, arrancados con casi 5 horas de diferencia,
# cada uno con su modelo cargado: 1.617 MB + 1.619 MB de commit, la mitad tirados a la basura en
# una maquina que tenia 2.651 MB de margen total.
#
# POR QUE PASO: mentis-transcribe.sh decidia "ya hay uno" con un curl de 3 segundos contra
# /salud. Con la maquina paginando 7 GB, un servidor VIVO PERO LENTO falla ese chequeo. Ahi el
# script borraba el archivo de estado y lanzaba otro -- y el primero quedaba huerfano para
# siempre, porque ya no habia nada que apuntara a el. El mismo agujero lo abre --apagar: borra el
# estado aunque el POST /apagar haya fallado.
#
# LA RAIZ: la deteccion era por ARCHIVO. Si el archivo se pierde o el proceso tarda en contestar,
# el servidor se vuelve invisible pero no deja de existir ni de ocupar memoria.
#
# LA SOLUCION: un candado del sistema operativo, que no depende de que nadie conteste a tiempo ni
# de que ningun archivo sobreviva. Windows lo suelta solo cuando el proceso muere, incluso si
# murio a la fuerza. Medido en esta maquina antes de escribir esto:
#   - se puede bloquear un byte mas alla del fin del archivo         -> si
#   - un segundo proceso no puede tomarlo mientras el primero vive   -> confirmado
#   - el PID del que lo tiene se puede leer desde afuera             -> si, SIN buffer (ver abajo)
#   - al morir el primero, el candado queda libre sin limpiar nada   -> confirmado
# ---------------------------------------------------------------------------------------------

def _abrir_candado(ruta):
    if not os.path.exists(ruta):
        with open(ruta, "wb") as f:
            f.write(b" " * CANDADO_CABECERA)
    return open(ruta, "r+b")


def _tomar_candado(f):
    f.seek(CANDADO_OFFSET)
    try:
        msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        return True
    except OSError:
        return False


def _escribir_pid(f):
    f.seek(0)
    f.write(("%d" % os.getpid()).ljust(CANDADO_CABECERA).encode("ascii"))
    f.flush()
    os.fsync(f.fileno())


def _leer_pid(ruta):
    # SIN buffer y leyendo exactamente CANDADO_CABECERA bytes. Un lector con buffer pide 8192
    # bytes de una sola vez, se cruza con el byte bloqueado del offset 4096 y Windows contesta
    # PermissionError aunque el pedazo que uno queria leer no estuviera bloqueado. Costo media
    # hora descubrirlo en el banco de prueba; queda escrito para no repetirlo.
    try:
        fd = os.open(ruta, os.O_RDONLY | os.O_BINARY)
    except OSError:
        return None
    try:
        crudo = os.read(fd, CANDADO_CABECERA).strip()
    finally:
        os.close(fd)
    try:
        return int(crudo)
    except ValueError:
        return None


def _es_python(pid):
    """True solo si ese PID es un proceso python. Guarda contra reuso de PID: Windows recicla los
    numeros, y matar a ciegas el PID que quedo anotado puede voltear un proceso ajeno."""
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return False
    try:
        buf = ctypes.create_unicode_buffer(32768)
        n = ctypes.c_uint32(len(buf))
        if not k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
            return False
        return os.path.basename(buf.value).lower() in ("python.exe", "pythonw.exe")
    finally:
        k32.CloseHandle(h)


def asegurar_instancia_unica(ruta):
    """Garantiza que este sea el UNICO servidor de transcripcion vivo.

    Si hay otro, lo mata y ocupa su lugar en vez de negarse a arrancar. Es a proposito: el unico
    momento en que se llega aca es cuando el que llama ya no pudo hablar con el que estaba, asi
    que negarse dejaria al usuario sin dictado y con la memoria igual de ocupada.
    """
    global CANDADO
    f = _abrir_candado(ruta)
    sospechoso = None
    for _ in range(40):                      # hasta ~10 s
        if _tomar_candado(f):
            _escribir_pid(f)
            CANDADO = f
            return
        pid = _leer_pid(ruta)
        if not pid or pid == os.getpid() or pid <= 4:
            time.sleep(0.25)
            continue
        # Dos vueltas mirando el MISMO pid antes de matar. Cierra la unica ventana de carrera que
        # queda: entre que otro servidor toma el candado y alcanza a escribir su PID, el archivo
        # todavia tiene el PID de la corrida anterior -- que esta muerto y cuyo numero Windows
        # pudo haber reciclado. Si el PID cambia en la segunda vuelta, el nuevo es el bueno.
        if sospechoso != pid:
            sospechoso = pid
            time.sleep(0.3)
            continue
        if not _es_python(pid):
            print("candado ocupado por el pid %d, que no es python: no se toca" % pid,
                  file=sys.stderr, flush=True)
            time.sleep(0.25)
            continue
        print("ya habia un servidor de voz (pid %d): se lo da de baja y se ocupa su lugar" % pid,
              file=sys.stderr, flush=True)
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as e:
            print("no se pudo dar de baja el pid %d: %s" % (pid, e), file=sys.stderr, flush=True)
        sospechoso = None
        time.sleep(0.4)
    raise SystemExit("ERROR: no se pudo tomar el candado de instancia unica en %s" % ruta)


def soltar_candado(ruta):
    global CANDADO
    if CANDADO is None:
        return
    try:
        CANDADO.seek(CANDADO_OFFSET)
        msvcrt.locking(CANDADO.fileno(), msvcrt.LK_UNLCK, 1)
    except OSError:
        pass
    try:
        CANDADO.close()
    except OSError:
        pass
    CANDADO = None
    # Recien con el archivo cerrado se puede borrar: Windows no deja borrar un archivo que algun
    # proceso tiene abierto.
    try:
        os.remove(ruta)
    except OSError:
        pass


def cargar_modelo(nombre):
    global MODELO, NOMBRE_MODELO, CARGADO_EN
    from faster_whisper import WhisperModel
    t0 = time.time()
    # int8 en CPU: es lo que hace que esto sea viable sin GPU discreta.
    # cpu_threads explicito: medido, el modelo suelto transcribia en 1,47 s y dentro del
    # servidor tardaba 2,7 s. CTranslate2 elige la cantidad de hilos segun el contexto en el que
    # arranca, y dentro de un proceso servidor lanzado con nohup no siempre detecta bien cuantos
    # nucleos tiene disponibles. Se le dice explicitamente.
    hilos = os.cpu_count() or 4
    MODELO = WhisperModel(nombre, device="cpu", compute_type="int8", cpu_threads=hilos)
    NOMBRE_MODELO = nombre
    CARGADO_EN = time.time() - t0
    print("modelo '%s' cargado en %.1fs" % (nombre, CARGADO_EN), file=sys.stderr, flush=True)


def transcribir(ruta):
    global TRANSCRIPCIONES
    if MODELO is None:
        return {"ok": False, "error": "el modelo todavia no termino de cargar"}
    if not os.path.exists(ruta):
        return {"ok": False, "error": "no existe el archivo de audio: %s" % ruta}
    t0 = time.time()
    # Una sola transcripcion a la vez: dos en paralelo sobre CPU se pelean por los nucleos y
    # terminan tardando mas que en fila.
    with LOCK:
        segmentos, info = MODELO.transcribe(
            ruta, language="es", vad_filter=True,
            beam_size=5,
            initial_prompt=PROMPT_CONTEXTO,
            # Cada pedido de voz es una frase suelta, no la continuacion de la anterior. Dejarlo
            # en True hace que el modelo arrastre el texto del turno previo como contexto y, en
            # audios cortos, invente continuaciones de algo que ya no se esta diciendo.
            condition_on_previous_text=False,
        )
        # Se materializan los segmentos una sola vez: el generador de faster-whisper se consume
        # al recorrerlo, y hace falta tanto el texto como la confianza.
        segs = list(segmentos)
        texto = " ".join(s.text for s in segs).strip()
    TRANSCRIPCIONES += 1
    # CONFIANZA (2026-07-27): avg_logprob es lo que el propio modelo cree sobre lo que acaba de
    # escribir -- negativo, y cuanto mas cerca de 0, mas seguro. Ya lo calculaba en cada
    # transcripcion y se tiraba a la basura.
    # Sirve para algo concreto: el learning loop NO aprende de un turno mal escuchado. Asi nacio
    # una memoria falsa sobre el usuario a partir de "decime, quedia y soy por favor" (ERR-077).
    confianza = None
    if segs:
        vals = [s.avg_logprob for s in segs if getattr(s, "avg_logprob", None) is not None]
        if vals:
            confianza = round(sum(vals) / len(vals), 3)
    return {"ok": True, "texto": texto, "segundos": round(time.time() - t0, 2),
            "duracion_audio": round(getattr(info, "duration", 0) or 0, 2),
            "confianza": confianza}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass   # sin ruido en stderr: cada pedido loguearia una linea inutil

    def _responder(self, codigo, cuerpo):
        datos = json.dumps(cuerpo, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def do_GET(self):
        if self.path == "/salud":
            self._responder(200, {"ok": MODELO is not None, "modelo": NOMBRE_MODELO,
                                  "carga_segundos": round(CARGADO_EN or 0, 1),
                                  "transcripciones": TRANSCRIPCIONES})
            return
        # /texto?ruta=... devuelve TEXTO PLANO, sin JSON.
        # Medido: el cliente en bash gastaba ~1,6 s solo en arrancar python dos veces (una para
        # armar el JSON del pedido y otra para leer la respuesta). En Windows levantar el
        # interprete es caro, y sobre un pipeline de voz de pocos segundos eso se nota. Con esta
        # ruta, transcribir es un curl y nada mas.
        if self.path.startswith("/texto?"):
            from urllib.parse import urlparse, parse_qs, unquote
            params = parse_qs(urlparse(self.path).query)
            ruta = unquote((params.get("ruta") or [""])[0])
            res = transcribir(ruta)
            cuerpo = (res.get("texto", "") if res.get("ok") else "ERROR: " + str(res.get("error", "")))
            datos = cuerpo.encode("utf-8")
            self.send_response(200 if res.get("ok") else 500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(datos)))
            self.end_headers()
            self.wfile.write(datos)
            return
        self._responder(404, {"ok": False, "error": "ruta desconocida"})

    def do_POST(self):
        largo = int(self.headers.get("Content-Length") or 0)
        crudo = self.rfile.read(largo) if largo else b"{}"
        if self.path == "/apagar":
            self._responder(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if self.path != "/transcribir":
            self._responder(404, {"ok": False, "error": "ruta desconocida"})
            return
        try:
            pedido = json.loads(crudo.decode("utf-8"))
        except Exception:
            self._responder(400, {"ok": False, "error": "cuerpo JSON invalido"})
            return
        ruta = pedido.get("ruta") or ""
        try:
            self._responder(200, transcribir(ruta))
        except Exception as e:
            self._responder(500, {"ok": False, "error": str(e)[:300]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--puerto", type=int, default=0, help="0 = que el sistema elija uno libre")
    ap.add_argument("--estado", required=True, help="archivo JSON donde se anota el puerto")
    ap.add_argument("--modelo", default="base", choices=["tiny", "base", "small", "medium"])
    args = ap.parse_args()

    # ANTES de abrir el socket y ANTES de cargar el modelo: si hay otro servidor vivo, no tiene
    # sentido reservar 1,6 GB para despues descubrirlo.
    ruta_candado = os.path.splitext(args.estado)[0] + ".lock"
    asegurar_instancia_unica(ruta_candado)

    servidor = ThreadingHTTPServer(("127.0.0.1", args.puerto), Handler)
    puerto = servidor.server_address[1]

    # El estado se escribe ANTES de cargar el modelo: el que espera necesita saber el puerto ya
    # mismo, y puede preguntar por /salud para enterarse de cuando esta listo de verdad.
    with open(args.estado, "w", encoding="utf-8") as f:
        json.dump({"puerto": puerto, "pid": os.getpid(), "modelo": args.modelo,
                   "iniciado": time.time()}, f)
    print("escuchando en 127.0.0.1:%d" % puerto, file=sys.stderr, flush=True)

    # Cargar en segundo plano para que el servidor conteste /salud desde el primer instante.
    threading.Thread(target=cargar_modelo, args=(args.modelo,), daemon=True).start()

    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.remove(args.estado)
        except OSError:
            pass
        soltar_candado(ruta_candado)


if __name__ == "__main__":
    sys.exit(main())
