#!/usr/bin/env bash
# test-bucle-aciertos.sh -- que una accion EXITOSA repetida no se coma el turno entero.
#
# POR QUE EXISTE:
#   El 2026-08-12 el modo Study leyo el MISMO archivo 23 veces seguidas y termino sin responder.
#   Se tapo ese agujero... solo para 'read'. El 2026-08-14, probando el gate de completitud, el
#   modelo escribio el MISMO archivo SEIS veces seguidas y volvio a pasar exactamente lo mismo:
#   seis 'write' exitosos, presupuesto agotado, cero respuesta. La guarda existia y no aplicaba.
#
#   La leccion no es "agregar write": es que la guarda tenia que ser por FIRMA DE ACCION desde el
#   principio. Cualquier herramienta que devuelva lo mismo ante los mismos argumentos puede
#   entrar en bucle sin producir un solo error.
#
# POR QUE NO CORRE UN TURNO DE VERDAD (igual criterio que test-cierre-turno.sh): haria falta que
# el modelo se porte mal HOY. Se prueba la MECANICA de la firma, que es determinista, y el
# cableado leyendo el codigo del agente.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }
check() { [ "$2" = "$3" ] && _ok "$1" || _mal "$1" "esperaba $2, obtuvo $3"; }

# --- la firma, copiada EN FORMA de la del agente ------------------------------------------------
# (el cableado real se verifica abajo leyendo el archivo; aca se prueba la REGLA)
firma() { # $1=tool $2=path $3=contenido $4=write_cnt
  local tool="$1" p="$2" c="$3" w="$4"
  case "$tool" in
    write|edit) printf '%s|%s|%s' "$tool" "$p" "$c" ;;
    *)          printf '%s|%s|%s|w%s' "$tool" "$p" "$c" "$w" ;;
  esac | cksum | cut -d' ' -f1
}

echo "== la firma distingue lo que tiene que distinguir =="
[ "$(firma write a.py "print(1)" 0)" = "$(firma write a.py "print(1)" 3)" ] \
  && _ok "write: el mismo archivo con el mismo contenido es la MISMA accion" \
  || _mal "write mismo contenido" "la firma cambio sin que cambiara la accion"
[ "$(firma write a.py "print(1)" 0)" != "$(firma write a.py "print(2)" 0)" ] \
  && _ok "write: mismo archivo con contenido DISTINTO es otra accion (corregir es legitimo)" \
  || _mal "write contenido distinto" "corregir un archivo contaria como bucle"
[ "$(firma exec. "node --test" 1)" != "$(firma exec. "node --test" 2)" ] \
  && _ok "exec: el mismo comando DESPUES de escribir algo es otra accion" \
  || _mal "exec tras escribir" "re-verificar despues de un fix contaria como bucle -- justo lo que queremos que haga"
[ "$(firma exec. "node --test" 2)" = "$(firma exec. "node --test" 2)" ] \
  && _ok "exec: el mismo comando SIN tocar nada en el medio es la misma accion" \
  || _mal "exec sin cambios" "el bucle no se detectaria"
[ "$(firma read a.py "" 0)" != "$(firma read b.py "" 0)" ] \
  && _ok "read: archivos distintos son acciones distintas" \
  || _mal "read distinto archivo" "leer dos archivos contaria como repeticion"

echo ""
echo "== el conteo: por TOTAL, no por racha =="
# Un bucle alternado (A,B,A,B) es igual de mortal que uno seguido, y la version por rachas --
# la que habia hasta hoy -- lo daba por bueno porque nunca habia dos iguales seguidas.
declare -A C=()
sumar() { local k="$1"; C["$k"]=$(( ${C["$k"]:-0} + 1 )); echo "${C["$k"]}"; }
a="$(firma write a.py "x" 0)"; b="$(firma write b.py "y" 0)"
sumar "$a" >/dev/null; sumar "$b" >/dev/null; sumar "$a" >/dev/null
check "alternado A,B,A: la tercera vuelta de A va en 2"  "2" "$(sumar "$b")"
check "y la siguiente de A llega al umbral"              "3" "$(sumar "$a")"

umbral() { [ "$1" -ge 3 ] && echo "avisa" || echo "sigue"; }
check "1 vez: no molesta"        "sigue" "$(umbral 1)"
check "2 veces: todavia no"      "sigue" "$(umbral 2)"
check "3 veces: avisa"           "avisa" "$(umbral 3)"
check "el caso real (6 writes)"  "avisa" "$(umbral 6)"

echo ""
echo "== el cableado en el agente =="
grep -q 'declare -A OK_SIG_COUNT=()' "$A" && _ok "el contador por firma existe" || _mal "OK_SIG_COUNT declarado" "sin el array no cuenta nada"
grep -q 'OK_SIG_MAX=3' "$A" && _ok "el umbral es 3" || _mal "umbral" "sin umbral no avisa"
# Lo que fallo en la version vieja: la guarda entraba solo para una herramienta.
if grep -q 'if \[\[ "\$OBS" != ERROR:\* \]\] && \[ "\$TOOL" != "done" \]; then' "$A"; then
  _ok "la guarda entra para CUALQUIER herramienta exitosa, no solo read"
else
  _mal "guarda generica" "si vuelve a filtrar por una herramienta, el proximo bucle sera de otra"
fi
if awk '/GENERALIZADO EL 2026-08-14/,/^  fi$/' "$A" | grep -q 'write|edit) OK_SIG_RAW='; then
  _ok "write/edit firman por contenido (sin WRITE_CNT)"
else
  _mal "firma de write" "con WRITE_CNT adentro, cada write cambia su propia firma y nunca se detecta"
fi
if awk '/GENERALIZADO EL 2026-08-14/,/^  fi$/' "$A" | grep -q 'w\$WRITE_CNT'; then
  _ok "el resto firma con el estado del mundo (WRITE_CNT)"
else
  _mal "firma con estado" "re-correr un test despues de un fix contaria como bucle"
fi
# LOS DOS ESCALONES (cambiado el 2026-08-15). Hasta hoy esto exigia que la guarda NUNCA cortara:
# la accion estuvo bien y cortar dejaba al usuario sin nada. El caso real que lo cambio: 'task create'
# repetido QUINCE veces, trece avisos ignorados, presupuesto quemado y ningun documento. Trece
# avisos que no cambian nada no son un empujon.
#
# La invariante nueva conserva la razon de la vieja: se sigue avisando primero (no se corta a la
# tercera), y cuando se corta con trabajo real hecho se prende CIERRE_FORZADO, que es justamente el
# mecanismo que existe para no dejar al usuario sin respuesta teniendo los archivos hechos.
BLOQUE_TXT="$(awk '/GENERALIZADO EL 2026-08-14/,/^  fi$/' "$A")"
if printf '%s' "$BLOQUE_TXT" | grep -q 'OK_SIG_CORTE'; then
  _ok "hay un techo (OK_SIG_CORTE) y no solo un aviso infinito"
else
  _mal "hay un techo" "sin techo, trece avisos ignorados siguen quemando el turno"
fi
if printf '%s' "$BLOQUE_TXT" | grep -q 'CIERRE_FORZADO=1'; then
  _ok "al cortar con trabajo hecho, pide igual la respuesta final"
else
  _mal "cortar sin dejar sin nada" "corta sin CIERRE_FORZADO: el usuario se queda sin respuesta con los archivos hechos"
fi
# Y el aviso tiene que seguir viniendo ANTES del corte, no en su lugar.
if printf '%s' "$BLOQUE_TXT" | grep -q 'elif \[ "$OK_SIG_VECES" -ge "$OK_SIG_MAX" \]'; then
  _ok "el aviso sigue primero: se avisa a las 3 y se corta despues"
else
  _mal "el aviso va primero" "si se corta de una, se castiga una accion que estuvo bien"
fi

echo ""
echo "== la guarda REAL, ejecutada (no la regla del test) =="
# Probarlo con un modelo no funciona: se intento dos veces en vivo el 2026-08-14 con la MISMA
# tarea que habia provocado el bucle de seis writes, y las dos veces el modelo cerro bien. Un
# test que dependa de eso da verde sin haber probado nada. Aca se extraen las lineas del agente
# y se ejecutan: si alguien las edita, este test ejecuta la version editada.
BLOQUE="$(mktemp)"
awk '/# GENERALIZADO EL 2026-08-14/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 15 ]; then
  _mal "se puede extraer la guarda" "no se encontro en $A (cambiaron los marcadores?)"
else
  _ok "la guarda se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"

  # Simula N acciones seguidas y devuelve la OBS de la ULTIMA (que es donde deberia aparecer el aviso).
  correr() { # $1=tool $2=path_b64 $3=contenido_b64 $4=veces $5=write_cnt_inicial
    (
      set +e
      declare -A OK_SIG_COUNT=(); OK_SIG_MAX=3
      TOOL="$1"; PATH_B64="$2"; CONTENT_B64="$3"; WRITE_CNT="$5"
      NEW_B64=""; OLD_B64=""; QUERY_B64=""; CODE_B64=""; URL_B64=""; ACTION_B64=""; TARGET_B64=""
      REL="archivo.py"; it=1
      for _v in $(seq 1 "$4"); do
        OBS="OK: archivo escrito (33 bytes): archivo.py"
        source "$BLOQUE"
        it=$((it+1))
      done
      printf '%s' "${OBS:0:20}"
    ) 2>/dev/null
  }

  r="$(correr write cGF0aA== Y29udGVuaWRv 2 0)"
  case "$r" in AVISO*) _mal "dos writes iguales no alcanzan" "aviso demasiado pronto: $r" ;;
               *)      _ok  "dos escrituras iguales todavia no molestan" ;; esac

  r="$(correr write cGF0aA== Y29udGVuaWRv 3 0)"
  case "$r" in AVISO*) _ok  "a la TERCERA escritura identica aparece el aviso" ;;
               *)      _mal "detecta el bucle de write" "obtuvo: $r" ;; esac

  # A las 5 todavia avisa: hay margen para que reaccione solo.
  r="$(correr write cGF0aA== Y29udGVuaWRv 5 0)"
  case "$r" in AVISO*) _ok  "a la quinta todavia avisa (no corta de golpe)" ;;
               *)      _mal "avisa hasta el techo" "obtuvo: $r" ;; esac

  # A las 6 corta. Este es el caso del usuario: 'task create' quince veces con trece avisos ignorados.
  # La observacion pasa a ser ERROR, que es lo que ademas hace que el detector de errores lo vea.
  r="$(correr write cGF0aA== Y29udGVuaWRv 6 0)"
  case "$r" in ERROR*) _ok  "a la sexta corta el turno en vez de avisar de nuevo" ;;
               *)      _mal "el techo corta" "obtuvo: $r" ;; esac

  # El corte tiene que prender LOOP_DETECTADO: sin eso el bucle sigue igual, solo que con otro texto.
  r="$( (
      set +e
      declare -A OK_SIG_COUNT=(); OK_SIG_MAX=3; LOOP_DETECTADO=0; ACCIONES_N=2; CIERRE_FORZADO=0
      TOOL="write"; PATH_B64="cGF0aA=="; CONTENT_B64="Y29udGVuaWRv"; WRITE_CNT=0
      NEW_B64=""; OLD_B64=""; QUERY_B64=""; CODE_B64=""; URL_B64=""; ACTION_B64=""; TARGET_B64=""
      REL="archivo.py"; it=1
      for _v in $(seq 1 6); do OBS="OK: archivo escrito (33 bytes): archivo.py"; source "$BLOQUE"; it=$((it+1)); done
      printf 'loop=%s cierre=%s' "$LOOP_DETECTADO" "$CIERRE_FORZADO"
    ) 2>/dev/null )"
  case "$r" in
    "loop=1 cierre=1") _ok "corta de verdad (LOOP_DETECTADO) y pide la respuesta final (CIERRE_FORZADO)" ;;
    *)                 _mal "el corte esta cableado" "obtuvo: $r" ;;
  esac

  # Sin trabajo real hecho no se fuerza el cierre: no hay nada que contar. Es el caso de los 15
  # 'task create' -- ahi corta como loop y el chat ya tiene su mensaje honesto.
  r="$( (
      set +e
      declare -A OK_SIG_COUNT=(); OK_SIG_MAX=3; LOOP_DETECTADO=0; ACCIONES_N=0; CIERRE_FORZADO=0
      TOOL="task"; PATH_B64=""; CONTENT_B64=""; WRITE_CNT=0
      NEW_B64=""; OLD_B64=""; QUERY_B64=""; CODE_B64=""; URL_B64=""; ACTION_B64="Y3JlYXRl"; TARGET_B64=""
      REL=""; it=1
      for _v in $(seq 1 6); do OBS="OK: tarea 3 creada"; source "$BLOQUE"; it=$((it+1)); done
      printf 'loop=%s cierre=%s' "$LOOP_DETECTADO" "$CIERRE_FORZADO"
    ) 2>/dev/null )"
  case "$r" in
    "loop=1 cierre=0") _ok "15 'task create' sin trabajo real: corta y no finge un cierre" ;;
    *)                 _mal "el caso de la captura del usuario" "obtuvo: $r" ;;
  esac

  r="$(correr read cGF0aA== '' 3 0)"
  case "$r" in AVISO*) _ok  "el caso viejo (read repetido) sigue cubierto" ;;
               *)      _mal "regresion de read" "obtuvo: $r" ;; esac

  r="$(correr search '' '' 3 0)"
  case "$r" in AVISO*) _ok  "y ahora tambien una herramienta que antes no miraba nadie (search)" ;;
               *)      _mal "search repetido" "obtuvo: $r" ;; esac
fi
rm -f "$BLOQUE"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
