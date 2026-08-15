#!/usr/bin/env bash
# test-archivos-nombrados.sh -- que Mentis no pueda nombrar archivos que no creó.
#
# EL CASO REAL (2026-08-14, midiendo el reparto de Cowork): un turno cerró con
#   "Se generaron los tres archivos requeridos: mercado.md, competencia.md y plan90.md,
#    cumpliendo con los requisitos especificados de estructura y longitud"
# y en la carpeta había UNO. Las tres guardas del cierre lo dejaron pasar:
#   - la de acción real vio un 'write' exitoso (hubo uno, el de mercado.md);
#   - la de documento sólo mira las palabras documento/informe/word/pdf;
#   - el gate de completitud busca "funciona/probado/verificado", y "se generaron" no lo es.
#
# La diferencia de esta guarda: NO busca frases. Toma los nombres de archivo que la respuesta
# menciona y pregunta si existen. Por eso no se le escapa una redacción nueva -- que es
# exactamente como se escaparon las otras tres.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$HERE/engine/nv-agent.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

echo "== el cableado =="
grep -q 'MENTIS_ARCHIVOS_OFF' "$A" && _ok "se puede apagar con MENTIS_ARCHIVOS_OFF=1" || _mal "apagado" "un cambio de comportamiento sin escape"
grep -q '^ARCH_RECHAZOS=0' "$A" && _ok "el contador de rechazos arranca en cero" || _mal "ARCH_RECHAZOS" "sin inicializar, bajo set -u el turno revienta"
if awk '/¿LOS ARCHIVOS QUE NOMBRA EXISTEN\?/,/^  fi$/' "$A" | grep -q 'ALLOW_WRITE:-0} " *= *"1"\|ALLOW_WRITE:-0}" = "1"'; then
  _ok "solo mira en turnos que pueden escribir"
else
  _mal "requiere permiso de escritura" "en un turno de solo lectura, nombrar un archivo ajeno no es mentir"
fi
if awk '/¿LOS ARCHIVOS QUE NOMBRA EXISTEN\?/,/^  fi$/' "$A" | grep -q 'MENTIS_CREATIONS_DIR'; then
  _ok "busca tambien en la carpeta de creaciones"
else
  _mal "mira las creaciones" "los documentos de 'gen' no viven en la raiz: darian falso positivo"
fi

echo ""
echo "== la deteccion REAL, ejecutada sobre archivos de verdad =="
# Se extrae el bloque del agente y se corre con una carpeta preparada a mano. No es una copia de
# la regla: si alguien edita la guarda, este test ejecuta la version editada.
BLOQUE="$(mktemp)"
awk '/# ¿LOS ARCHIVOS QUE NOMBRA EXISTEN\?/,/^  fi$/' "$A" > "$BLOQUE"
if [ "$(wc -l < "$BLOQUE")" -lt 15 ]; then
  _mal "se puede extraer la guarda" "no se encontro en $A"
else
  _ok "la guarda se extrae de nv-agent.sh ($(wc -l < "$BLOQUE") lineas)"

  correr() { # $1=FINAL  $2=rechazos previos  $3=apagado
    local d; d="$(mktemp -d)"
    printf 'hola\n' > "$d/mercado.md"          # existe UNO solo, como en el caso real
    mkdir -p "$d/sub"; printf 'x\n' > "$d/sub/anidado.txt"
    (
      set +e
      ROOT="$d"; MENTIS_CREATIONS_DIR="$d/creaciones"; mkdir -p "$MENTIS_CREATIONS_DIR"
      printf 'y\n' > "$MENTIS_CREATIONS_DIR/informe.pdf"
      FINAL="$1"; ARCH_RECHAZOS="$2"; MENTIS_ARCHIVOS_OFF="$3"
      ALLOW_WRITE=1; STATUS="done"; HIST=""; it=3; MAXIT=20
      source "$BLOQUE"
      printf 'STATUS=%s|FINAL=%s' "$STATUS" "$(printf '%s' "$FINAL" | head -c 30)"
    ) 2>/dev/null
    rm -rf "$d"
  }

  r="$(correr "Se generaron los tres archivos: mercado.md, competencia.md y plan90.md." 0 0)"
  case "$r" in STATUS=budget*FINAL=) _ok "el caso real: nombra tres, existe uno -> se rechaza el cierre" ;;
               *) _mal "atrapa el caso real" "obtuvo: $r" ;; esac

  r="$(correr "Listo, escribí mercado.md con el análisis." 0 0)"
  case "$r" in STATUS=done*FINAL=Listo*) _ok "si el archivo existe, no se mete" ;;
               *) _mal "no molesta cuando existe" "obtuvo: $r" ;; esac

  r="$(correr "Quedó en sub/anidado.txt." 0 0)"
  case "$r" in STATUS=done*) _ok "encuentra archivos en subcarpetas (no exige que esten en la raiz)" ;;
               *) _mal "busca en subcarpetas" "obtuvo: $r" ;; esac

  r="$(correr "Te generé el informe.pdf." 0 0)"
  case "$r" in STATUS=done*) _ok "encuentra los documentos en la carpeta de creaciones" ;;
               *) _mal "mira las creaciones" "obtuvo: $r" ;; esac

  r="$(correr "Se generaron mercado.md y plan90.md." 1 0)"
  case "$r" in STATUS=done*FINAL=Ojo*) _ok "a la segunda corrige el texto y dice CUALES faltan" ;;
               *) _mal "corrige en vez de rechazar dos veces" "obtuvo: $r" ;; esac

  r="$(correr "Se generaron mercado.md y plan90.md." 0 1)"
  case "$r" in STATUS=done*FINAL=Se\ generaron*) _ok "MENTIS_ARCHIVOS_OFF=1 lo desactiva de verdad" ;;
               *) _mal "el apagado funciona" "obtuvo: $r" ;; esac
fi
rm -f "$BLOQUE"

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
