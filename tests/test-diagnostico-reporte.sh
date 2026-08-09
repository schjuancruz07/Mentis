#!/usr/bin/env bash
# test-diagnostico-reporte.sh -- el reporte que la gente le manda al usuario cuando algo no anda.
#
# QUE SE PRUEBA Y POR QUE:
#   Mentis lo usa mas gente, en maquinas que el usuario no tiene adelante. `--reporte` arma un archivo
#   con datos tecnicos para que puedan pedirle ayuda. Todo el valor de esa funcion depende de UNA
#   cosa: que se pueda mandar sin miedo.
#
#   La primera version incluia la direccion completa de la pagina del celular, con el token de
#   acceso adentro, justo debajo de una linea que prometia que no habia claves. Cualquiera que lo
#   mandara por WhatsApp estaba regalando la llave de su Mentis. Se descubrio LEYENDO el archivo
#   generado, no revisando el codigo -- por eso este test abre el archivo de verdad y lo revisa
#   entero, en vez de mirar el script que lo escribe.
set -uo pipefail
TR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TR_ROOT="$(cd "$TR_HERE/.." && pwd)"
TR_OK=0; TR_MAL=0
_ok()  { TR_OK=$((TR_OK+1));  echo "  OK   $1"; }
_mal() { TR_MAL=$((TR_MAL+1)); echo "  MAL  $1  ($2)"; }

TR_TMP="$(mktemp -d)"
case "$TR_TMP" in "$TR_ROOT"|"$TR_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TR_TMP" 2>/dev/null' EXIT
TR_ARCH="$TR_TMP/reporte.txt"

echo "== el reporte que se manda =="
echo "-- generandolo de verdad (tarda: llama a los modelos)"
if timeout 560 bash "$TR_ROOT/mentis-diagnostico.sh" --reporte "$TR_ARCH" >/dev/null 2>&1 && [ -s "$TR_ARCH" ]; then
  _ok "el reporte se genera ($(wc -l < "$TR_ARCH") lineas)"
else
  _mal "no se pudo generar el reporte" "$TR_ARCH vacio o el comando fallo"
  echo; echo "== $TR_OK OK, $TR_MAL MAL =="; exit 1
fi

echo "-- lo que NO puede tener adentro"

# El token de la pagina: es la llave de acceso desde la red. Este es el que se colo la primera vez.
TR_TOKEN="$(bash "$TR_ROOT/mentis-web.sh" token 2>/dev/null | tr -d ' \r\n')"
if [ -n "$TR_TOKEN" ] && grep -qF "$TR_TOKEN" "$TR_ARCH" 2>/dev/null; then
  _mal "EL TOKEN DE LA PAGINA ESTA EN EL REPORTE" "quien lo mande regala el acceso a su Mentis"
else
  _ok "el token de la pagina no aparece"
fi

# Claves de API, con el patron de cada proveedor.
TR_CLAVES=0
for pat in "nvapi-[A-Za-z0-9_-]\{20,\}" "sk-[A-Za-z0-9]\{20,\}" "ghp_[A-Za-z0-9]\{20,\}"; do
  grep -qE "$pat" "$TR_ARCH" 2>/dev/null && TR_CLAVES=$((TR_CLAVES+1))
done
[ "$TR_CLAVES" -eq 0 ] && _ok "no hay claves de API" \
  || _mal "hay $TR_CLAVES clave(s) de API en el reporte" "no se puede mandar asi"

# La clave real de esta maquina, comparada literal: el chequeo mas directo posible.
TR_REAL="$(bash -c 'source "'"$TR_ROOT"'/engine/nv-lib.sh" 2>/dev/null; nv_read_setting NVIDIA_API_KEY' 2>/dev/null | tr -d ' \r\n')"
if [ -n "$TR_REAL" ] && grep -qF "$TR_REAL" "$TR_ARCH" 2>/dev/null; then
  _mal "la clave de NVIDIA de esta maquina esta en el reporte" "fuga directa"
else
  _ok "la clave de NVIDIA no aparece"
fi

# Conversaciones y memorias: lo mas privado que hay en la carpeta.
if [ -d "$TR_ROOT/conversations" ]; then
  TR_FRASE="$(find "$TR_ROOT/conversations" -type f -name '*.jsonl' 2>/dev/null | head -1 | xargs -r tail -1 2>/dev/null \
              | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
    t = (d.get("text") or "").strip()
    print(t[:40] if len(t) >= 20 else "")
except Exception:
    print("")
' 2>/dev/null)"
  if [ -n "$TR_FRASE" ] && grep -qF "$TR_FRASE" "$TR_ARCH" 2>/dev/null; then
    _mal "hay texto de una conversacion real en el reporte" "$(printf '%s' "$TR_FRASE" | head -c 40)"
  else
    _ok "no hay texto de conversaciones"
  fi
fi

# El mail del dueño (armado en dos pedazos para que este archivo no lo contenga entero).
TR_U="usuario"; TR_U="${TR_U}07"
grep -qi "$TR_U" "$TR_ARCH" 2>/dev/null \
  && _mal "aparece el mail del dueño" "dato personal" \
  || _ok "no aparece el mail de nadie"

echo "-- pero tiene que servir para diagnosticar"
for campo in "python3" "node" "NVIDIA_API_KEY" "modelos" "pagina del celular"; do
  grep -qi "$campo" "$TR_ARCH" 2>/dev/null \
    && _ok "informa: $campo" \
    || _mal "al reporte le falta '$campo'" "sin eso no se puede ayudar a nadie"
done

# Que diga si la clave esta o no, pero nunca cual.
grep -qE "NVIDIA_API_KEY: (si|NO)" "$TR_ARCH" 2>/dev/null \
  && _ok "dice si la clave esta, sin decir cual" \
  || _mal "no informa el estado de la clave" "es el primer dato que hace falta"

echo
echo "== $TR_OK OK, $TR_MAL MAL =="
[ "$TR_MAL" -eq 0 ]
