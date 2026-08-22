#!/usr/bin/env bash
# test-depto-aritmetica.sh -- la guarda que no le cree al modelo cuando suma.
#
# POR QUE EXISTE (2026-08-20): la guarda se creo esa manana, despues de que Presupuestos escribiera
# los items bien y totalizara 288.400 en vez de 202.400. Nacio sin test. Esa misma tarde, en tres
# corridas de control, dejo pasar EXACTAMENTE el mismo error: un presupuesto que sumaba 262.400
# donde iban 202.400, y el departamento cerro con rc=0.
#
# La causa no fue la aritmetica sino el FORMATO: el modelo escribio "= **262400 ARS**" y el patron
# esperaba un digito despues del '='. En el mismo archivo, el presupuesto de al lado tenia el total
# sin negrita y ese SI se verificaba. Una guarda que mira o no mira segun como el modelo formateo
# la linea no es una guarda.
#
# De ahi las dos reglas de este test:
#   1. cada caso se prueba en LAS DOS formas, con marcas de markdown y sin ellas;
#   2. hay casos que TIENEN que pasar limpio -- una guarda que grita siempre se termina apagando.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARDA="$HERE/engine/depto_aritmetica.py"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# _revisar <texto> -> imprime la salida; devuelve el rc de la guarda
_revisar() {
  printf '%s\n' "$1" > "$SB/caso.md"
  python3 "$GUARDA" "$(cygpath -w "$SB/caso.md" 2>/dev/null || printf '%s' "$SB/caso.md")" 2>&1
}
_rc() {
  printf '%s\n' "$1" > "$SB/caso.md"
  python3 "$GUARDA" "$(cygpath -w "$SB/caso.md" 2>/dev/null || printf '%s' "$SB/caso.md")" >/dev/null 2>&1
  echo $?
}

echo "== una suma mal, escrita de las dos formas =="
PLANO='# Presupuesto
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
- 8 * 2500 = 20000 ARS
Subtotal: 144000 + 38400 + 20000 = 262400 ARS
Total: 262400 ARS'
[ "$(_rc "$PLANO")" = "3" ] && _ok "la caza en texto plano" || _mal "suma mal en texto plano" "paso como buena"

NEGRITA='# Presupuesto
- **3 * 48000 = 144000 ARS**
- **12 * 3200 = 38400 ARS**
- **8 * 2500 = 20000 ARS**
**Subtotal**: 144000 + 38400 + 20000 = **262400 ARS**
**Total**: 262400 ARS'
[ "$(_rc "$NEGRITA")" = "3" ] && _ok "la caza en negrita (el caso REAL que se escapo)" \
  || _mal "suma mal en negrita" "es exactamente el error de 60.000 pesos que dejo pasar"

BACKTICK='# Presupuesto
- `3 * 48000 = 144000` ARS
- `12 * 3200 = 38400` ARS
Subtotal: 144000 + 38400 = `182401` ARS'
[ "$(_rc "$BACKTICK")" = "3" ] && _ok "la caza entre backticks" || _mal "suma mal entre backticks" "paso como buena"

echo ""
echo "== un producto mal =="
[ "$(_rc '- 3 * 48000 = 145000 ARS')" = "3" ] && _ok "3 x 48000 no da 145000" || _mal "producto mal" "paso como bueno"
[ "$(_rc '- **7 x 1500 = 11000 ARS**')" = "3" ] && _ok "y tambien en negrita" || _mal "producto mal en negrita" "paso como bueno"

echo ""
echo "== el total suelto, sin la suma escrita =="
# La forma mas natural de escribir un presupuesto: los items y abajo el total. Antes no habia
# NADA que verificar en este caso, porque no existia una linea "a + b = c" que mirar.
SUELTO='# Presupuesto
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
Total: 200000 ARS'
[ "$(_rc "$SUELTO")" = "3" ] && _ok "suma los items y los compara con el total declarado" \
  || _mal "total suelto" "sin la cuenta escrita no verifica nada"
# El mensaje se captura en una variable en vez de mandarlo por un pipe: con `set -o pipefail` el
# pipe se queda con el codigo de la guarda (3, porque encontro el error), asi que
# `_revisar... | grep -q` daba FALLA aunque el grep hubiera acertado. Un test que se rompe solo
# por la forma de leer la salida reporta un bug que no existe -- que es lo que paso aca.
SAL_SUELTO="$(_revisar "$SUELTO" || true)"
case "$SAL_SUELTO" in
  *182400*) _ok "y dice cuanto tendria que dar" ;;
  *) _mal "mensaje del total" "no informa el valor correcto: $SAL_SUELTO" ;;
esac

echo ""
echo "== cada presupuesto se cuenta aparte =="
# Un archivo con dos presupuestos tiene dos totales. Si se sumaran todos los items del archivo
# contra un total, cualquier entregable con dos clientes daria error.
DOS='# Cliente A
- 2 * 1000 = 2000 ARS
- 3 * 1000 = 3000 ARS
Total: 5000 ARS

# Cliente B
- 4 * 500 = 2000 ARS
- 2 * 250 = 500 ARS
Total: 2500 ARS'
[ "$(_rc "$DOS")" = "0" ] && _ok "dos presupuestos correctos pasan limpio" \
  || _mal "dos presupuestos" "los mezclo: $(_revisar "$DOS" | head -2)"

DOS_MAL='# Cliente A
- 2 * 1000 = 2000 ARS
- 3 * 1000 = 3000 ARS
Total: 5000 ARS

# Cliente B
- 4 * 500 = 2000 ARS
- 2 * 250 = 500 ARS
Total: 9999 ARS'
[ "$(_rc "$DOS_MAL")" = "3" ] && _ok "y si uno de los dos esta mal, lo encuentra" || _mal "dos, uno mal" "paso como bueno"

echo ""
echo "== lo que NO tiene que gritar =="
# Una guarda con falsos positivos se termina apagando, y entonces no protege nada.
[ "$(_rc '# Presupuesto
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
- 8 * 2500 = 20000 ARS
Subtotal: 144000 + 38400 + 20000 = 202400 ARS
Total: 202400 ARS')" = "0" ] && _ok "un presupuesto correcto pasa limpio" || _mal "falso positivo" "un presupuesto bien hecho fue rechazado"

[ "$(_rc 'Recordatorio para Talleres Rivas: la factura A-0104 de 48.000 ARS vencio hace 12 dias.')" = "0" ] \
  && _ok "un texto sin cuentas pasa limpio" || _mal "falso positivo" "un borrador de cobranza fue rechazado"

# Con IVA, descuento o envio el total NO es la suma pelada de los items: no se puede exigir que lo sea.
CON_IVA='# Presupuesto
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
IVA 21%
Total: 220968 ARS'
[ "$(_rc "$CON_IVA")" = "0" ] && _ok "con IVA no exige que el total sea la suma pelada" \
  || _mal "falso positivo con IVA" "rechazaria todo presupuesto con impuestos"

# Miles con punto y con coma: las dos escrituras del mismo numero.
[ "$(_rc '- 3 * 48.000 = 144.000 ARS')" = "0" ] && _ok "entiende los miles con punto" || _mal "miles con punto" "los leyo mal"
[ "$(_rc '- 3 * 48,000 = 144,000 ARS')" = "0" ] && _ok "entiende los miles con coma" || _mal "miles con coma" "los leyo mal"

echo ""
echo "== --corregir: el motor arregla la suma en vez de pedirsela de nuevo al modelo =="
# POR QUE (2026-08-20): avisar del error deja el arreglo en manos del que no sabe sumar. Medido
# sobre tres corridas de Presupuestos: falla la aritmetica 1 de cada 3. Una suma es determinista.
_corregir() {   # <texto> -> imprime la salida; deja el archivo corregido en $SB/caso.md
  printf '%s
' "$1" > "$SB/caso.md"
  python3 "$GUARDA" --corregir "$(cygpath -w "$SB/caso.md" 2>/dev/null || printf '%s' "$SB/caso.md")" 2>&1
}

MAL='# Presupuesto
- 3 * 48000 = 144000 ARS
- 12 * 3200 = 38400 ARS
- 8 * 2500 = 20000 ARS
**Subtotal**: 144000 + 38400 + 20000 = **262400 ARS**
**Total**: 262400 ARS
Texto para el cliente: Total 262400 ARS'
SAL="$(_corregir "$MAL" || true)"
case "$SAL" in
  *"CORREGIDO: 262400 -> 202400"*) _ok "corrige el total y dice que lo hizo" ;;
  *) _mal "no corrigio" "salio: $SAL" ;;
esac
case "$SAL" in
  *"las cuentas cierran"*) _ok "y despues de corregir, las cuentas cierran" ;;
  *) _mal "quedo mal despues de corregir" "salio: $SAL" ;;
esac
# El numero corregido tiene que cambiar en TODAS sus apariciones: el total, el subtotal y el texto
# que el usuario copia y pega. Si se arregla el subtotal y el texto del cliente queda con el viejo, el
# error sale igual por la puerta.
if [ "$(grep -c '262400' "$SB/caso.md")" = "0" ] && [ "$(grep -c '202400' "$SB/caso.md")" = "3" ]; then
  _ok "el numero quedo corregido en las tres apariciones (subtotal, total y texto del cliente)"
else
  _mal "quedaron numeros viejos" "262400 aparece $(grep -c '262400' "$SB/caso.md") veces, 202400 aparece $(grep -c '202400' "$SB/caso.md")"
fi

# EL CASO QUE PODRIA ROMPERLO: dos presupuestos donde el total equivocado de uno es un numero
# CORRECTO en el otro. El reemplazo es por texto, asi que hay que comprobar que no arrastre.
CRUCE='# Cliente A
- 2 * 1000 = 2000 ARS
- 3 * 1000 = 3000 ARS
Subtotal: 2000 + 3000 = 6000 ARS

# Cliente B
- 3 * 2000 = 6000 ARS
- 1 * 1000 = 1000 ARS
Subtotal: 6000 + 1000 = 7000 ARS'
SAL="$(_corregir "$CRUCE" || true)"
if grep -q '3 \* 2000 = 6000' "$SB/caso.md"; then
  _ok "corregir el total de un presupuesto no toca los numeros del otro"
else
  _mal "el reemplazo arrastro numeros de otro presupuesto" "$(cat "$SB/caso.md")"
fi

echo ""
echo "== lo que --corregir NO tiene que tocar =="
# Un PRODUCTO mal no se corrige: el numero equivocado puede ser el precio unitario, y arreglar el
# resultado consolidaria el error y taparia que hay que releer la lista de precios.
PROD_MAL='# Presupuesto
- 3 * 48000 = 145000 ARS
- 2 * 1000 = 2000 ARS'
SAL="$(_corregir "$PROD_MAL" || true)"
case "$SAL" in
  *"CORREGIDO"*) _mal "corrigio un PRODUCTO" "si el precio unitario esta mal copiado, esto tapa el error de fondo" ;;
  *) _ok "un producto mal no se corrige solo: va a reintento" ;;
esac
grep -q '145000' "$SB/caso.md" && _ok "y el archivo queda como estaba" || _mal "toco el archivo" "no deberia"

# Sin --corregir, el archivo NO se toca: la verificacion sola tiene que seguir siendo de lectura.
printf '%s
' "$MAL" > "$SB/caso.md"
python3 "$GUARDA" "$(cygpath -w "$SB/caso.md" 2>/dev/null || printf '%s' "$SB/caso.md")" >/dev/null 2>&1
grep -q '262400' "$SB/caso.md" && _ok "sin --corregir no escribe nada" || _mal "modifico el archivo sin que se lo pidieran" "verificar tiene que ser de solo lectura"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
