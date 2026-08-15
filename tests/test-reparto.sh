#!/usr/bin/env bash
# test-reparto.sh -- el reparto automatico del modo Cowork: cuando entra, cuando no, y que hace
# con lo que le devuelve el planificador.
#
# POR QUE EXISTE: en el duelo contra CrewAI (2026-08-14) Mentis tenia 'parallel' habilitada y no
# la uso NI UNA VEZ en tres corridas. La persona del modo ya le pedia repartir; no alcanzo, porque
# una defensa (o un pedido) escrito como instruccion es una sugerencia. Ahora reparte el motor.
#
# Lo que se prueba aca es lo determinista: el parseo del plan (con el codigo REAL extraido del
# agente) y las condiciones de activacion. Si el reparto sirve o no -- eso es una medicion, y vive
# en eval/reparto-cowork/.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"
M="$HERE/mentis-chat.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== la activacion =="
grep -q 'p) REPARTO=1 ;;' "$A" && _ok "el motor acepta -p" || _mal "bandera -p" "sin bandera no hay como encenderlo"
grep -q '^REPARTO=0' "$A" && _ok "arranca apagado" || _mal "default apagado" "se activaria en todos los turnos"
grep -q 'MENTIS_REPARTO_OFF' "$A" && _ok "se puede apagar con MENTIS_REPARTO_OFF=1" || _mal "apagado de emergencia" "un cambio de comportamiento sin escape"
grep -q 'nv_modo_reparto' "$HERE/engine/nv-modos-lib.sh" && _ok "el modo declara el reparto en modos.json" || _mal "nv_modo_reparto" "no habria de donde leerlo"
# Que NO se active por tener 'parallel': el modo Code tambien la tiene y un fix de una linea no se
# parte en pedazos -- seria una llamada extra en cada turno de codigo.
if grep -q 'nv_modo_reparto "$MC_MODO"' "$M"; then
  _ok "la app lo enciende por la clave del modo, no por tener la herramienta"
else
  _mal "activacion por modo" "si se deduce de 'parallel', el modo Code hereda una llamada extra por turno"
fi
# Y que el modo pueda apagarlo sacando la herramienta: la regla de siempre es que un modo solo quita.
if awk '/REPARTO AUTOMATICO \(2026-08-14/,/^  fi$/' "$M" | grep -q 'parallel'; then
  _ok "si el modo saca 'parallel', el reparto se apaga con ella"
else
  _mal "el modo solo puede quitar" "el reparto sobreviviria a apagar la herramienta que usa"
fi
# APAGADO el 2026-08-14 por decision del usuario, con los numeros adelante: sobre 12 corridas el
# reparto saco 31/60 contra 37/60 sin repartir (ver eval/reparto-cowork/VEREDICTO.md). El
# mecanismo queda construido y probado; lo que se saco es la clave que lo enciende.
# La invariante de aca es que NADIE lo prenda de nuevo sin medirlo.
_CON="$(python3 -c "
import json,sys,io
d=json.load(io.open(sys.argv[1],encoding='utf-8'))
m=d.get('modos',d)
print(','.join(sorted(k for k,v in m.items() if v.get('reparto'))))
" "$(cygpath -w "$HERE/modos.json" 2>/dev/null || printf '%s' "$HERE/modos.json")" | tr -d '
')"
if [ -z "$_CON" ]; then
  _ok "hoy ningun modo reparte (apagado por medicion, no por olvido)"
elif [ "$_CON" = "cowork" ]; then
  _ok "el unico modo con reparto es Cowork (encendido a proposito)"
else
  _mal "quien reparte" "modos con reparto:true sin medir: $_CON"
fi

echo ""
echo "== el parseo del plan (codigo REAL extraido del agente) =="
# El planificador es un modelo: va a devolver el JSON envuelto en markdown, con texto adelante, o
# con elementos rotos. Si el parseo no aguanta eso, el reparto no se activa nunca y nadie se entera.
PARSER="$(mktemp)"
awk '/^  roles_prompts="\$\(printf/{f=1;next} f&&/^'"'"' 2>\/dev\/null\)"/{exit} f' "$A" > "$PARSER"
if [ "$(wc -l < "$PARSER")" -lt 8 ]; then
  _mal "se puede extraer el parser" "no se encontro en $A"
else
  _ok "el parser se extrae del agente ($(wc -l < "$PARSER") lineas)"
  parsear() { printf '%s' "$1" | python3 "$PARSER" 2>/dev/null | grep -c. ; }

  n="$(parsear '[{"role":"general","prompt":"a"},{"role":"code","prompt":"b"}]')"
  [ "$n" = "2" ] && _ok "un plan limpio de dos partes da dos" || _mal "plan limpio" "dio $n"

  n="$(parsear 'Claro, acá tenés el plan:
```json
[{"role":"general","prompt":"a"},{"role":"general","prompt":"b"},{"role":"general","prompt":"c"}]
```
Espero que sirva.')"
  [ "$n" = "3" ] && _ok "aguanta el JSON envuelto en markdown y con charla alrededor" || _mal "plan con markdown" "dio $n"

  n="$(parsear '[]')"
  [ "$n" = "0" ] && _ok "una tarea que no se parte devuelve cero (y no se reparte nada)" || _mal "plan vacio" "dio $n"

  n="$(parsear '[{"role":"general","prompt":"a"},"esto no es un objeto",{"role":"x","prompt":""}]')"
  [ "$n" = "1" ] && _ok "descarta elementos rotos y prompts vacios sin explotar" || _mal "plan roto" "dio $n"

  n="$(parsear '[{"role":"general","prompt":"1"},{"role":"general","prompt":"2"},{"role":"general","prompt":"3"},{"role":"general","prompt":"4"},{"role":"general","prompt":"5"},{"role":"general","prompt":"6"}]')"
  [ "$n" = "4" ] && _ok "corta en 4 partes aunque el plan pida mas" || _mal "tope de partes" "dio $n (sin tope, un plan de 20 abre 20 llamadas)"

  # Un rol inventado tiene que caer en uno real, no viajar tal cual a ask-nvidia.
  r="$(printf '%s' '[{"role":"inventado","prompt":"a"},{"role":"code","prompt":"b"}]' | python3 "$PARSER" 2>/dev/null | cut -f1 | tr '\n' ' ')"
  [ "$r" = "general code " ] && _ok "un rol que no existe cae en 'general'" || _mal "rol invalido" "dio: $r"

  n="$(parsear 'no hay ningun json aca')"
  [ "$n" = "0" ] && _ok "si el planificador no devuelve JSON, no se reparte (y el turno sigue igual)" || _mal "sin json" "dio $n"
fi
rm -f "$PARSER"

echo ""
echo "== hace falta MAS DE UNA parte para repartir =="
# Repartir una sola parte es pagar una llamada extra para no ganar nada.
if awk '/^_auto_reparto\(\)/,/^}/' "$A" | grep -q '\-ge 2'; then
  _ok "con menos de dos partes no reparte"
else
  _mal "umbral de dos" "repartiria tareas de una sola parte"
fi
# Y el material repartido tiene que entrar al historial con la instruccion de NO rehacerlo.
if grep -q 'NO las vuelvas a generar' "$A"; then
  _ok "al modelo se le dice que el material ya esta hecho"
else
  _mal "nota del reparto" "sin eso vuelve a generar todo y el reparto no sirvio de nada"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
