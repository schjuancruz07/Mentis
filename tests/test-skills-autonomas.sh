#!/usr/bin/env bash
# test-skills-autonomas.sh -- Mentis usando sus propias habilidades sin que el usuario escriba el comando.
#
# LO QUE HAY QUE PROTEGER: hasta el 2026-07-30 el prompt le decía "vos NO podés ejecutarlas". Ahora
# puede, pero SÓLO las que el usuario habilitó en skills-autonomas.json, y las cinco que dejan algo hecho
# después del turno tienen que dejar un RECIBO con cómo deshacerlo.
#
# Por qué eso importa, con nombres propios: /builder y /multiply no son "skills", son agentes --
# corren nv-agent.sh CON -w, o sea con permiso de escribir archivos y ejecutar comandos. Si la
# lista de permisos fallara, "usar una skill sola" se convertiría en "hacer cualquier cosa sola".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FALLO=0
_ok()  { echo "ok: $1"; PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1"; FALLO=$((FALLO+1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/engine" "$SB/capabilities" "$SB/workspace"
cp "$DIR/engine/nv-agent.sh" "$DIR/engine/nv-lib.sh" "$SB/engine/"
cp "$DIR/engine/nv-verify.sh" "$SB/engine/" 2>/dev/null || true
cp "$DIR/skills-autonomas.json" "$SB/"

# Skills de mentira: una "libre" y una "con recibo", que sólo dicen que corrieron.
printf '#!/usr/bin/env bash\necho "CORRIO-LIBRE con: $*"\n' > "$SB/capabilities/where.sh"
printf '#!/usr/bin/env bash\necho "CORRIO-RECIBO con: $*"\n' > "$SB/capabilities/programar.sh"
printf '#!/usr/bin/env bash\necho "NO-DEBERIA-CORRER"\n' > "$SB/capabilities/prohibida.sh"
chmod +x "$SB/capabilities/"*.sh
printf '#!/usr/bin/env bash\necho "foto-de-prueba-777"\n' > "$SB/mentis-deshacer.sh"
chmod +x "$SB/mentis-deshacer.sh"

# Stub del modelo: pide la skill que le indiquemos y después termina.
cat > "$SB/engine/ask-nvidia.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
N="$(cat "${STUB_STATE:?}" 2>/dev/null || echo 0)"; N=$((N+1)); echo "$N" > "$STUB_STATE"
cat > /dev/null
if [ "$N" = "1" ]; then
  printf '{"tool":"skill","action":"%s","value":"%s"}\n' "${STUB_SKILL:?}" "${STUB_ARG:-}"
else
  printf '{"tool":"done","answer":"listo"}\n'
fi
STUB
chmod +x "$SB/engine/ask-nvidia.sh"

_correr() {   # _correr <skill> [banderas...]
  local skill="$1"; shift
  rm -f "$SB/state"
  STUB_STATE="$SB/state" STUB_SKILL="$skill" STUB_ARG="algo" \
  MENTIS_SETTINGS_FILE="$SB/nope.json" \
    bash "$SB/engine/nv-agent.sh" -d "$SB/workspace" -m code -i 3 "$@" "tarea" 2>&1
}

echo "== 0. GUARDIA: el agente corre de verdad en el sandbox =="
SAL="$(_correr where -K)"
if printf '%s' "$SAL" | grep -qE '\[nv-agent\] iter 1:'; then
  _ok "el agente ejecutó una iteración"
else
  _bad "el agente no arrancó -- lo de abajo no significa nada"
  echo "$SAL" | head -5; echo; echo "RESULTADO: $PASS ok, $FALLO fallos."; exit 1
fi

echo "== 1. una skill LIBRE corre sin avisar nada =="
case "$SAL" in
  *"iter 1: skill where"*) _ok "corrió /where por su cuenta" ;;
  *) _bad "no corrió la skill libre" ;;
esac
case "$SAL" in
  *"SKILL-RECIBO"*) _bad "una skill libre dejó recibo (ruido innecesario)" ;;
  *) _ok "y no dejó recibo, que es el punto de 'libre'" ;;
esac

echo "== 2. una skill CON RECIBO corre igual, pero deja rastro y punto de retorno =="
SAL="$(_correr programar -K)"
case "$SAL" in
  *"iter 1: skill programar"*) _ok "corrió /programar sin frenar a pedir permiso" ;;
  *) _bad "no corrió la skill de recibo" ;;
esac
case "$SAL" in
  *"SKILL-RECIBO programar :: foto-de-prueba-777"*) _ok "dejó recibo con el punto de retorno real" ;;
  *"SKILL-RECIBO programar"*) _bad "dejó recibo pero SIN punto de retorno: no se podría deshacer" ;;
  *) _bad "no dejó recibo: el usuario no se enteraría de que agendó una tarea" ;;
esac

echo "== 3. una skill que NO está en la lista no corre =="
SAL="$(_correr prohibida -K)"
case "$SAL" in
  *"NO-DEBERIA-CORRER"*) _bad "CORRIÓ UNA SKILL NO AUTORIZADA" ;;
  *) _ok "no ejecutó la skill que no está en el registro" ;;
esac
case "$SAL" in
  *"skill RECHAZADO (no autorizada"*) _ok "y lo dice con todas las letras en el log" ;;
  *) _bad "la rechazó sin explicar por qué" ;;
esac

echo "== 4. sin la bandera -K no hay skills, aunque el registro diga que sí =="
SAL="$(_correr where)"
case "$SAL" in
  *"skill RECHAZADO (sin -K)"*) _ok "sin -K no corre ninguna" ;;
  *) _bad "corrió una skill sin tener la bandera habilitada" ;;
esac

echo "== 5. no se puede salir de la carpeta de skills con el nombre =="
for veneno in "../mentis-backup" "..\\\\mentis-backup" "/etc/passwd" "where;rm -rf." "Where"; do
  SAL="$(_correr "$veneno" -K)"
  case "$SAL" in
    *"skill RECHAZADO (no existe"*) _ok "rechazó el nombre '$veneno'" ;;
    *) _bad "el nombre '$veneno' NO fue rechazado como debía" ;;
  esac
done

echo "== 6. el registro es la única fuente de verdad =="
# Si el usuario pone una skill en 'no', deja de correr aunque exista y aunque esté -K.
python3 - "$SB/skills-autonomas.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["where"] = "no"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
SAL="$(_correr where -K)"
case "$SAL" in
  *"CORRIO-LIBRE"*) _bad "siguió corriendo una skill que el usuario puso en 'no'" ;;
  *) _ok "apagar una skill en el registro la apaga de verdad" ;;
esac

echo
echo "RESULTADO: $PASS ok, $FALLO fallos."
[ "$FALLO" -eq 0 ] || exit 1
