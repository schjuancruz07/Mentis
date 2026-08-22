#!/usr/bin/env bash
# test-depto-correccion.sh -- que el departamento CORRIJA la aritmetica de verdad, no que
# "tenga el codigo puesto".
#
# POR QUE EXISTE (2026-08-20): el cableado de `--corregir` se agrego despues de medir que
# Presupuestos falla la aritmetica 1 de cada 3 veces. Las corridas reales de control salieron con
# las cuentas bien -- o sea que la correccion NO se ejecuto ni una vez, y quedo sin probar que
# funcione cuando haga falta. Verificar leyendo el codigo no alcanza: la primera version de esa
# condicion comparaba contra "true" cuando el valor que llega es "True" (python imprime asi los
# booleanos de JSON), y NO SE HABRIA ACTIVADO NUNCA.
#
# Aca el modelo se reemplaza por un stub que escribe un entregable con la suma mal a proposito.
# Asi se prueba el camino completo -- departamento -> guarda -> correccion -> archivo -- sin gastar
# una sola llamada, y con el caso que en las corridas reales aparece 1 de cada 3.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/engine" "$SB/empresa" "$SB/memoria/departamentos"
cp "$HERE/mentis-departamento.sh" "$SB/"
cp "$HERE/engine/depto_aritmetica.py" "$HERE/engine/depto_cobertura.py" "$SB/engine/" 2>/dev/null || true
printf '#!/usr/bin/env bash\necho foto-de-prueba\n' > "$SB/mentis-deshacer.sh"

# Datos de la empresa, de mentira.
cat > "$SB/empresa/lista-precios.json" <<'JSON'
{"items": [{"codigo": "CH-01", "precio": 48000}, {"codigo": "CO-05", "precio": 3200}]}
JSON
cat > "$SB/empresa/consultas.json" <<'JSON'
{"consultas": [{"id": "C-31", "cliente": "Talleres Rivas"}]}
JSON

# Un departamento de prueba con la verificacion de aritmetica encendida.
cat > "$SB/departamentos.json" <<'JSON'
{
  "version": 1,
  "departamentos": {
    "prueba": {
      "titulo": "Prueba",
      "objetivo": "probar la correccion",
      "medida": "que las cuentas cierren",
      "rol": "reason",
      "fuente": ["empresa/lista-precios.json", "empresa/consultas.json"],
      "salida": "empresa/salida-prueba.md",
      "herramientas": ["read", "write"],
      "irreversibles": ["enviar"],
      "tope_por_turno": 5,
      "memoria": "prueba",
      "disparadores": ["prueba"],
      "persona": "Sos un departamento de prueba.",
      "verificar_aritmetica": true
    }
  }
}
JSON

# EL STUB DEL MODELO: escribe un entregable con la suma MAL, igual que la corrida real que fallo
# (144000 + 38400 + 20000 = 262400, cuando da 202400), y con el total en negrita, que es como el
# modelo lo escribio de verdad.
cat > "$SB/engine/nv-agent.sh" <<'STUB'
#!/usr/bin/env bash
# Escribe el entregable con la suma equivocada, como hizo el modelo de verdad.
DEST=""
while [ $# -gt 0 ]; do
  case "$1" in -d) DEST="$2"; shift 2 ;; *) shift ;; esac
done
cat > "$DEST/salida-prueba.md" <<'MD'
# Presupuesto C-31 - Talleres Rivas
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
- 8 * 2500 = 20000 ARS
**Subtotal**: 144000 + 38400 + 20000 = **262400 ARS**
**Total**: 262400 ARS
Texto para copiar y pegar: Presupuesto para Talleres Rivas, total 262400 ARS
MD
echo "listo, presupuesto escrito"
STUB
chmod +x "$SB/engine/nv-agent.sh"

echo "== el departamento corre y deja el entregable =="
SALIDA="$(cd "$SB" && MENTIS_DEPARTAMENTOS="$SB/departamentos.json" \
  MENTIS_LIBRO_MAYOR="$SB/memoria/departamentos/libro-mayor.jsonl" \
  timeout -k 10 90 bash "$SB/mentis-departamento.sh" correr prueba "hacelo" 2>&1 </dev/null)"
if [ -f "$SB/empresa/salida-prueba.md" ]; then
  _ok "el entregable existe"
else
  _mal "no se genero el entregable" "sin eso, lo de abajo no significa nada"
  printf '%s\n' "$SALIDA" | head -10
  echo "== $ok ok, $fallo fallan =="; exit 1
fi

echo ""
echo "== LA CORRECCION SE EJECUTO DE VERDAD =="
# Lo que importa no es que el codigo este escrito: es que el numero del archivo haya cambiado.
if grep -q "202400" "$SB/empresa/salida-prueba.md"; then
  _ok "el total quedo corregido a 202400 en el archivo"
else
  _mal "el total NO se corrigio" "el archivo dice: $(grep -i total "$SB/empresa/salida-prueba.md" | head -2 | tr '\n' ' ')"
fi
if grep -q "262400" "$SB/empresa/salida-prueba.md"; then
  _mal "quedo el numero viejo en alguna linea" "$(grep -n '262400' "$SB/empresa/salida-prueba.md" | head -2 | tr '\n' ' ')"
else
  _ok "no quedo ni una aparicion del numero equivocado"
fi
# Incluido el texto que el usuario copia y le manda al cliente: es el que sale por la puerta.
if grep -q "copiar y pegar.*202400" "$SB/empresa/salida-prueba.md"; then
  _ok "el texto para el cliente tambien quedo con el numero bueno"
else
  _mal "el texto del cliente quedo con el numero viejo" "es el que se manda: el error saldria igual"
fi

echo ""
echo "== y lo dice, no lo hace en silencio =="
# Corregir un numero del entregable sin avisar seria peor que no corregirlo: el usuario tiene que poder
# enterarse de que el modelo se equivoco, que es justamente el dato del periodo de prueba.
case "$SALIDA" in
  *"aritmetica corregida"*) _ok "avisa en el log que corrigio" ;;
  *) _mal "corrigio en silencio" "el usuario no se enteraria de que el modelo sumo mal" ;;
esac
case "$SALIDA" in
  *"262400 -> 202400"*) _ok "y dice exactamente que numero cambio" ;;
  *) _mal "no dice que cambio" "un aviso sin el detalle no se puede auditar" ;;
esac

echo ""
echo "== el departamento cierra bien despues de corregir =="
case "$SALIDA" in
  *"entregable verificado"*) _ok "el entregable pasa la verificacion una vez corregido" ;;
  *) _mal "no lo dio por bueno" "corrigio pero igual lo rechaza: se llevaria dos reintentos al pedo" ;;
esac

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
