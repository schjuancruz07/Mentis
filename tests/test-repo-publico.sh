#!/usr/bin/env bash
# test-repo-publico.sh -- QUE SE PUBLICA y, sobre todo, que NO.
#
# POR QUE EXISTE (2026-08-20): mentis-repo-publico.sh decide que sale al repositorio publico, y
# publico es para siempre -- lo indexa Google, lo clonan bots, queda en caches que no se borran.
# Era el unico script critico del proyecto sin un solo test. Se noto cuando una verificacion a
# mano encontro que 'empresa/' entera (cobranzas, lista de precios, consultas, los borradores de
# los departamentos) viajaba al repo publico, y el publicador terminaba con "LISTO" y sus siete
# controles en ok.
#
# COMO SE PRUEBA: sobre un arbol de MENTIRA, no sobre el repo de verdad. Dos razones: correrlo
# sobre el repo real tarda ~112 s, y un test no puede depender de que hoy exista tal carpeta.
# Aca se arma un origen chiquito con las dos clases de cosas -- programa y datos -- y se mira
# donde termina cada una.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="$HERE/mentis-repo-publico.sh"

ok=0; fallo=0
_ok()  { ok=$((ok+1));       printf '  ok    %s\n' "$1"; }
_mal() { fallo=$((fallo+1)); printf '  FALLA %s -- %s\n' "$1" "$2"; }

[ -f "$PUB" ] || { echo "no existe $PUB"; exit 1; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
ORIG="$SB/origen"; DEST="$SB/publicado"
mkdir -p "$ORIG"

# --- el origen de mentira ---------------------------------------------------------------------
# EL PROGRAMA (tiene que viajar)
mkdir -p "$ORIG/app/lib" "$ORIG/engine" "$ORIG/capabilities" "$ORIG/tests"
printf 'codigo de la app\n'        > "$ORIG/app/lib/store.js"
printf 'motor\n'                   > "$ORIG/engine/nv-agent.sh"
printf 'una capacidad\n'           > "$ORIG/capabilities/where.sh"
printf 'un test\n'                 > "$ORIG/tests/test-algo.sh"
printf '#!/bin/bash\necho hola\n'  > "$ORIG/mentis-chat.sh"
printf 'un script de python\n'     > "$ORIG/mentis-curator-core.py"
printf '{"modos":{}}\n'            > "$ORIG/modos.json"
printf '1.0.0\n'                   > "$ORIG/VERSION"

# LOS DATOS (no pueden viajar). Con contenido reconocible: si aparece en el destino, se ve.
mkdir -p "$ORIG/empresa/recordatorios" "$ORIG/conversations" "$ORIG/memoria" "$ORIG/engine/logs"
printf 'DATO-SECRETO factura 001 cliente Perez 250000 vencida\n' > "$ORIG/empresa/cobranzas.json"
printf 'DATO-SECRETO borrador de cobranza\n'                     > "$ORIG/empresa/recordatorios/drafts.json"
printf 'DATO-SECRETO una conversacion entera\n'                  > "$ORIG/conversations/historia.jsonl"
printf 'DATO-SECRETO memoria personal\n'                         > "$ORIG/memoria/nota.md"
printf 'DATO-SECRETO log con rutas\n'                            > "$ORIG/engine/logs/motor.log"
printf 'DATO-SECRETO clave nvapi-abc\n'                          > "$ORIG/engine/.nv-secrets"
# Y algo NUEVO que nadie decidio todavia: la clase de cosa que rompio esto cuatro veces.
mkdir -p "$ORIG/carpeta-recien-inventada"
printf 'DATO-SECRETO lo que sea que guarde esto\n' > "$ORIG/carpeta-recien-inventada/datos.json"

cp "$PUB" "$ORIG/mentis-repo-publico.sh"

echo "== corre sobre el arbol de mentira =="
SALIDA="$(cd "$ORIG" && timeout -k 5 120 bash "$ORIG/mentis-repo-publico.sh" -o "$DEST" 2>&1 </dev/null)"
if [ -d "$DEST" ]; then
  _ok "genero la carpeta publica"
else
  _mal "no genero nada" "sin destino, lo de abajo no significa nada"
  printf '%s\n' "$SALIDA" | head -20
  echo "== $ok ok, $fallo fallan =="; exit 1
fi

echo ""
echo "== LO QUE NO PUEDE SALIR =="
# La comprobacion de fondo: que no haya quedado NI UNA linea de las marcadas, sin importar en que
# archivo. Es la unica forma de no depender de acordarse de cada carpeta.
FUGAS="$(grep -rl "DATO-SECRETO" "$DEST" 2>/dev/null | sed "s|$DEST/||" | tr '\n' ' ')"
if [ -z "${FUGAS// }" ]; then
  _ok "ningun dato marcado llego al repo publico"
else
  _mal "SE PUBLICARON DATOS" "aparecieron en: $FUGAS"
fi

for prohibido in empresa conversations memoria carpeta-recien-inventada engine/logs engine/.nv-secrets; do
  if [ -e "$DEST/$prohibido" ]; then
    _mal "viajo '$prohibido'" "publico es para siempre: esto no se puede deshacer despues"
  else
    _ok "'$prohibido' no viajo"
  fi
done

echo ""
echo "== LO QUE SI TIENE QUE SALIR =="
for necesario in app/lib/store.js engine/nv-agent.sh capabilities/where.sh mentis-chat.sh \
                 mentis-curator-core.py modos.json VERSION tests/test-algo.sh; do
  if [ -e "$DEST/$necesario" ]; then
    _ok "'$necesario' viajo"
  else
    _mal "falta '$necesario'" "el repo publico quedaria sin una parte del programa"
  fi
done

echo ""
echo "== lo nuevo se avisa en voz alta =="
# Una carpeta que no esta ni en la lista blanca ni en la negra no se publica -- pero tiene que
# decirlo, o el dia que sea una funcion nueva va a faltar en el repo sin que nadie se entere.
case "$SALIDA" in
  *"carpeta-recien-inventada"*) _ok "aviso de que hay algo nuevo sin decidir" ;;
  *) _mal "no aviso de lo nuevo" "quedaria afuera en silencio: seguro, pero invisible" ;;
esac

echo ""
echo "== la lista blanca es lo que decide, no la negra =="
# La invariante que hace que esto valga la pena: agregar una carpeta de datos NUEVA no requiere
# acordarse de nada. Se prueba con el caso que rompio el diseño viejo cuatro veces.
mkdir -p "$ORIG/otra-carpeta-mas-nueva-todavia"
printf 'DATO-SECRETO otra vez\n' > "$ORIG/otra-carpeta-mas-nueva-todavia/x.json"
rm -rf "$DEST"
SALIDA2="$(cd "$ORIG" && timeout -k 5 120 bash "$ORIG/mentis-repo-publico.sh" -o "$DEST" 2>&1 </dev/null)"
if [ -e "$DEST/otra-carpeta-mas-nueva-todavia" ]; then
  _mal "una carpeta de datos NUEVA se publico sola" "es exactamente el fallo que la lista blanca viene a impedir"
else
  _ok "una carpeta nueva queda afuera sin que nadie la haya listado"
fi

echo ""
echo "== $ok ok, $fallo fallan =="
[ "$fallo" -eq 0 ]
