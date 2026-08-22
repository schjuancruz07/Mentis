# -*- coding: utf-8 -*-
"""Ningun camino de corte del loop puede dejar el turno mudo.

POR QUE ES EXHAUSTIVO Y NO UNA LISTA (2026-08-18): test-turno-mudo.sh verifica con grep los
caminos que alguien se acordo de enumerar. Ya paso que se taparon dos caminos y quedaba un tercero
nueve lineas mas abajo -- el propio codigo lo documenta como "EL TERCER CAMINO QUE DEJABA EL TURNO
MUDO". Esto no enumera: encuentra los cortes solo, asi que un camino nuevo entra al test el dia que
se escribe, que es justo cuando nadie se acuerda de actualizar el test.

Se mira el BLOQUE `if` que contiene cada corte (hasta su `fi`), no una ventana de N lineas: los
comentarios de este archivo son largos y una ventana fija da falsos positivos.
"""
import io, os, re, sys

raiz = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
lineas = io.open(os.path.join(raiz, "engine", "nv-agent.sh"),
                 encoding="utf-8", errors="replace").read().split("\n")

def sangria(l):
    return len(l) - len(l.lstrip())

def bloque_de(i):
    """Texto del bloque `if` que contiene la linea i: desde su `if` hasta el `fi` de esa sangria."""
    s = sangria(lineas[i])
    ini = i
    for k in range(i, -1, -1):
        if lineas[k].lstrip().startswith(("if ", "elif ")) and sangria(lineas[k]) < s:
            ini = k
            s_if = sangria(lineas[k])
            break
    else:
        return "\n".join(lineas[max(0, i - 20):i + 20])
    fin = len(lineas)
    for k in range(ini + 1, len(lineas)):
        if lineas[k].strip() == "fi" and sangria(lineas[k]) == s_if:
            fin = k
            break
    return "\n".join(lineas[ini:fin + 1])

# Un corte con STATUS ya en "done" es el camino EXITOSO: el modelo cerro solo y hay respuesta.
CIERRA = re.compile(r'CIERRE_FORZADO=1|STATUS="done"|FINAL=')

# Un corte con STATUS ya en "done" es el camino EXITOSO: el modelo cerro solo y hay
# respuesta. No es un turno mudo.
SALIDA_OK = '"$STATUS" = "done"'

def cierra(bloque):
    return bool(CIERRA.search(bloque)) or SALIDA_OK in bloque
fallos = []

# --- invariante 1: todo LOOP_DETECTADO=1 cierra el turno en su mismo bloque ---
n_loop = 0
for i, l in enumerate(lineas):
    if "LOOP_DETECTADO=1" not in l or l.lstrip().startswith("#"):
        continue
    n_loop += 1
    if not cierra(bloque_de(i)):
        fallos.append("linea %d: prende LOOP_DETECTADO sin cerrar el turno" % (i + 1))

# --- invariante 2: todo corte del loop principal cierra, o delega en LOOP_DETECTADO ---
ini = next((i for i, l in enumerate(lineas)
            if re.match(r'\s*for\s+it\s+in\s|\s*while\s+\[\s*"?\$?\{?it', l)), None)
if ini is None:
    print("MAL no se pudo ubicar el loop principal -- el detector quedo ciego")
    sys.exit(1)
s_ini = sangria(lineas[ini])
fin = next((i for i in range(ini + 1, len(lineas))
            if lineas[i].strip() == "done" and sangria(lineas[i]) == s_ini), len(lineas))

n_cortes = 0
for i in range(ini, fin):
    l = lineas[i]
    if l.lstrip().startswith("#") or not re.search(r'(^|;|\s)break(\s|;|$)', l):
        continue
    if sangria(l) > s_ini + 6:      # break de un case/for interno: no corta el turno
        continue
    n_cortes += 1
    # La linea del corte va incluida: un `if...; then break; fi` de una sola linea es su
    # propio bloque, y bloque_de() sale a buscar el `if` de mas arriba.
    b = lineas[i] + chr(10) + bloque_de(i)
    if not cierra(b) and "LOOP_DETECTADO" not in b:
        fallos.append("linea %d: '%s' corta el turno sin cerrarlo" % (i + 1, l.strip()[:55]))

if n_loop == 0 or n_cortes == 0:
    print("MAL el detector no encontro nada que revisar -- quedo ciego")
    sys.exit(1)
if fallos:
    for f in fallos:
        print("MAL " + f)
    sys.exit(1)
print("casos: %d cortes del loop y %d detecciones de bucle, todos cierran" % (n_cortes, n_loop))
