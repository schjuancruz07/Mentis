#!/usr/bin/env bash
# test-aprender.sh -- el learning loop con frenos (mentis-aprender.sh y sus cinco reglas).
#
# Cada prueba corresponde a una falla REAL del 2026-07-27: las tres memorias falsas que Mentis
# se genero solo en un dia. No son casos inventados -- son regresiones.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$HERE/.." && pwd)"
OK=0; FALLOS=0
ok()  { echo "  ok   -- $1"; OK=$((OK+1)); }
mal() { echo "  MAL  -- $1"; FALLOS=$((FALLOS+1)); }

APR_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/aprender-$$")"
mkdir -p "$APR_TMP/memoria"
trap 'rm -rf "$APR_TMP"' EXIT
MSG="$APR_TMP/mensaje.txt"
printf 'Prefiero que las respuestas sean cortas y sin preambulos.' > "$MSG"

echo "== REGLA 2: de un turno que fallo no se aprende =="
SAL="$(MENTIS_MEMDIR="$APR_TMP/memoria" bash "$RAIZ/mentis-aprender.sh" destilar "$MSG" --turno-fallo 2>&1)"
if echo "$SAL" | grep -q "regla 2"; then ok "corta antes de llamar al modelo"; else mal "no corto: $SAL"; fi
if [ -z "$(ls -A "$APR_TMP/memoria" 2>/dev/null)" ]; then
  ok "no dejo ninguna memoria"
else
  mal "creo una memoria a partir de un turno fallido"
fi

echo "== REGLA 3: de una transcripcion dudosa tampoco =="
SAL="$(MENTIS_MEMDIR="$APR_TMP/memoria" bash "$RAIZ/mentis-aprender.sh" destilar "$MSG" --confianza -1.4 2>&1)"
if echo "$SAL" | grep -q "regla 3"; then ok "descarta la baja confianza"; else mal "no descarto: $SAL"; fi
# Y que NO descarte una transcripcion buena, o no se aprenderia nunca nada.
SAL="$(MENTIS_MEMDIR="$APR_TMP/memoria" timeout 5 bash "$RAIZ/mentis-aprender.sh" destilar "$MSG" --confianza -0.18 2>&1)"
if echo "$SAL" | grep -q "regla 3"; then
  mal "descarto una transcripcion BUENA (-0.18): nunca aprenderia nada"
else
  ok "deja pasar la transcripcion buena"
fi

echo "== REGLA 5: nace provisional, no llega al modelo, se confirma, caduca =="
cat > "$APR_TMP/memoria/auto-prov.md" <<'EOF'
---
name: auto-prov
description: Observacion sin confirmar
type: user
estado: provisional
visto: 1
---

Observacion sin confirmar
EOF
cat > "$APR_TMP/memoria/auto-firme.md" <<'EOF'
---
name: auto-firme
description: Hecho ya confirmado
type: user
estado: firme
visto: 3
---

Hecho ya confirmado
EOF
cat > "$APR_TMP/memoria/vieja-sin-estado.md" <<'EOF'
---
name: vieja-sin-estado
description: Memoria anterior a este sistema
type: user
---

Memoria anterior a este sistema
EOF
printf -- '- [auto-prov] (user): Observacion sin confirmar\n- [auto-firme] (user): Hecho ya confirmado\n- [vieja-sin-estado] (user): Memoria anterior a este sistema\n' \
  > "$APR_TMP/memoria/indice.md"

VISTO="$(python3 "$RAIZ/engine/memorias_firmes.py" --indice "$APR_TMP/memoria/indice.md" --memorias "$APR_TMP/memoria" 2>/dev/null)"
if echo "$VISTO" | grep -q "auto-firme"; then ok "la firme llega al modelo"; else mal "la firme no llega"; fi
if echo "$VISTO" | grep -q "auto-prov"; then
  mal "la PROVISIONAL llega al modelo (la regla 5 no sirve de nada)"
else
  ok "la provisional queda en cuarentena"
fi
if echo "$VISTO" | grep -q "vieja-sin-estado"; then
  ok "las memorias anteriores al sistema se respetan"
else
  mal "degrado una memoria vieja que el usuario ya venia usando"
fi
if echo "$VISTO" | grep -q "provisional(es) sin confirmar"; then
  ok "le avisa que hay algo pendiente, sin decirle que dice"
else
  mal "no avisa que hay observaciones en cuarentena"
fi

echo "== confirmar vuelve firme =="
MENTIS_MEMDIR="$APR_TMP/memoria" bash "$RAIZ/mentis-aprender.sh" confirmar auto-prov >/dev/null 2>&1
VISTO="$(python3 "$RAIZ/engine/memorias_firmes.py" --indice "$APR_TMP/memoria/indice.md" --memorias "$APR_TMP/memoria" 2>/dev/null)"
if echo "$VISTO" | grep -q "auto-prov"; then ok "confirmada, ahora si llega al modelo"; else mal "sigue oculta tras confirmarla"; fi

echo "== caducidad: una provisional vieja se borra sola =="
cat > "$APR_TMP/memoria/auto-vencida.md" <<'EOF'
---
name: auto-vencida
description: Nadie la confirmo nunca
type: user
estado: provisional
visto: 1
---

Nadie la confirmo nunca
EOF
printf -- '- [auto-vencida] (user): Nadie la confirmo nunca\n' >> "$APR_TMP/memoria/indice.md"
# Se la envejece 30 dias tocando su fecha de modificacion.
touch -d "30 days ago" "$APR_TMP/memoria/auto-vencida.md" 2>/dev/null || touch -t "$(date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$APR_TMP/memoria/auto-vencida.md" 2>/dev/null
MENTIS_MEMDIR="$APR_TMP/memoria" bash "$RAIZ/mentis-aprender.sh" caducar >/dev/null 2>&1
if [ -f "$APR_TMP/memoria/auto-vencida.md" ]; then
  mal "la provisional vencida sigue ahi"
else
  ok "la provisional vencida se borro sola"
fi
if [ -f "$APR_TMP/memoria/auto-firme.md" ]; then
  ok "una firme NO se toca al caducar"
else
  mal "borro una memoria firme"
fi

echo "== REGLA 6: una limitacion tecnica vence antes que un hecho sobre el usuario =="
# Regresión del caso real: Mentis guardó "la búsqueda web está bloqueada" y durante SEMANAS se
# negó a intentarlo. La causa era un bug de una línea en el navegador. Como no intentaba, nunca
# descubría que ya funcionaba: la memoria se cumplía sola.
cat > "$APR_TMP/memoria/auto-limitacion.md" <<'EOF'
---
name: auto-limitacion
description: La busqueda web no funciona
type: feedback
estado: provisional
visto: 1
limitacion: si
---

La busqueda web no funciona
EOF
cat > "$APR_TMP/memoria/auto-gusto.md" <<'EOF'
---
name: auto-gusto
description: A el usuario le gusta el mate amargo
type: user
estado: provisional
visto: 1
---

A el usuario le gusta el mate amargo
EOF
# Las dos tienen 3 días: la limitación ya venció (2), el gusto todavía no (7).
for f in auto-limitacion auto-gusto; do
  touch -d "3 days ago" "$APR_TMP/memoria/$f.md" 2>/dev/null || true
done
MENTIS_MEMDIR="$APR_TMP/memoria" bash "$RAIZ/mentis-aprender.sh" caducar >/dev/null 2>&1
if [ -f "$APR_TMP/memoria/auto-limitacion.md" ]; then
  mal "la limitacion vieja sigue ahi: Mentis seguiria creyendo que no puede"
else
  ok "la limitacion vencio a los 2 dias y se volvera a comprobar"
fi
if [ -f "$APR_TMP/memoria/auto-gusto.md" ]; then
  ok "un hecho sobre el usuario NO vence a los 2 dias"
else
  mal "borro un hecho sobre el usuario con el plazo corto de las limitaciones"
fi

echo "== REGLA 4: reconoce un duplicado por SIGNIFICADO, no por nombre =="
if [ -f "$RAIZ/engine/memorias-index.jsonl" ] || [ -d "$RAIZ/memoria" ]; then
  RES="$(timeout 200 bash "$RAIZ/mentis-recordar.sh" --memorias "como le gusta al usuario que sean las respuestas" 2>/dev/null | head -3)"
  if [ -n "${RES// }" ]; then
    ok "la busqueda sobre memorias devuelve resultados"
  else
    mal "la busqueda sobre memorias no devolvio nada"
  fi
else
  echo "  (salteado: no hay memorias reales para consultar)"
fi

echo
echo "RESULTADO: $OK ok, $FALLOS fallos."
[ "$FALLOS" -eq 0 ] || exit 1
