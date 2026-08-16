# -*- coding: utf-8 -*-
"""nv_eco_procedencia.py -- ¿esta respuesta es texto que el motor le dio al modelo?

LA DIFERENCIA CON LA DETECCION POR MARCADORES (nv_eco_interno, en nv-lib.sh): aquella pregunta si
el texto SE PARECE a algo interno -- si trae el JSON de una tool, si empieza con AVISO:, si ordena
cerrar con done. Funciona, pero es una lista de patrones que hay que mantener sincronizada con los
~100 puntos del motor que le inyectan texto al modelo, y las listas se desincronizan: ERR-130,
ERR-159 y ERR-165 son tres versiones del mismo cuento en este mismo repositorio.

Esto pregunta otra cosa, que no envejece: ¿este texto SALIO DE ACA? El motor anota cada observacion
que le entrega al modelo, y al cerrar se compara la respuesta final contra ese registro. Cubre
tambien las guardas que se escriban manana, sin tocar nada.

COMO SE COMPARA, Y POR QUE ASI:
  - Por TIRADAS DE PALABRAS (8 seguidas, textuales). Ocho palabras iguales en fila no es
    coincidencia: es copiado. Menos que eso empieza a agarrar frases hechas ("no pude generar el
    documento") que el modelo puede escribir por su cuenta.
  - Y ademas por COBERTURA: no alcanza con que comparta una tirada, tiene que compartir una parte
    grande de la respuesta. Esa es la diferencia entre CITAR y HACER ECO. Si el usuario pregunta "¿que
    error te dio?" y el modelo le copia el error, eso es informacion util y no se puede censurar;
    lo que no sirve es una respuesta que ES el error y nada mas.

Uso:
    python3 nv_eco_procedencia.py <archivo_de_observaciones> <archivo_con_la_respuesta>
    -> imprime "ECO <cobertura>" y sale 0 si es eco; imprime "OK <cobertura>" y sale 1 si no.
"""
import io
import os
import re
import sys

# LOS DOS NUMEROS SALEN DE MEDIR, NO DE ELEGIR (2026-08-16, eval/eco-procedencia/).
# Se barrieron tiradas de 3 a 8 palabras contra las 75 respuestas REALES del historial del usuario y
# contra el caso que motivo todo esto (la captura del brazalete):
#     tirada   peor cobertura de una respuesta real   el caso de la captura
#        3               0.00                                0.49
#        4               0.00                                0.43
#        6               0.00                                0.18
#        8               0.00                                0.18
# Ninguna respuesta legitima comparte NADA con el andamiaje: la separacion es total. Se elige 4 --
# no 3, que empieza a agarrar coincidencias por azar en textos mas largos, y no 6, que ya no ve el
# caso real porque el modelo PARAFRASEO la observacion en vez de copiarla.
TIRADA = int(os.environ.get('MENTIS_ECO_TIRADA', '4'))
# Umbral a mitad de camino entre 0.00 (lo peor real) y 0.43 (el caso). No esta pegado a ninguno de
# los dos a proposito: si mañana una respuesta legitima cita algo, hay lugar antes de que moleste.
COBERTURA_MIN = float(os.environ.get('MENTIS_ECO_COBERTURA', '0.30'))
# Y ADEMAS un minimo ABSOLUTO de palabras copiadas. Sin esto, una respuesta corta que comparte una
# frase de cuatro palabras con una observacion ya llega al 30% y se censura: el caso que lo
# encontro fue "Copie los archivos del respaldo a la carpeta nueva y quedaron los 42" contra un
# error que hablaba de "los archivos del respaldo". Cuatro palabras en comun no son un eco, son el
# tema de la conversacion. El eco de la captura del usuario tiene 26 palabras copiadas; ese es el orden
# de magnitud que distingue copiar de coincidir.
PALABRAS_MIN = int(os.environ.get('MENTIS_ECO_PALABRAS', '15'))


def palabras(t):
    # Se ignoran mayusculas y puntuacion: el modelo reescribe "AVISO:" como "Aviso" y sigue siendo
    # el mismo texto. Los acentos se dejan como estan (comparar dos textos entre si no tiene el
    # problema de los bracket-expressions de grep).
    return re.findall(r'\w+', t.lower(), flags=re.UNICODE)


def tiradas(ws, n=TIRADA):
    return set(tuple(ws[i:i + n]) for i in range(max(0, len(ws) - n + 1)))


def cobertura(respuesta, observaciones):
    """Que fraccion de las palabras de la respuesta cae dentro de una tirada copiada. 0.0 a 1.0."""
    rw = palabras(respuesta)
    if len(rw) < TIRADA:
        # Una respuesta mas corta que la tirada no se puede evaluar asi. Se deja pasar: la
        # deteccion por marcadores ya cubre los avisos cortos.
        return 0.0, 0
    ajenas = set()
    for obs in observaciones:
        ajenas |= tiradas(palabras(obs))
    if not ajenas:
        return 0.0, 0
    marcadas = [False] * len(rw)
    for i in range(len(rw) - TIRADA + 1):
        if tuple(rw[i:i + TIRADA]) in ajenas:
            for j in range(i, i + TIRADA):
                marcadas[j] = True
    return sum(marcadas) / float(len(rw)), sum(marcadas)


def leer_observaciones(ruta):
    """El motor separa cada observacion con \\x1e (record separator)."""
    if not ruta or not os.path.isfile(ruta):
        return []
    with io.open(ruta, encoding='utf-8', errors='replace') as f:
        crudo = f.read()
    return [o.strip() for o in crudo.split('\x1e') if o.strip()]


def es_eco(respuesta, observaciones):
    """Las DOS condiciones: proporcion alta Y volumen real de texto copiado."""
    c, n = cobertura(respuesta, observaciones)
    return (c >= COBERTURA_MIN and n >= PALABRAS_MIN), c


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 64
    obs = leer_observaciones(argv[1])
    with io.open(argv[2], encoding='utf-8', errors='replace') as f:
        respuesta = f.read()
    eco, c = es_eco(respuesta, obs)
    sys.stdout.write('%s %.2f\n' % ('ECO' if eco else 'OK', c))
    return 0 if eco else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
