"""nv_stream.py -- una sola llamada al modelo, con streaming y presupuestos de vida.

REEMPLAZA TRES PROCESOS POR UNO. Antes cada llamada a un modelo costaba: un python3 para armar el
JSON del pedido, un curl para mandarlo, y otro python3 para parsear la respuesta. Medido en esta
maquina, arrancar el interprete cuesta ~446 ms, y un saludo por el rol 'fast' gastaba 4.254 ms de
los cuales solo 1.543 ms eran el modelo. Aca se hace todo en un proceso.

PERO EL MOTIVO PRINCIPAL NO ES ESE, ES EL STREAMING.

  1. LO QUE VE USUARIO. Con "stream": false el sistema espera la respuesta ENTERA antes de mostrar
     una sola letra. Por eso hasta un "hola" se sentia lento: no tardaba en pensar, tardaba en
     terminar de escribir.

  2. SABER SI SIGUE VIVO. Un timeout total no distingue "esta pensando" de "esta colgado" -- solo
     mide reloj. Ese es el error que tenia el sistema: 120 s por modelo, tres modelos en cadena,
     y una cola de latencia de 303-309 s (p99 medido: 296 s). Bajar el numero no alcanzaba:
     glm-5.2 tarda 30,9 s en respuestas perfectamente sanas, asi que un timeout corto habria
     cortado respuestas buenas.

     Con streaming se mide lo que importa de verdad:
       - TIEMPO HASTA EL PRIMER TOKEN: si no llega, no va a llegar. Dispara el fallback.
       - SILENCIO ENTRE TOKENS: si venia escribiendo y se callo, se colgo.
     Un modelo que razona tres minutos pero emite tokens NO se corta. Se corta el que no da
     senales de vida. Esa es la diferencia entre castigar al lento y detectar al muerto.

     Los presupuestos son generosos a proposito y salen de medicion (tests/calibrar-streaming.py),
     no de una regla del pulgar: glm-5.2 se calla hasta 9,8 s en medio de una respuesta sana.

CONTRATO DE SALIDA (identico al que tenia ask-nvidia.sh, para no romper a nadie):
    stdout  -> el texto de la respuesta
    stderr  -> lineas de servicio con prefijo, nunca texto de la respuesta
                 NVMETA {json}     una sola, al final: latencia, ttft, motivo de corte
                 NVTHINK <texto>   trozos de razonamiento, si el modelo los emite
    exit 0  -> hay respuesta
    exit 2  -> reintentable (401/429/500/502/503/504)
    exit 3  -> cuelgue, silencio, o respuesta vacia -> al fallback, sin reintentar
    exit 4  -> definitivo (404/400/modelo que no existe) -> al fallback

VARIABLES DE ENTORNO: NVMODEL NVMAX NVTEMP NVPROMPT NVEXTRA NVSYS NVSKILL NVIMAGES NVKEY NVURL
    NV_TTFT       segundos para el primer token (default 20)
    NV_SILENCIO   segundos de silencio tolerados entre tokens (default 30)
    NV_TECHO      techo absoluto en segundos (default 600)
    NV_EMITIR     1 = escribir el texto a stdout a medida que llega (default 0 = todo al final)
"""
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# ERR-030: el stdout de python en este Windows sale en cp1252 y revienta con cualquier caracter
# que no entre ahi. Esto es lo que va al modelo y lo que vuelve al usuario: se fuerza utf-8 siempre.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

URL = os.environ.get("NVURL") or "https://integrate.api.nvidia.com/v1/chat/completions"

# 529 NO ESTABA, Y ES EL QUE MAS APARECE. Medido el 2026-08-03: deepseek-v4-flash -- principal
# del rol 'general', el que contesta casi todo -- devuelve "Service temporarily overloaded" con
# codigo 529 en 2 de cada 3 llamadas. Sin el en esta lista se clasificaba como DEFINITIVO, o sea
# "este modelo no existe": ni se reintentaba ni se le daba otra chance despues. Un modelo
# saturado no es un modelo muerto, y tratarlo como muerto es lo que hace que el sistema se quede
# sin cerebros sanos. 408/522/524 se agregan por la misma razon: son esperas, no negativas.
REINTENTABLES = {"401", "408", "429", "500", "502", "503", "504", "522", "524", "529"}


def _flotante(nombre, defecto):
    try:
        v = float(os.environ.get(nombre, "") or defecto)
        return v if v > 0 else defecto
    except ValueError:
        return defecto


TTFT = _flotante("NV_TTFT", 20.0)
SILENCIO = _flotante("NV_SILENCIO", 30.0)
TECHO = _flotante("NV_TECHO", 600.0)
EMITIR = os.environ.get("NV_EMITIR") == "1"
THINK_STDERR = os.environ.get("NV_THINK_STDERR") == "1"
# NV_ANSWER_STDERR=1 -> ir escupiendo por stderr la RESPUESTA FINAL a medida que se escribe, en
# lineas "NVANSWER <trozo>". Ver answer_incremental para el por que y el como.
ANSWER_STDERR = os.environ.get("NV_ANSWER_STDERR") == "1"
# NV_ANSWER_RAW=1 -> la respuesta NO es un JSON de accion sino prosa suelta: emitir los trozos
# tal cual, sin buscarles el campo "answer".
#
# POR QUE HIZO FALTA (2026-08-18): answer_incremental extrae el texto de un JSON de accion, que
# es lo que devuelve el agente en sus iteraciones. Pero los DOS caminos que producen la respuesta
# que el usuario lee mas seguido NO son JSON: el cierre forzado de nv-agent.sh (le pide al modelo
# "escribi AHORA la respuesta final", en prosa) y la charla directa de mentis-chat.sh (el turno
# sin herramientas). En los dos, la regex no encontraba nada y el streaming quedaba mudo. Medido
# antes del arreglo: 0 chunks en un turno real completo, con el modelo emitiendo bien token a
# token un eslabon mas arriba. O sea que el streaming andaba solo en los turnos donde menos se
# nota, y fallaba justo en los dos mas frecuentes.
ANSWER_RAW = os.environ.get("NV_ANSWER_RAW") == "1"

_ANSWER_INICIO = re.compile(r'"answer"\s*:\s*"')


def answer_incremental(bruto, ya_emitido):
    """De un JSON A MEDIO LLEGAR, devuelve el texto NUEVO del campo "answer" y cuanto se lleva.

    EL PROBLEMA QUE RESUELVE (streaming en la app, 2026-08-06):
    el motor ya emitia por chunks, pero lo que emite el agente no es texto: es
    {"tool":"done","answer":"..."}. Mostrar los tokens crudos le pintaria al usuario el JSON en la
    cara, asi que la app esperaba al final y la respuesta aparecia de golpe -- el streaming
    existia y no se veia.

    Recortar por posicion no alcanza, porque adentro del JSON el texto viene ESCAPADO: los saltos
    de linea son \\n de dos caracteres, y las comillas y los acentos \\uXXXX. Hay que decodificar.
    Y no se puede decodificar a lo bruto, porque en cualquier momento el corte cae en la mitad de
    un escape ("\\u00e", "\\") y eso no es JSON valido.

    La salida: se cierra el string a mano y se prueba a decodificar; si el final quedo cortado, se
    recorta un caracter y se reintenta. Como maximo se descartan los ultimos poquitos caracteres
    de un escape a medias, que van a llegar enteros en el chunk siguiente.

    Es O(n^2) sobre el largo de la respuesta -- se redecodifica el prefijo entero en cada chunk.
    Medido a proposito y aceptado: para una respuesta de chat (unos pocos miles de caracteres) el
    costo es despreciable, y la alternativa (un decodificador incremental propio) es justo el tipo
    de codigo que se rompe con un \\uXXXX partido al medio y nadie lo nota hasta que pasa.
    """
    m = _ANSWER_INICIO.search(bruto)
    if not m:
        return "", ya_emitido
    crudo = bruto[m.end():]

    # Cortar en la comilla de cierre, si es que ya llego. Una comilla precedida de un numero PAR
    # de barras invertidas cierra el string; si son impares, esta escapada.
    fin = None
    i = 0
    while i < len(crudo):
        c = crudo[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            fin = i
            break
        i += 1
    if fin is not None:
        crudo = crudo[:fin]

    for recorte in range(0, 12):
        trozo = crudo[:len(crudo) - recorte] if recorte else crudo
        try:
            texto = json.loads('"' + trozo + '"')
        except Exception:
            continue
        if len(texto) <= ya_emitido:
            return "", ya_emitido
        return texto[ya_emitido:], len(texto)
    return "", ya_emitido


def trozo_para_juan(acumulado, trozo, ya_emitido, raw):
    """Decide QUE texto de este chunk se le muestra al usuario, y cuanto se lleva emitido.

    Dos formas llegan por el mismo canal y hay que distinguirlas MIRANDO lo que llega, no
    confiando en lo que se pidio:
      - JSON de accion ({"tool":..,"answer":".."}): hay que sacarle el campo answer y
        des-escaparlo, si no se le pinta el JSON en la cara.
      - prosa suelta: el chunk YA es texto y va tal cual.

    'raw' dice cual se ESPERA (lo prende quien llama: el cierre forzado y la charla directa
    esperan prosa). Pero no alcanza con eso: al cierre se le pide prosa y el modelo contesta
    JSON igual bastante seguido -- medido en turnos reales. Por eso, aun con raw, si el
    acumulado arranca con '{' se trata como JSON. La decision es estable desde el primer chunk.
    """
    if raw and acumulado.lstrip()[:1] != "{":
        return trozo, ya_emitido
    return answer_incremental(acumulado, ya_emitido)

# --- GUARDA DE PRIVACIDAD ------------------------------------------------------------------------
# Misma lista de patrones que nv_redact en nv-lib.sh, movida aca por una razon medida: la llamada
# suelta a nv_redact costaba 1.152 ms por turno -- mas de la mitad de todo lo que no era el modelo
# en un saludo. Casi todo eso es arrancar el interprete, no enmascarar. Como este proceso ya esta
# arrancado y ya tiene el prompt en la mano, sale gratis.
#
# NO se toco ni un patron ni el mensaje: es una guarda de seguridad, y moverla de lugar no es
# excusa para reescribirla. tests/test-stream.sh comprueba que un secreto NO llegue al endpoint.
PATRONES = [
    (r"nvapi-[A-Za-z0-9_\-]{8,}", "[NVAPI_KEY]"),
    (r"sk-[A-Za-z0-9_\-]{12,}", "[SK_KEY]"),
    (r"ghp_[A-Za-z0-9]{20,}", "[GH_TOKEN]"),
    (r"AKIA[0-9A-Z]{16}", "[AWS_KEY]"),
    (r"(?i)bearer\s+[A-Za-z0-9._\-]{12,}", "Bearer [TOKEN]"),
    (r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", "[EMAIL]"),
    (r"\b\d{2}-\d{8}-\d\b", "[CUIT]"),
    (r"\b\d{22}\b", "[CBU]"),
]


def redactar(texto):
    """Enmascara secretos. NV_REDACT=0 lo apaga (mismo contrato que nv_redact)."""
    if os.environ.get("NV_REDACT", "1") == "0" or not texto:
        return texto
    import re
    n = 0
    for rx, rep in PATRONES:
        texto, k = re.subn(rx, rep, texto)
        n += k
    if n:
        sys.stderr.write("PRIVACIDAD: %d dato(s) sensible(s) enmascarado(s) antes del envio.\n" % n)
    return texto


def armar_payload():
    partes = []
    if (os.environ.get("NVSKILL") or "").strip():
        partes.append("Aplica rigurosamente el siguiente expertise en tu respuesta:\n\n"
                      + os.environ["NVSKILL"].strip())
    if os.environ.get("NVSYS"):
        partes.append(os.environ["NVSYS"])

    msgs = []
    if partes:
        msgs.append({"role": "system", "content": "\n\n---\n\n".join(partes)})

    imgs = []
    ruta_img = os.environ.get("NVIMAGES", "")
    if ruta_img and os.path.exists(ruta_img):
        with io.open(ruta_img, encoding="utf-8") as fh:
            imgs = [ln.strip() for ln in fh if ln.strip()]

    prompt = redactar(os.environ["NVPROMPT"])
    if imgs:
        contenido = [{"type": "text", "text": prompt}]
        for u in imgs:
            contenido.append({"type": "image_url", "image_url": {"url": u}})
        msgs.append({"role": "user", "content": contenido})
    else:
        msgs.append({"role": "user", "content": prompt})

    p = {"model": os.environ["NVMODEL"], "messages": msgs,
         "temperature": float(os.environ.get("NVTEMP") or 0.6), "top_p": 0.95,
         "max_tokens": int(os.environ.get("NVMAX") or 4096), "stream": True}
    extra = os.environ.get("NVEXTRA") or "{}"
    try:
        p.update(json.loads(extra))
    except Exception:
        pass
    p["stream"] = True          # nunca dejar que NVEXTRA lo apague: el streaming es la vida
    return p


def meta(**campos):
    linea = json.dumps(campos, ensure_ascii=False)
    # A stderr SOLO si se pide. mentis-chat.sh reenvia CADA linea de stderr al panel de la app
    # (tee al FIFO, sin filtrar), asi que una linea de metricas por llamada seria ruido visible
    # para el usuario. El dato no se pierde: va al archivo de abajo y de ahi a la telemetria.
    if os.environ.get("NV_META_STDERR") == "1":
        sys.stderr.write("NVMETA " + linea + "\n")
        sys.stderr.flush()
    # NV_META_FILE evita que el llamador tenga que interceptar stderr con `tee` para quedarse con
    # las metricas: ese tee costaba dos procesos por llamada (~150 ms en MSYS) para leer una linea
    # que este proceso ya tiene escrita.
    destino = os.environ.get("NV_META_FILE")
    if destino:
        try:
            with io.open(destino, "w", encoding="utf-8") as f:
                f.write(linea)
        except Exception:
            pass


def salir(codigo, t0, motivo, **extra):
    meta(exit=codigo, motivo=motivo, latencia_ms=round((time.time() - t0) * 1000), **extra)
    sys.exit(codigo)


def tomar_socket(respuesta):
    """Devuelve el socket de la respuesta, o None si esta version de Python no lo expone.

    Se usa para cambiar el plazo de lectura EN CALIENTE: mientras no llego el primer token rige
    el presupuesto de primer token, y despues el de silencio. `fp.raw._sock` es API privada de
    CPython (verificada funcionando aca), asi que si algun dia deja de existir esto degrada a un
    plazo unico en vez de romperse."""
    try:
        s = respuesta.fp.raw._sock
        s.gettimeout()
        return s
    except Exception:
        return None


def clasificar_http(cuerpo, codigo_http):
    """Traduce un error de la API al contrato de exit codes de siempre."""
    estado = str(codigo_http or "")
    try:
        d = json.loads(cuerpo)
        estado = str((d.get("error") or {}).get("code") or d.get("status") or estado)
    except Exception:
        pass
    sys.stderr.write("API: " + (cuerpo or "")[:300] + "\n")
    return 2 if estado in REINTENTABLES else 4


def main():
    t0 = time.time()
    try:
        payload = armar_payload()
    except KeyError as e:
        sys.stderr.write("falta la variable de entorno %s\n" % e)
        return 4

    req = urllib.request.Request(
        URL, data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"Authorization": "Bearer " + (os.environ.get("NVKEY") or ""),
                 "Content-Type": "application/json", "Accept": "text/event-stream",
                 # USER-AGENT PROPIO (2026-08-15). urllib manda "Python-urllib/3.x" y hay
                 # proveedores detras de Cloudflare que lo rechazan con un 403 y una pagina HTML
                 # -- Groq es uno. El sintoma era desconcertante: el mismo modelo, con el mismo
                 # payload y la misma key, andaba por curl (NV_STREAM_OFF=1) y "no respondia" por
                 # el camino normal, asi que parecia un problema del modelo y no del cliente.
                 # curl nunca lo sufrio porque manda su propio User-Agent.
                 "User-Agent": "Mentis/1.0 (+https://github.com/usuario/Mentis)"})

    try:
        # El plazo inicial es el presupuesto de PRIMER TOKEN: si la conexion no da senales en ese
        # rato, no las va a dar. Despues se cambia en caliente al presupuesto de silencio. Si el
        # socket no se puede tocar (ver tomar_socket), se abre directo con el mayor de los dos y
        # se pierde la distincion, pero nada se rompe.
        respuesta = urllib.request.urlopen(req, timeout=max(TTFT, SILENCIO))
        sock = tomar_socket(respuesta)
        if sock is not None:
            sock.settimeout(TTFT)
    except urllib.error.HTTPError as e:
        cuerpo = ""
        try:
            cuerpo = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        codigo = clasificar_http(cuerpo, e.code)
        salir(codigo, t0, "http_%s" % e.code)
    except Exception as e:
        salir(3, t0, "sin_conexion_%s" % type(e).__name__)

    texto = []
    razonamiento = []
    emitido = 0
    ttft_ms = None
    ttfc_ms = None                 # primer token de CONTENIDO (la respuesta que se lee)
    primer_razonamiento_ms = None  # primer token de RAZONAMIENTO (señal de que esta pensando)
    ultimo = time.time()
    silencio_max = 0.0
    corte = None
    answer_emitido = 0   # cuantos caracteres del campo "answer" ya salieron por NVANSWER

    try:
        while True:
            # El plazo de cada lectura es el que quede mas cerca: el silencio tolerado o el techo.
            resto_techo = TECHO - (time.time() - t0)
            if resto_techo <= 0:
                corte = "techo"
                break
            if sock is not None:
                plazo = SILENCIO if ttft_ms is not None else TTFT
                sock.settimeout(min(plazo, resto_techo))

            cruda = respuesta.readline()
            if not cruda:
                break
            linea = cruda.decode("utf-8", "replace").strip()
            if not linea or not linea.startswith("data:"):
                continue
            carga = linea[5:].strip()
            if carga == "[DONE]":
                break
            try:
                d = json.loads(carga)
            except Exception:
                continue

            if "choices" not in d:
                # Algunos errores llegan como un objeto suelto dentro del stream.
                codigo = clasificar_http(carga, None)
                salir(codigo, t0, "error_en_stream")

            delta = (d.get("choices") or [{}])[0].get("delta") or {}
            trozo = delta.get("content") or ""
            piensa = delta.get("reasoning_content") or ""
            if not (trozo or piensa):
                continue

            ahora = time.time()
            if ttft_ms is None:
                ttft_ms = round((ahora - t0) * 1000)
            else:
                silencio_max = max(silencio_max, ahora - ultimo)
            ultimo = ahora

            # PRIMERA SEÑAL DE VIDA vs PRIMER CONTENIDO (2026-08-06). No es lo mismo y hasta hoy
            # se median juntos, lo que llevo a descartar modelos buenos por "lentos".
            #
            # Un modelo que razona manda su monologo interno por reasoning_content ANTES de
            # escribir una sola letra de la respuesta. Si emite razonamiento a los 2 s y contenido
            # a los 20 s, ESTA VIVO desde los 2 s -- lo que pasa es que esta pensando. Cortarlo por
            # "no contesta" es como pedirle a un modelo de razonamiento que no razone.
            #
            # ttft_ms  = primera señal de CUALQUIER tipo -> sirve para saber si esta vivo.
            # ttfc_ms  = primer CONTENIDO -> sirve para saber cuando el usuario empieza a leer.
            # Con los dos separados se puede esperar a los que piensan y cortar a los que no
            # contestan, que era justo la distincion que faltaba.
            if piensa and primer_razonamiento_ms is None:
                primer_razonamiento_ms = round((ahora - t0) * 1000)
            if trozo and ttfc_ms is None:
                ttfc_ms = round((ahora - t0) * 1000)

            if piensa:
                razonamiento.append(piensa)
                # El razonamiento va por stderr, NUNCA a stdout: no es la respuesta, es el
                # proceso. Sirve para mostrar "pensando..." en vez de una pantalla muerta.
                #
                # Apagado por defecto hasta que la app sepa RENDERIZARLO. Hoy mentis-chat.sh
                # reenvia stderr crudo al panel, asi que prenderlo ahora no seria "mostrar que
                # piensa": seria volcarle al usuario el monologo interno del modelo entre los pasos.
                if THINK_STDERR:
                    sys.stderr.write("NVTHINK " + piensa.replace("\n", " ") + "\n")
                    sys.stderr.flush()
            if trozo:
                texto.append(trozo)
                if ANSWER_STDERR:
                    nuevo, answer_emitido = trozo_para_juan(
                        "".join(texto), trozo, answer_emitido, ANSWER_RAW)
                    if nuevo:
                        sys.stderr.write("NVANSWER " + nuevo.replace("\n", "\\n") + "\n")
                        sys.stderr.flush()
                if EMITIR:
                    sys.stdout.write(trozo)
                    sys.stdout.flush()
                    emitido += len(trozo)
    except Exception as e:
        # Un timeout de lectura aca significa exactamente una cosa: se callo. Si ya habia
        # emitido texto, se conserva lo que llego -- media respuesta es mejor que ninguna.
        corte = "silencio" if ttft_ms is not None else "sin_primer_token"
        if type(e).__name__ not in ("timeout", "TimeoutError", "socket.timeout"):
            corte = "error_%s" % type(e).__name__
    finally:
        try:
            respuesta.close()
        except Exception:
            pass

    completo = "".join(texto).strip()
    if not completo:
        completo = "".join(razonamiento).strip()

    if not completo:
        salir(3, t0, corte or "vacio", ttft_ms=ttft_ms, ttfc_ms=ttfc_ms,
              razono_ms=primer_razonamiento_ms)

    if EMITIR and emitido == 0:
        # Habia razonamiento pero nunca contenido: se emite ahora para no dejar al usuario sin nada.
        sys.stdout.write(completo)
    elif not EMITIR:
        sys.stdout.write(completo)
    sys.stdout.flush()

    # Un corte por silencio con texto parcial NO es un exito: se devuelve 3 para que el llamador
    # decida si vale la pena reintentar con otro modelo. Pero el texto ya salio, asi que si el
    # llamador se queda con esto, algo tiene.
    if corte in ("silencio", "techo"):
        salir(3, t0, corte, ttft_ms=ttft_ms, ttfc_ms=ttfc_ms,
              razono_ms=primer_razonamiento_ms, parcial=True,
              silencio_max_ms=round(silencio_max * 1000), chars=len(completo))

    salir(0, t0, "ok", ttft_ms=ttft_ms, ttfc_ms=ttfc_ms,
          razono_ms=primer_razonamiento_ms,
          silencio_max_ms=round(silencio_max * 1000),
          chars=len(completo), razono=bool(razonamiento))


if __name__ == "__main__":
    sys.exit(main())
