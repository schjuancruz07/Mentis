# -*- coding: utf-8 -*-
"""Que `.hidden` GANE la cascada, calculandola -- no mirando si el texto esta escrito.

POR QUE (2026-08-18): test-ocultar.sh verifica el CSS con grep. Pero el bug que motivo ese archivo
NO es una linea que falte: es una linea que PIERDE. `#admin-panel { display:flex }` tiene
especificidad 100 y `.hidden { display:none }` tiene 10, asi que el panel se mostraba con el
switch apagado aunque las dos reglas estuvieran escritas (ERR-124, y otra vez el 2026-08-08). Un
grep ve las dos reglas presentes y da verde. Esto calcula cual gana.
"""
import io, os, re, sys

raiz = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
css = io.open(os.path.join(raiz, "app", "renderer", "style.css"),
              encoding="utf-8", errors="replace").read()
css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)

def especificidad(sel):
    sel = re.sub(r'::?[a-z-]+(\([^)]*\))?', '', sel)
    return (len(re.findall(r'#[\w-]+', sel)),
            len(re.findall(r'\.[\w-]+', sel)) + len(re.findall(r'\[[^\]]+\]', sel)),
            len(re.findall(r'(?:^|[\s>+~])([a-z][\w-]*)', sel)))

# reglas que tocan 'display', con su selector, valor e importancia
reglas = []
for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', css):
    sel_grupo, cuerpo = m.group(1).strip(), m.group(2)
    d = re.search(r'(?:^|;)\s*display\s*:\s*([^;!]+)(!important)?', cuerpo, re.I)
    if not d:
        continue
    for sel in sel_grupo.split(","):
        sel = sel.strip()
        if not sel or sel.startswith("@"):
            continue
        reglas.append((sel, d.group(1).strip().lower(), bool(d.group(2)), especificidad(sel)))

fallos = []

# 1) tiene que existir la regla global.hidden y ocultar
glob = [r for r in reglas if r[0] == ".hidden"]
if not glob:
    fallos.append("no existe una regla global '.hidden' que setee display")
elif glob[0][1] != "none":
    fallos.append("'.hidden' no pone display:none, pone %r" % glob[0][1])
elif not glob[0][2]:
    fallos.append("'.hidden' no es !important: cualquier regla con id le gana")

# 2) LA CASCADA: ninguna otra regla puede ganarle a.hidden en un elemento oculto.
# Con !important, solo le gana otro !important de mayor especificidad.
if glob and glob[0][2]:
    for sel, val, imp, esp in reglas:
        if sel == ".hidden" or val == "none":
            continue
        if imp and esp > glob[0][3]:
            fallos.append("'%s { display:%s !important }' le gana a.hidden (esp %s vs %s)"
                          % (sel, val, esp, glob[0][3]))

# 3) las reglas que combinan un id CON.hidden tienen que ocultar, no mostrar.
# Esta es la forma exacta del bug: '#admin-panel.hidden { display:flex }'.
for sel, val, imp, esp in reglas:
    if ".hidden" in sel and sel != ".hidden" and val != "none":
        fallos.append("'%s' combina.hidden y MUESTRA (display:%s): invierte el sentido de ocultar"
                      % (sel, val))

if not reglas:
    print("MAL no se parseo ninguna regla de display -- el detector quedo ciego")
    sys.exit(1)
if fallos:
    for f in fallos:
        print("MAL " + f)
    sys.exit(1)
print("casos: 3 invariantes de cascada sobre %d reglas de display" % len(reglas))
