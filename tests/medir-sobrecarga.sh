#!/usr/bin/env bash
# medir-sobrecarga.sh -- cuanto de una llamada NO es el modelo (Bloque A del plan 2026-08-03).
#
# POR QUE ESTA METRICA Y NO "cuanto tardo": la latencia total mezcla dos cosas que no se
# controlan igual. Lo que tarda el modelo depende de NVIDIA y varia entre 1,5 y 2,5 s para el
# mismo saludo; lo que tarda el andamiaje depende de nosotros. Medir el total hace que una
# mejora real quede tapada por la varianza del modelo -- que es exactamente lo que paso al medir
# el primer cambio y ver "solo 400 ms".
#
# SOBRECARGA = tiempo de punta a punta - latencia del modelo (que el propio motor ya reporta en
# la telemetria). Es el numero que tiene que bajar.
#
# Comparacion PAREADA (alternando A y B en la misma corrida) porque el free tier de NVIDIA
# cambia de humor hora a hora: medir "antes" y "despues" en momentos distintos da veredictos
# falsos. Es la leccion de las 5 trampas de medicion de la revision 2026-08-02.
set -uo pipefail
MS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS_ROOT="$(cd "$MS_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

VUELTAS="${1:-5}"
ROL="${2:-fast}"
LOG="$MS_ROOT/engine/logs/nv.jsonl"

_ultima_latencia() { tail -1 "$LOG" 2>/dev/null | grep -oE '"latencia_ms": *[0-9]+' | grep -oE '[0-9]+$'; }

_una() {
  local etiqueta="$1"; shift
  local t0 t1 total modelo
  t0="$(date +%s%3N)"
  env "$@" timeout 200 bash "$MS_ROOT/engine/ask-nvidia.sh" "$ROL" "Hola" >/dev/null 2>&1
  t1="$(date +%s%3N)"
  total=$(( t1 - t0 ))
  modelo="$(_ultima_latencia)"
  [ -n "$modelo" ] || modelo=0
  echo "$etiqueta $total $modelo $(( total - modelo ))"
}

echo "== sobrecarga del rol '$ROL', $VUELTAS vueltas pareadas =="
RES="$(mktemp)"
for _ in $(seq 1 "$VUELTAS"); do
  _una NUEVO NV_STREAM_OFF=0 >> "$RES"
  sleep 2
  _una VIEJO NV_STREAM_OFF=1 NV_MEMO_OFF=1 >> "$RES"
  sleep 2
done

python3 - "$(cygpath -w "$RES")" <<'PY'
import io, sys
filas = [l.split() for l in io.open(sys.argv[1], encoding="utf-8") if l.strip()]
def resumen(etq):
    xs = [(int(f[1]), int(f[2]), int(f[3])) for f in filas if f[0] == etq]
    if not xs: return None
    tot = sorted(x[0] for x in xs); mod = sorted(x[1] for x in xs); sob = sorted(x[2] for x in xs)
    m = len(xs)//2
    return tot[m], mod[m], sob[m], len(xs)
print()
print("  %-8s %10s %10s %12s" % ("camino", "total", "modelo", "SOBRECARGA"))
print("  " + "-"*44)
for etq in ("VIEJO", "NUEVO"):
    r = resumen(etq)
    if r: print("  %-8s %8d ms %8d ms %10d ms   (mediana de %d)" % (etq, r[0], r[1], r[2], r[3]))
a, b = resumen("VIEJO"), resumen("NUEVO")
if a and b:
    d = a[2] - b[2]
    print()
    print("  sobrecarga: %d ms -> %d ms   (%+d ms, %.0f%% menos)" % (a[2], b[2], -d, 100*d/a[2] if a[2] else 0))
PY
rm -f "$RES"
