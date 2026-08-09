#!/usr/bin/env bash
# test-drive.sh -- subir a Google Drive por la app de escritorio (B3, 2026-08-03).
#
# QUE ES ESTO: el conector de Google Workspace no anda (token vencido, y re-autenticar solo lo
# puede hacer el usuario). Pero Drive de escritorio SI anda y monta las cuentas como unidades de
# Windows, asi que copiar un archivo ahi lo sube. Idea del usuario.
#
# EL RIESGO QUE MAS SE PRUEBA NO ES QUE FALLE, ES QUE ACIERTE MAL. En esta maquina hay TRES
# cuentas de Google montadas a la vez. Un archivo personal del usuario subido a la cuenta del taller
# no es un error que se arregle borrandolo. Por eso la mitad de los chequeos son sobre la negativa
# a adivinar, no sobre la subida.
#
# Los chequeos que suben de verdad estan detras de -v: escriben en el Drive REAL del usuario. Se hace
# en una subcarpeta con nombre de prueba y se borra al terminar, pero no es algo que deba pasar
# cada vez que alguien corre la suite.
set -uo pipefail
TD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD_ROOT="$(cd "$TD_HERE/.." && pwd)"
export PYTHONIOENCODING=utf-8

TD_VIVO=0; [ "${1:-}" = "-v" ] && TD_VIVO=1
TD_OK=0; TD_MAL=0
_ok()  { TD_OK=$((TD_OK+1));  echo "  OK   $1"; }
_mal() { TD_MAL=$((TD_MAL+1)); echo "  MAL  $1  ($2)"; }

DRIVE="$TD_ROOT/mentis-drive.sh"
AGENTE="$TD_ROOT/engine/nv-agent.sh"
[ -f "$DRIVE" ] || { echo "ABORTA: no existe $DRIVE" >&2; exit 1; }

TD_TMP="$(mktemp -d)"
case "$TD_TMP" in "$TD_ROOT"|"$TD_ROOT"/*) echo "ABORTA: temporal dentro de Mentis" >&2; exit 1 ;; esac
trap 'rm -rf "$TD_TMP"' EXIT

echo "== Google Drive por la app de escritorio =="
echo "-- A. lee la realidad, no una lista escrita a mano"

bash -n "$DRIVE" && _ok "A1 mentis-drive.sh compila" || _mal "A1 compila" "error de sintaxis"

# A2: las cuentas salen de Windows. Si estuvieran hardcodeadas, agregar o sacar una cuenta
# dejaria a Mentis subiendo a una unidad que ya no existe.
# Se miran SOLO las lineas de codigo: los comentarios nombran G:/H:/J: a proposito, porque
# documentan lo que se midio en esta maquina. Un test que no distingue codigo de prosa falla
# cuando nada se rompio -- ya paso hoy con test-modelos-override, y un test que grita en falso
# entrena a quien lo lee a ignorarlo.
CODIGO="$(grep -vE '^\s*#' "$DRIVE")"
if printf '%s' "$CODIGO" | grep -q "Win32_LogicalDisk" \
   && ! printf '%s' "$CODIGO" | grep -qE '=\s*"?/[ghj]/|"[GHJ]:'; then
  _ok "A2 las cuentas se leen del sistema, no estan hardcodeadas"
else
  _mal "A2 cuentas del sistema" "hay letras de unidad hardcodeadas en el codigo"
fi

# A3: "Mi unidad" cambia de nombre con el idioma de la cuenta.
if grep -q '"Mi unidad" "My Drive"' "$DRIVE"; then
  _ok "A3 contempla 'Mi unidad' y 'My Drive' (el nombre depende del idioma)"
else
  _mal "A3 nombre de la raiz" "asume un solo nombre; se rompe con una cuenta en ingles"
fi

# A4: arranca Drive con Start-Process, no con "&". Backgroundear procesos de larga vida desde
# Git Bash tiene su propia historia de fallos en esta maquina (ERR-027).
if grep -q "Start-Process -FilePath" "$DRIVE" && grep -q "WorkingDirectory" "$DRIVE"; then
  _ok "A4 levanta Drive con Start-Process y fuera de la carpeta (ERR-027 + ERR-106)"
else
  _mal "A4 arranque de Drive" "usa un patron de background que ya fallo antes en esta maquina"
fi

echo "-- B. no adivina a que cuenta sube (lo mas importante)"

echo "contenido de prueba" > "$TD_TMP/archivo.txt"

# B1: sin cuenta y con varias montadas -> se niega, con codigo propio (3), no con 0 ni con 1.
timeout 200 bash "$DRIVE" subir "$TD_TMP/archivo.txt" >"$TD_TMP/b1.out" 2>&1
RC=$?
N_CUENTAS="$(timeout 200 bash "$DRIVE" cuentas 2>/dev/null | grep -c ':')"
if [ "${N_CUENTAS:-0}" -gt 1 ]; then
  [ "$RC" = "3" ] \
    && _ok "B1 con $N_CUENTAS cuentas y sin indicar cual, NO sube (exit 3)" \
    || _mal "B1 no adivina la cuenta" "exit=$RC (deberia ser 3, y no haber subido nada)"
  grep -q "no me dijiste a cual" "$TD_TMP/b1.out" \
    && _ok "B2 y explica por que, mostrando las cuentas" \
    || _mal "B2 explica y lista" "$(head -c 90 "$TD_TMP/b1.out")"
else
  _ok "B1 (una sola cuenta montada: la ambiguedad no aplica en esta maquina)"
  _ok "B2 (idem)"
fi

# B3: una cuenta que no existe no puede terminar subiendo a otra.
timeout 200 bash "$DRIVE" subir "$TD_TMP/archivo.txt" "cuenta-que-no-existe@x.com" >"$TD_TMP/b3.out" 2>&1
[ $? = "3" ] && grep -q "no tengo montada ninguna cuenta" "$TD_TMP/b3.out" \
  && _ok "B3 una cuenta inexistente da error, no cae en otra cuenta" \
  || _mal "B3 cuenta inexistente" "exit distinto de 3 o mensaje inesperado"

# B4: archivo inexistente.
timeout 200 bash "$DRIVE" subir "$TD_TMP/no-esta.txt" "G" >/dev/null 2>&1
[ $? = "1" ] && _ok "B4 archivo inexistente -> exit 1" || _mal "B4 archivo inexistente" "exit inesperado"

echo "-- C. honestidad sobre lo que hace"

grep -q "no convertido a documento de Google editable" "$DRIVE" \
  && _ok "C1 avisa que NO convierte a documento de Google" \
  || _mal "C1 avisa el limite" "podria dar a entender que quedo convertido"

# C2: verifica que llego, no lo da por hecho. Drive es un sistema de archivos virtual: la
# escritura puede aceptarse y fallar despues.
grep -q "llego incompleto a Drive" "$DRIVE" \
  && _ok "C2 compara el tamaño en destino antes de decir 'subido'" \
  || _mal "C2 verifica la subida" "reportaria exito sobre un archivo de 0 bytes"

echo "-- D. cableado en el agente"

grep -q 'NVA_FICHA_DRIVE=' "$AGENTE" \
  && _ok "D1 la ficha existe y va bajo demanda (no pesa en cada turno)" \
  || _mal "D1 ficha de drive" "no esta"

grep -q '_nva_indexar "drive"' "$AGENTE" \
  && _ok "D2 aparece en el indice de capacidades" \
  || _mal "D2 en el indice" "seria una capacidad invisible (ERR-084)"

# D3: usa ARGS_B64, que es lo que el extractor produce de verdad. La primera version leia
# ARGS_JSON, una variable que no existe -- misma familia de bug que ya rompio dos veces acá.
grep -q 'DCARPETA="\$(_b64d "\${ARGS_B64' "$AGENTE" \
  && _ok "D3 lee ARGS_B64 (el campo que el extractor realmente emite)" \
  || _mal "D3 campo del extractor" "si lee una variable que no existe, la subcarpeta se ignora en silencio"

# D4: solo con permiso de escritura. El modo remoto (celular) lo apaga, que es justo donde no se
# quiere que Mentis suba cosas a la nube sin el usuario adelante.
grep -q 'if \[ "\${ALLOW_WRITE:-0}" != "1" \]; then' "$AGENTE" \
  && _ok "D4 sin permiso de escritura no sube (cubre el modo remoto del celular)" \
  || _mal "D4 gate de escritura" "se podria subir desde la pagina del celular"

# D5: HAD_REAL_ACTION solo si subio DE VERDAD. Marcarlo cuando la subida quedo pendiente por
# falta de cuenta dejaria pasar un "ya lo subi" que seria mentira.
#
# Se busca la INVARIANTE (que el flag este condicionado a DRC igual a 0), no una linea literal:
# la version anterior de este chequeo exigia `[ "$DRC" -eq 0 ] && HAD_REAL_ACTION=1` y empezo a
# fallar cuando esa linea se reescribio como `if`... justamente para arreglar un bug real
# (`set -e` abortaba el turno cuando la condicion daba falsa). Un test que se rompe cuando se
# arregla un bug esta midiendo la forma, no el fondo.
if awk '/^    drive\)/,/^    capacidad\|/' "$AGENTE" \
   | grep -A 3 'DRC" -eq 0' | grep -q 'HAD_REAL_ACTION=1'; then
  _ok "D5 solo cuenta como accion real si la subida salio bien"
else
  _mal "D5 accion real" "HAD_REAL_ACTION no esta condicionado a que la subida haya salido bien"
fi

# D6: y que ese flag NO se ponga con una lista AND al final de la rama. Bug real del 2026-08-03:
# con `set -euo pipefail`, un `[ cond ] && accion` cuya condicion es falsa devuelve 1 y ABORTA el
# script entero sin imprimir nada. El turno terminaba con la respuesta vacia y sin un solo error.
if awk '/^    drive\)/,/^    capacidad\|/' "$AGENTE" | grep -qE '^\s*\[ "\$DRC" -eq 0 \] && HAD_REAL_ACTION=1\s*$'; then
  _mal "D6 sin lista AND al final de la rama" "volvio el patron que aborta el turno bajo set -e"
else
  _ok "D6 usa 'if' y no una lista AND (que bajo set -e aborta el turno en silencio)"
fi

if [ "$TD_VIVO" = "1" ]; then
  echo "-- E. subida de verdad (escribe en el Drive REAL y despues borra)"
  CUENTA="$(timeout 200 bash "$DRIVE" cuentas 2>/dev/null | head -1 | awk '{print $1}' | tr -d ':')"
  if [ -z "$CUENTA" ]; then
    _mal "E1 subida real" "no hay ninguna cuenta montada"
  else
    echo "prueba automatica $(date)" > "$TD_TMP/subida-real.txt"
    SAL="$(timeout 300 bash "$DRIVE" subir "$TD_TMP/subida-real.txt" "$CUENTA" "Mentis-pruebas" 2>&1)"
    if [ $? = "0" ] && printf '%s' "$SAL" | grep -q "Subido a Drive"; then
      _ok "E1 sube de verdad y lo confirma ($(printf '%s' "$SAL" | head -1 | cut -c1-58))"
      L="$(printf '%s' "$CUENTA" | tr '[:upper:]' '[:lower:]')"
      for raiz in "Mi unidad" "My Drive"; do
        if [ -f "/$L/$raiz/Mentis-pruebas/subida-real.txt" ]; then
          _ok "E2 el archivo esta de verdad en la unidad montada"
          rm -f "/$L/$raiz/Mentis-pruebas/subida-real.txt"
          rmdir "/$L/$raiz/Mentis-pruebas" 2>/dev/null || true
          break
        fi
      done
    else
      _mal "E1 subida real" "$(printf '%s' "$SAL" | head -c 100)"
    fi
  fi
else
  echo "-- E. (subida real salteada; corre con -v. Escribe en el Drive del usuario)"
fi

echo
echo "== $TD_OK OK, $TD_MAL MAL =="
[ "$TD_MAL" -eq 0 ]
