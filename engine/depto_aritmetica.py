# -*- coding: utf-8 -*-
"""Verifica que las cuentas de un entregable CIERREN. No confia en que el modelo sume.

POR QUE EXISTE (2026-08-20): el departamento de Presupuestos escribio las lineas bien
(3*48000=144000, 12*3200=38400, 8*2500=20000) y despues sumo 288400 en vez de 202400. Un error de
86.000 pesos, y el texto listo para mandarle al cliente llevaba el numero equivocado. Los modelos
no suman de forma confiable y esto no es opinable: se verifica con codigo o no se verifica.

Detecta tres formas:
  a*b = c            -> comprueba el producto
  a + b + c = TOTAL  -> comprueba la suma
  items + "Total: X" -> suma los productos del bloque y los compara con el total declarado

Uso:  depto_aritmetica.py <archivo>
Sale 0 si todo cierra, 3 si hay errores (los imprime).
"""
import io
import re
import sys

for _f in (sys.stdout, sys.stderr):
    try:
        _f.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


# Los numeros pueden venir con puntos o comas de miles: se normalizan antes de comparar.
def _num(s):
    s = s.strip().replace(".", "").replace(",", "")
    return int(s) if s.lstrip("-").isdigit() else None


RE_PROD = re.compile(r'(\d[\d.,]*)\s*[*x×]\s*(\d[\d.,]*)\s*(?:ARS\s*)?=\s*(\d[\d.,]*)', re.I)
RE_SUMA = re.compile(r'((?:\d[\d.,]*\s*\+\s*){1,}\d[\d.,]*)\s*(?:ARS\s*)?=\s*(\d[\d.,]*)', re.I)
RE_TOTAL = re.compile(r'\b(?:total|totales)\b[^0-9\n]{0,20}(\d[\d.,]*)', re.I)
# Palabras que hacen que el total NO tenga que ser la suma pelada de los items.
RE_AJUSTE = re.compile(r'\b(iva|descuento|recargo|bonific|impuesto|env[ií]o|flete|anticipo|se[ñn]a)\b', re.I)


def _sin_markdown(texto):
    """Saca las marcas que no son numeros ni operadores.

    ESTO ERA EL BUG (2026-08-20, mismo dia que se creo la guarda). La guarda existia, corria, y
    decia "las cuentas cierran" sobre un presupuesto que sumaba 262.400 donde iban 202.400 --
    60.000 de mas, en un texto listo para mandarle al cliente. La causa: el modelo escribio el
    total en negrita, "= **262400 ARS**", y el patron espera un digito despues del '=' -- se
    encontro un asterisco y no matcheo nada. En el MISMO archivo, la seccion de al lado tenia el
    total sin negrita y esa si se verificaba. O sea que la guarda miraba o no miraba segun como el
    modelo hubiera decidido formatear la linea, que es como no tener guarda.

    Se sacan solo las marcas DOBLES y los backticks: el asterisco simple es el signo de
    multiplicacion en "3 * 48000" y no se puede tocar.
    """
    return texto.replace("**", " ").replace("__", " ").replace("`", " ")


def _bloques(texto):
    """Parte el entregable por encabezados: cada presupuesto es su propia cuenta.

    Sin esto no se puede comparar un Total contra sus items: un archivo con tres presupuestos
    tiene tres totales, y sumar todos los productos del archivo daria cualquier cosa.
    """
    partes, actual = [], []
    for linea in texto.splitlines():
        if linea.lstrip().startswith("#") and actual:
            partes.append("\n".join(actual))
            actual = []
        actual.append(linea)
    if actual:
        partes.append("\n".join(actual))
    return partes


def revisar(texto):
    texto = _sin_markdown(texto)
    errores = []
    for m in RE_PROD.finditer(texto):
        a, b, c = (_num(m.group(i)) for i in (1, 2, 3))
        if None in (a, b, c):
            continue
        if a * b != c:
            errores.append("%s x %s deberia dar %s y dice %s" % (a, b, a * b, c))
    for m in RE_SUMA.finditer(texto):
        partes = [_num(p) for p in m.group(1).split("+")]
        total = _num(m.group(2))
        if total is None or any(p is None for p in partes):
            continue
        if sum(partes) != total:
            errores.append("%s deberia dar %s y dice %s"
                           % (" + ".join(str(p) for p in partes), sum(partes), total))

    # EL TOTAL, AUNQUE NO ESCRIBA LA SUMA (2026-08-20). Las dos comprobaciones de arriba solo
    # funcionan si el modelo DEJA LA CUENTA ESCRITA. Si pone los items y despues un "Total: X"
    # suelto, no habia nada que verificar -- y es la forma mas natural de escribir un presupuesto.
    # Aca se suman los resultados de los productos de cada bloque y se comparan con su total.
    for bloque in _bloques(texto):
        if RE_AJUSTE.search(bloque):
            continue  # hay IVA, descuento o envio: el total no tiene por que ser la suma pelada
        productos = [_num(m.group(3)) for m in RE_PROD.finditer(bloque)]
        productos = [p for p in productos if p is not None]
        if len(productos) < 2:
            continue
        totales = [_num(m.group(1)) for m in RE_TOTAL.finditer(bloque)]
        totales = [t for t in totales if t is not None]
        if not totales:
            continue
        esperado = sum(productos)
        # Alcanza con que ALGUNO de los totales del bloque coincida: "Subtotal" y "Total" suelen
        # convivir, y a veces el mismo numero se repite en el texto para copiar y pegar.
        if esperado not in totales:
            errores.append("los items suman %s y el total dice %s"
                           % (esperado, " / ".join(str(t) for t in totales)))
    return errores


def corregir(texto):
    """Arregla los TOTALES que no cierran. Devuelve (texto_nuevo, lista_de_cambios).

    POR QUE CORREGIR Y NO SOLO AVISAR (2026-08-20): avisar deja el arreglo en manos del modelo, y
    el modelo es justamente el que no sabe sumar -- medido, falla 1 de cada 3 presupuestos. El
    reintento le decia el error concreto y aun asi dependia de que la segunda vez sumara bien.
    Una suma es determinista: la hace el codigo o no la hace nadie.

    LO QUE NO SE TOCA, Y ES DELIBERADO: los PRODUCTOS (3 x 48000 = 144000). Ahi el numero
    equivocado puede ser cualquiera de los tres -- si el precio unitario esta mal copiado de la
    lista, "corregir" el resultado consolidaria el error y taparia el problema de fondo. Un
    producto mal se devuelve como error para que el departamento reintente leyendo los datos.
    Se corrige solo lo que es una SUMA de numeros que ya estan escritos ahi.
    """
    cambios = []
    # SE CORRIGE BLOQUE POR BLOQUE, no sobre el archivo entero. Un archivo puede tener varios
    # presupuestos, y el numero equivocado de uno puede ser un numero CORRECTO en otro. Probado:
    # con "Cliente A: 2000 + 3000 = 6000" (mal, da 5000) y "Cliente B: 3 * 2000 = 6000" (bien), el
    # reemplazo global arreglaba el primero y ROMPIA el segundo.
    #
    # Dentro de un bloque, en cambio, el reemplazo SI va a todas las apariciones a proposito: el
    # total repetido abajo y el texto de "copiar y pegar" que el usuario le manda al cliente tienen que
    # quedar con el numero bueno. Arreglar el subtotal y dejar el texto del cliente con el viejo
    # seria dejar salir el error por la puerta.
    salida = []
    for bloque in _bloques(texto):
        plano = _sin_markdown(bloque)
        for m in RE_SUMA.finditer(plano):
            partes = [_num(x) for x in m.group(1).split("+")]
            total = _num(m.group(2))
            if total is None or any(x is None for x in partes):
                continue
            bien = sum(partes)
            if bien != total:
                escrito = m.group(2)
                nuevo_txt = _mismo_formato(escrito, bien)
                if escrito in bloque:
                    bloque = bloque.replace(escrito, nuevo_txt)
                    cambios.append("%s -> %s (la suma de %s)"
                                   % (escrito, nuevo_txt, " + ".join(str(x) for x in partes)))
        salida.append(bloque)
    return "\n".join(salida), cambios


def _mismo_formato(escrito, valor):
    """Escribe el numero nuevo como estaba escrito el viejo: 144.000 / 144,000 / 144000."""
    if "." in escrito:
        return "{:,}".format(valor).replace(",", ".")
    if "," in escrito:
        return "{:,}".format(valor)
    return str(valor)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    corregir_pedido = "--corregir" in sys.argv
    if not args:
        return 2
    ruta = args[0]
    try:
        texto = io.open(ruta, encoding="utf-8", errors="replace").read()
    except Exception:
        return 1

    if corregir_pedido:
        texto2, cambios = corregir(texto)
        if cambios:
            try:
                io.open(ruta, "w", encoding="utf-8").write(texto2)
            except Exception:
                return 1
            for c in cambios:
                print("CORREGIDO: " + c)
            texto = texto2

    errores = revisar(texto)
    if errores:
        for e in errores:
            print("CUENTA MAL: " + e)
        return 3
    print("las cuentas cierran")
    return 0


if __name__ == "__main__":
    sys.exit(main())
