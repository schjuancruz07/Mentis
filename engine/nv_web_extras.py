"""nv_web_extras.py -- lo que le faltaba a la página del celular (Fase 3, 2026-08-01).

Está aparte de nv_web_server.py a propósito: ese archivo ya tiene el turno en vivo, el cuerpo 3D
y el long-polling, que es la parte delicada. Todo lo de acá es aditivo y de sólo lectura sobre el
historial, así que un error mío no puede romper la conversación en curso.

Lo que agrega:
  - lista de conversaciones anteriores, con fecha y una vista previa
  - buscador sobre todas las conversaciones
  - resumen de una conversación, para retomarla sin arrastrar todo el historial
  - estadísticas de uso
  - guardado de una foto sacada desde el celular, para mandársela a Mentis

LO QUE NO HACE, Y ES DELIBERADO: nada de acá escribe en una conversación ni ejecuta un turno.
La página del celular corre en modo remoto (-R), que ya tiene prohibido escribir, ejecutar, ver
la pantalla y usar la cámara de la computadora. Sumarle capacidades por la puerta de atrás
vaciaría esa decisión de contenido.
"""

import base64
import json
import os
import re
import time

# Los mismos límites que usa el resto del servidor: una conversación no puede crecer sin techo
# dentro de una respuesta HTTP.
MAX_PREVIEW = 90
MAX_RESULTADOS = 40


def _carpeta(raiz):
    return os.path.join(raiz, "conversations")


def _leer_conversacion(camino):
    """Devuelve [{role, text}] de un.jsonl de conversación. Tolera líneas rotas: un historial a
    medio escribir (la app estaba escribiendo cuando se leyó) no puede tumbar la lista entera."""
    mensajes = []
    try:
        with open(camino, "rb") as f:
            crudo = f.read()
    except OSError:
        return mensajes
    for linea in crudo.decode("utf-8", "replace").splitlines():
        linea = linea.strip()
        if not linea:
            continue
        try:
            d = json.loads(linea)
        except Exception:
            continue
        if d.get("role") in ("usuario", "mentis") and (d.get("text") or "").strip():
            mensajes.append({"role": d["role"], "text": d["text"]})
    return mensajes


def listar_conversaciones(raiz, incluye_app=True):
    """Todas las conversaciones, la más reciente primero.

    Incluye las de la app y no sólo las del celular: desde el teléfono, lo más útil suele ser
    retomar algo que se empezó sentado en la computadora."""
    carpeta = _carpeta(raiz)
    salida = []
    if not os.path.isdir(carpeta):
        return salida
    for nombre in os.listdir(carpeta):
        if not nombre.endswith(".jsonl"):
            continue
        es_remota = nombre.startswith("remoto-")
        if not incluye_app and not es_remota:
            continue
        camino = os.path.join(carpeta, nombre)
        try:
            st = os.stat(camino)
        except OSError:
            continue
        if st.st_size == 0:
            continue
        msgs = _leer_conversacion(camino)
        if not msgs:
            continue
        primero = next((m["text"] for m in msgs if m["role"] == "usuario"), msgs[0]["text"])
        salida.append({
            "id": nombre[:-6],
            "origen": "celular" if es_remota else "computadora",
            "modificada": int(st.st_mtime),
            "mensajes": len(msgs),
            "vista": (primero[:MAX_PREVIEW] + ("…" if len(primero) > MAX_PREVIEW else "")),
        })
    salida.sort(key=lambda c: -c["modificada"])
    return salida


def buscar(raiz, consulta, limite=MAX_RESULTADOS):
    """Busca texto en todas las conversaciones.

    Búsqueda literal, sin distinguir mayúsculas ni tildes. No usa expresiones regulares a
    propósito: lo que escribe alguien en el buscador de un celular es texto, y un paréntesis
    suelto no puede hacer explotar la búsqueda ni colgar el servidor."""
    consulta = (consulta or "").strip()
    if not consulta:
        return []
    aguja = _sin_tildes(consulta.lower())
    resultados = []
    carpeta = _carpeta(raiz)
    if not os.path.isdir(carpeta):
        return resultados
    for nombre in sorted(os.listdir(carpeta), reverse=True):
        if not nombre.endswith(".jsonl"):
            continue
        camino = os.path.join(carpeta, nombre)
        for i, m in enumerate(_leer_conversacion(camino)):
            if aguja in _sin_tildes(m["text"].lower()):
                pos = _sin_tildes(m["text"].lower()).find(aguja)
                ini = max(0, pos - 40)
                resultados.append({
                    "conversacion": nombre[:-6],
                    "origen": "celular" if nombre.startswith("remoto-") else "computadora",
                    "indice": i,
                    "role": m["role"],
                    "fragmento": ("…" if ini > 0 else "") + m["text"][ini:ini + 160],
                })
                if len(resultados) >= limite:
                    return resultados
    return resultados


def _sin_tildes(s):
    """Comparación insensible a tildes: quien busca 'sesion' tiene que encontrar 'sesión'.
    Se hace con un mapa explícito y no con clases de caracteres -- en este proyecto ya costó caro
    confundir bytes con letras (ERR-100)."""
    for a, b in (("á", "a"), ("é", "e"), ("í", "i"), ("ó", "o"), ("ú", "u"),
                 ("ü", "u"), ("ñ", "n")):
        s = s.replace(a, b)
    return s


def resumen_para_retomar(raiz, conversacion, maximo=12):
    """Los últimos intercambios de una conversación, para poder seguirla sin arrastrar todo.

    Devuelve el material; NO escribe nada ni llama al modelo. Quien retoma decide qué hacer con
    esto. Mezclar 'leer' con 'continuar' acá le daría al modo remoto una capacidad de escritura
    que se le quitó a propósito."""
    limpio = re.sub(r"[^A-Za-z0-9_-]", "", str(conversacion or ""))[:60]
    if not limpio:
        return None
    camino = os.path.join(_carpeta(raiz), limpio + ".jsonl")
    if not os.path.exists(camino):
        return None
    msgs = _leer_conversacion(camino)
    if not msgs:
        return None
    ultimos = msgs[-maximo:]
    return {
        "conversacion": limpio,
        "total": len(msgs),
        "mostrados": len(ultimos),
        "mensajes": ultimos,
        # Texto listo para pegarle al modelo como contexto si se quiere retomar.
        "contexto": "\n".join(
            ("el usuario: " if m["role"] == "usuario" else "Mentis: ") + m["text"] for m in ultimos
        ),
    }


def estadisticas(raiz):
    """Números de uso. Se calculan leyendo, no se guardan en ningún lado: un contador persistido
    es una cosa más que se puede desincronizar de la realidad."""
    convs = listar_conversaciones(raiz)
    total_msgs = sum(c["mensajes"] for c in convs)
    ahora = time.time()
    ultima_semana = [c for c in convs if ahora - c["modificada"] < 7 * 86400]
    por_origen = {}
    for c in convs:
        por_origen[c["origen"]] = por_origen.get(c["origen"], 0) + 1
    return {
        "conversaciones": len(convs),
        "mensajes": total_msgs,
        "conversaciones_ultima_semana": len(ultima_semana),
        "mensajes_ultima_semana": sum(c["mensajes"] for c in ultima_semana),
        "por_origen": por_origen,
        "promedio_mensajes": round(total_msgs / len(convs), 1) if convs else 0,
        "ultima": convs[0]["modificada"] if convs else 0,
    }


def guardar_foto(raiz, datos_base64, sesion=""):
    """Guarda una foto sacada desde el celular y devuelve su ruta, para pasársela al turno.

    Se valida el tamaño y el tipo ANTES de escribir: esto lo alimenta un navegador a través de la
    red, y un endpoint que escribe archivos sin mirar lo que le mandan es un agujero. El nombre lo
    genera el servidor, nunca el cliente."""
    if not datos_base64:
        return None, "no llego ninguna imagen"
    cabecera, _, cuerpo = datos_base64.partition(",")
    if not cuerpo:
        cuerpo = cabecera
        cabecera = ""
    ext = "jpg"
    if "png" in cabecera.lower():
        ext = "png"
    elif "webp" in cabecera.lower():
        ext = "webp"
    try:
        binario = base64.b64decode(cuerpo, validate=True)
    except Exception:
        return None, "la imagen no es base64 valido"
    # 12 MB: una foto de celular ronda los 3-5 MB. Más que esto es un error o algo raro.
    if len(binario) > 12 * 1024 * 1024:
        return None, "la imagen pesa mas de 12 MB"
    # Piso bajo a proposito: lo que garantiza que sea una imagen es la FIRMA de abajo, no el
    # tamano. Un piso de 100 bytes parecia razonable y rechazaba PNGs chiquitos perfectamente
    # validos (un 1x1 pesa ~70). Con 24 alcanza para descartar datos vacios o truncados sin
    # inventar un minimo que no tiene ninguna base.
    if len(binario) < 24:
        return None, "la imagen esta vacia o cortada"
    # Firma real del archivo, no lo que diga la cabecera que mandó el navegador.
    if not (binario[:3] == b"\xff\xd8\xff" or binario[:8] == b"\x89PNG\r\n\x1a\n" or binario[:4] == b"RIFF"):
        return None, "el archivo no es una imagen jpg, png ni webp"
    carpeta = os.path.join(raiz, "workspace-app", "fotos-celular")
    os.makedirs(carpeta, exist_ok=True)
    marca = re.sub(r"[^A-Za-z0-9-]", "", str(sesion))[:20] or "anon"
    nombre = "foto-%s-%s.%s" % (time.strftime("%Y%m%d-%H%M%S"), marca, ext)
    camino = os.path.join(carpeta, nombre)
    with open(camino, "wb") as f:
        f.write(binario)
    return camino, None
