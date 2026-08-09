#!/usr/bin/env bash
# test-web-extras.sh -- lo que se le sumó a la página del celular (Fase 3).
#
# Casi todo se prueba SIN levantar el servidor, llamando directo a engine/nv_web_extras.py sobre
# una carpeta de conversaciones falsa. Un test que necesitara el servidor real dependería de un
# puerto libre y de que no haya otro Mentis corriendo, y esos son rojos que no dicen nada.
#
# LO QUE MAS IMPORTA ACA: que el modo remoto no gane capacidades por la ventana. La página del
# celular tiene prohibido escribir, ejecutar, ver la pantalla y usar la cámara; si un endpoint
# nuevo abriera cualquiera de esas, la decisión de acotar el modo remoto quedaría sin efecto.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=0; FALLA=0
_ok()    { OK=$((OK+1));       echo "  ok   -- $1"; }
_falla() { FALLA=$((FALLA+1)); echo "  FALLA-- $1"; }

TW_TMP="$(mktemp -d)"
trap 'rm -rf "$TW_TMP" 2>/dev/null' EXIT
mkdir -p "$TW_TMP/conversations"
printf '%s\n' \
  '{"role":"usuario","text":"como ando de sesion hoy"}' \
  '{"role":"mentis","text":"Todo bien por aca."}' > "$TW_TMP/conversations/remoto-abc.jsonl"
printf '%s\n' \
  '{"role":"usuario","text":"hablemos de la impresora 3D"}' \
  '{"role":"mentis","text":"Dale."}' \
  'esto no es json y no puede tumbar nada' \
  '{"role":"usuario","text":"gracias"}' > "$TW_TMP/conversations/2026-07-30-xyz.jsonl"
: > "$TW_TMP/conversations/vacia.jsonl"

TWW="$(cygpath -w "$TW_TMP" 2>/dev/null || printf '%s' "$TW_TMP")"
_py() { PYTHONPATH="$(cygpath -w "$HERE/engine" 2>/dev/null || printf '%s' "$HERE/engine")" python3 -c "$1" "$TWW" 2>&1 | tr -d '\r'; }

echo "== la pagina del celular: conversaciones, buscador, resumen, estadisticas y foto =="

python3 -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$(cygpath -w "$HERE/engine/nv_web_extras.py")" \
  && _ok "sintaxis ok: nv_web_extras.py" || _falla "sintaxis rota en nv_web_extras.py"
python3 -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$(cygpath -w "$HERE/engine/nv_web_server.py")" \
  && _ok "sintaxis ok: nv_web_server.py" || _falla "sintaxis rota en nv_web_server.py"

echo "-- lista de conversaciones"
R="$(_py 'import sys,nv_web_extras as x; c=x.listar_conversaciones(sys.argv[1]); print(len(c)); print(",".join(i["id"] for i in c))')"
N="$(printf '%s' "$R" | head -1)"
if [ "$N" = "2" ]; then _ok "lista las 2 conversaciones con contenido"; else _falla "listo $N conversaciones, esperaba 2"; fi
printf '%s' "$R" | grep -q "vacia" && _falla "incluyo una conversacion vacia" || _ok "una conversacion vacia no aparece en la lista"

R="$(_py 'import sys,nv_web_extras as x; c=x.listar_conversaciones(sys.argv[1]); print(c[0]["origen"], c[0]["mensajes"])')"
printf '%s' "$R" | grep -qE "celular|computadora" && _ok "distingue si venia del celular o de la computadora" || _falla "no marca el origen"

# Una linea corrupta en el medio no puede tumbar la lectura: la app puede estar escribiendo.
R="$(_py 'import sys,nv_web_extras as x; c=[i for i in x.listar_conversaciones(sys.argv[1]) if i["id"].startswith("2026")]; print(c[0]["mensajes"])')"
if [ "$R" = "3" ]; then _ok "una linea corrupta se saltea y el resto se lee igual"; else _falla "con una linea rota leyo $R mensajes, esperaba 3"; fi

echo "-- buscador"
R="$(_py 'import sys,nv_web_extras as x; print(len(x.buscar(sys.argv[1], "impresora")))')"
[ "$R" -ge 1 ] && _ok "encuentra texto dentro de las conversaciones" || _falla "no encontro 'impresora'"
# Sin tildes: quien escribe rapido en un celular no pone tildes.
R="$(_py 'import sys,nv_web_extras as x; print(len(x.buscar(sys.argv[1], "sesión")))')"
[ "$R" -ge 1 ] && _ok "buscar con tilde encuentra el texto sin tilde" || _falla "la busqueda distingue tildes"
R="$(_py 'import sys,nv_web_extras as x; print(len(x.buscar(sys.argv[1], "")))')"
[ "$R" = "0" ] && _ok "una busqueda vacia no devuelve todo" || _falla "la busqueda vacia devolvio $R"
# Un parentesis suelto no puede hacer explotar la busqueda (por eso es literal, no regex).
R="$(_py 'import sys,nv_web_extras as x; print(len(x.buscar(sys.argv[1], "(((")))')"
[ "$R" = "0" ] && _ok "un texto con parentesis sueltos no rompe la busqueda" || _falla "la busqueda con '(((' devolvio algo raro: $R"

echo "-- resumen para retomar"
R="$(_py 'import sys,nv_web_extras as x; r=x.resumen_para_retomar(sys.argv[1], "remoto-abc"); print(r["total"], "el usuario:" in r["contexto"])')"
printf '%s' "$R" | grep -q "True" && _ok "arma el contexto listo para retomar la conversacion" || _falla "el resumen no arma contexto: $R"
R="$(_py 'import sys,nv_web_extras as x; print(x.resumen_para_retomar(sys.argv[1], "../../../etc/passwd"))')"
[ "$R" = "None" ] && _ok "un nombre con../ no sale de la carpeta de conversaciones" || _falla "posible fuga de ruta: $R"

echo "-- estadisticas"
R="$(_py 'import sys,nv_web_extras as x; e=x.estadisticas(sys.argv[1]); print(e["conversaciones"], e["mensajes"])')"
if [ "$R" = "2 5" ]; then _ok "cuenta bien conversaciones y mensajes ($R)"; else _falla "conto '$R', esperaba '2 5'"; fi

echo "-- foto"
R="$(_py 'import sys,nv_web_extras as x; print(x.guardar_foto(sys.argv[1], "")[1])')"
[ -n "$R" ] && _ok "sin imagen devuelve un error claro" || _falla "acepto una foto vacia"
R="$(_py 'import sys,nv_web_extras as x; print(x.guardar_foto(sys.argv[1], "data:image/png;base64,bm9lc3VuYWltYWdlbnJlYWxtZW50ZXBlcm9lc2xhcmdh")[1])')"
printf '%s' "$R" | grep -qi "no es una imagen" && _ok "un archivo que NO es imagen se rechaza por su firma" || _falla "acepto un archivo que no es imagen: $R"
R="$(_py '
import sys, base64, struct, zlib, nv_web_extras as x
def ch(t,d):
    c=t+d; return struct.pack(">I",len(d))+c+struct.pack(">I",zlib.crc32(c)&0xffffffff)
png=b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",1,1,8,2,0,0,0))+ch(b"IDAT",zlib.compress(b"\x00\xff\x00\x00"))+ch(b"IEND",b"")
ruta,err=x.guardar_foto(sys.argv[1],"data:image/png;base64,"+base64.b64encode(png).decode())
print("OK" if (ruta and not err) else ("ERR:"+str(err)))')"
[ "$R" = "OK" ] && _ok "un PNG chico pero valido se acepta (el piso de tamano no lo descarta)" || _falla "rechazo un PNG valido: $R"

echo "-- el modo remoto no gana capacidades nuevas"
# Los endpoints agregados son de lectura; el unico que escribe guarda una imagen validada y NO
# dispara ningun turno. Que eso siga siendo asi se verifica sobre el codigo.
if grep -q "def guardar_foto" "$HERE/engine/nv_web_extras.py" && ! grep -qE "subprocess|os\.system|Popen" "$HERE/engine/nv_web_extras.py"; then
  _ok "nv_web_extras.py no ejecuta NADA: no corre procesos ni comandos"
else
  _falla "nv_web_extras.py puede ejecutar procesos -- eso el modo remoto no lo puede hacer"
fi

echo "-- los endpoints estan cableados y detras del token"
for e in conversaciones buscar resumen estadisticas foto; do
  grep -q "/api/$e" "$HERE/engine/nv_web_server.py" && _ok "endpoint /api/$e cableado" || _falla "falta /api/$e"
done
# El chequeo de token va ANTES de cualquier ruta nueva: si alguna quedara arriba, seria publica.
LIN_TOKEN="$(grep -n "_token_ok(self)" "$HERE/engine/nv_web_server.py" | head -1 | cut -d: -f1)"
LIN_CONV="$(grep -n '"/api/conversaciones"' "$HERE/engine/nv_web_server.py" | head -1 | cut -d: -f1)"
if [ -n "$LIN_TOKEN" ] && [ -n "$LIN_CONV" ] && [ "$LIN_TOKEN" -lt "$LIN_CONV" ]; then
  _ok "las rutas nuevas quedan DESPUES del chequeo de token"
else
  _falla "alguna ruta nueva podria estar quedando sin token"
fi

echo
echo "== Resultado: $OK ok, $FALLA falla(s) =="
[ "$FALLA" = "0" ] || exit 1
exit 0
