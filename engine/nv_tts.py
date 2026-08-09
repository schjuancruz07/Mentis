#!/usr/bin/env python3
"""nv_tts.py -- voz de Mentis con los modelos TTS de NVIDIA (2026-07-26).

Por que gRPC y no REST: estos modelos NO se sirven desde integrate.api.nvidia.com (probado:
404 en todos los endpoints REST). Van por NVCF con el protocolo de Riva, que es gRPC. El
descubrimiento salio de la propia pagina del modelo, que muestra `pip install nvidia-riva-client`
y `--server grpc.nvcf.nvidia.com:443 --metadata function-id...`.

Modelos disponibles (function-ids sacados del catalogo real de NVCF, no de memoria):
    magpie-multilingual -> 9 idiomas, 74 voces en español con emociones (Isabela, Diego,...)
    magpie-zeroshot     -> clona una voz a partir de una muestra de audio

Uso:
    nv_tts.py --texto "hola" --salida audio.wav [--voz ES-US.Isabela.Calm] [--modelo magpie]
    nv_tts.py --listar-voces
"""
import argparse
import os
import sys
import time
import wave

FUNCIONES = {
    "magpie": "877104f7-e885-42b9-8de8-f6e4c6303969",           # magpie-tts-multilingual
    "magpie-zeroshot": "55cf67bf-600f-4b04-8eac-12ed39537a08",  # magpie-tts-zeroshot
    "chatterbox": "ddacc747-1269-4fab-bfd9-8f593dead106",       # resemble-ai chatterbox
}
SERVIDOR = "grpc.nvcf.nvidia.com:443"


def _auth(function_id, api_key):
    import riva.client
    return riva.client.Auth(
        uri=SERVIDOR, use_ssl=True,
        metadata_args=[["function-id", function_id],
                       ["authorization", "Bearer " + api_key]],
    )


def listar_voces(api_key, modelo, idioma="ES"):
    import riva.client
    auth = _auth(FUNCIONES[modelo], api_key)
    svc = riva.client.SpeechSynthesisService(auth)
    cfg = svc.stub.GetRivaSynthesisConfig(
        riva.client.proto.riva_tts_pb2.RivaSynthesisConfigRequest(),
        metadata=auth.get_auth_metadata())
    salida = []
    for m in cfg.model_config:
        params = dict(m.parameters)
        for sub in params.get("subvoices", "").split(","):
            nombre = sub.split(":")[0]
            if nombre and nombre.upper().startswith(idioma.upper()):
                salida.append(nombre)
    return salida


def sintetizar(texto, ruta_salida, api_key, modelo="magpie",
               voz="ES-US.Isabela.Calm", idioma="es-US", sample_rate=22050):
    import riva.client
    auth = _auth(FUNCIONES[modelo], api_key)
    svc = riva.client.SpeechSynthesisService(auth)
    t0 = time.time()
    resp = svc.synthesize(
        text=texto,
        voice_name=voz,
        language_code=idioma,
        sample_rate_hz=sample_rate,
        encoding=riva.client.AudioEncoding.LINEAR_PCM,
    )
    tardo = time.time() - t0
    # La respuesta es PCM crudo: hay que envolverlo en un WAV con cabecera, si no ningun
    # reproductor lo abre (y el archivo "existe" pero no suena -- otro falso exito).
    with wave.open(ruta_salida, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)          # LINEAR_PCM = 16 bits
        w.setframerate(sample_rate)
        w.writeframes(resp.audio)
    return tardo, len(resp.audio)


def main():
    ap = argparse.ArgumentParser(description="Genera voz con los modelos TTS de NVIDIA")
    ap.add_argument("--texto")
    ap.add_argument("--salida")
    ap.add_argument("--voz", default="ES-US.Isabela.Calm")
    ap.add_argument("--idioma", default="es-US")
    ap.add_argument("--modelo", default="magpie", choices=sorted(FUNCIONES))
    ap.add_argument("--listar-voces", action="store_true")
    ap.add_argument("--prefijo-idioma", default="ES")
    args = ap.parse_args()

    api_key = (os.environ.get("NVIDIA_KEY_VOZ_PARLANCHIN")
               or os.environ.get("NVIDIA_KEY_CHATTERBOX")
               or os.environ.get("NVIDIA_API_KEY", "")).strip()
    if not api_key:
        print("ERROR: falta la key de voz (NVIDIA_KEY_VOZ_PARLANCHIN)", file=sys.stderr)
        return 2

    if args.listar_voces:
        for v in listar_voces(api_key, args.modelo, args.prefijo_idioma):
            print(v)
        return 0

    if not args.texto or not args.salida:
        print("ERROR: hacen falta --texto y --salida", file=sys.stderr)
        return 2

    try:
        tardo, tam = sintetizar(args.texto, args.salida, api_key,
                                modelo=args.modelo, voz=args.voz, idioma=args.idioma)
    except Exception as e:
        print("ERROR: %s" % str(e)[:300], file=sys.stderr)
        return 1

    # Verificacion real: un.wav de menos de 1 KB es silencio o cabecera sola. Sin esto se
    # reportaria "listo" sobre un archivo que no suena (el mismo patron de falso exito que ya
    # mordio en gen y en Kai Vault).
    if tam < 1000:
        print("ERROR: el audio salio vacio (%d bytes de PCM)" % tam, file=sys.stderr)
        return 1
    print("OK archivo=%s bytes_pcm=%d segundos=%.2f voz=%s modelo=%s"
          % (args.salida, tam, tardo, args.voz, args.modelo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
