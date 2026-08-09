#!/usr/bin/env bash
# test-web.sh -- hablarle a Mentis desde el celular, sin estar sentado en la computadora.
#
# Lo que hay que proteger acá NO es que la página se vea linda: es que un mensaje que entra por la
# red de casa tenga las manos atadas. La página vive en la WiFi de una casa con más gente, y
# mentis-chat.sh le pasaba "-w" al agente SIEMPRE (permiso de escribir archivos y ejecutar
# comandos), sin forma de apagarlo. El modo remoto (-R) es lo que se prueba primero y con más
# detalle, porque es lo único que no se puede arreglar después de que pase algo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FALLO=0
_ok()  { echo "ok: $1"; PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1"; FALLO=$((FALLO+1)); }

# ============ PARTE 1: el modo remoto ata las manos ==========================================
# Se arma un sandbox con la estructura real (raíz/ + raíz/engine/) y un nv-agent.sh de mentira que
# lo único que hace es escribir las banderas que recibió. Así se ve EXACTAMENTE con qué permisos
# lo llamaría el chat, sin gastar una llamada a ningún modelo.
SB="$(mktemp -d)"

# Mata cualquier cosa que esté escuchando el puerto de prueba, sea de esta corrida o de una
# anterior. NO es paranoia: Windows deja que VARIOS procesos escuchen el mismo puerto, así que un
# servidor zombi de una corrida vieja no impide que arranque el nuevo -- pero es él quien contesta.
# Pasó exactamente eso (2026-07-30): cinco servidores viejos apilados en el 8791, el test hablaba
# con uno con el código de hace dos horas, y reportaba 10 fallos de un código que estaba bien.
# Se mata por PUERTO (dato del sistema operativo) y no por el pid que devuelve bash: el servidor
# es un python NATIVO de Windows y "$!" es el pid de MSYS, que taskkill no reconoce.
_matar_puerto() {
  local p
  for p in $(netstat -ano 2>/dev/null | grep -E ":$1[[:space:]].*LISTENING" | awk '{print $5}' | sort -u); do
    taskkill //PID "$p" //F >/dev/null 2>&1 || true
  done
}
trap 'rm -rf "$SB" "${SB2:-}"; _matar_puerto "${PUERTO:-8791}"; _matar_puerto 8792' EXIT
mkdir -p "$SB/engine"
cp "$DIR/mentis-chat.sh" "$SB/"
cp "$DIR/engine/nv-lib.sh" "$DIR/engine/nv-classify-lib.sh" "$SB/engine/"

cat > "$SB/engine/nv-agent.sh" <<'STUB'
#!/usr/bin/env bash
# nv-agent de mentira: anota las banderas con las que lo llamaron y contesta cualquier cosa.
printf '%s\n' "$*" >> "$MC_TEST_FLAGS"
echo "listo"
STUB
chmod +x "$SB/engine/nv-agent.sh"

_flags_de() {   # _flags_de <banderas del chat...> -> imprime las banderas que recibió el agente
  local marca="$SB/flags-$RANDOM.txt"
  : > "$marca"
  MC_TEST_FLAGS="$marca" STATEFILE="$SB/state.json" WORKSPACE_DEFAULT="$SB/work" \
  CAPABILITIES_DIR="$SB/nocap" MENTIS_DISPARADORES="$SB/nodisp.json" \
    printf 'una pregunta cualquiera\nsalir\n' 2>/dev/null | true
  MC_TEST_FLAGS="$marca" STATEFILE="$SB/state.json" WORKSPACE_DEFAULT="$SB/work" \
  CAPABILITIES_DIR="$SB/nocap" MENTIS_DISPARADORES="$SB/nodisp.json" \
    bash "$SB/mentis-chat.sh" -H "$SB/hist.jsonl" "$@" <<< "una pregunta cualquiera
salir" >/dev/null 2>&1
  cat "$marca" 2>/dev/null
}

echo "== 1. GUARDIA: el sandbox ejecuta de verdad =="
FLAGS_NORMAL="$(_flags_de)"
if [ -n "${FLAGS_NORMAL// }" ]; then
  _ok "el chat llamó al agente (banderas: ${FLAGS_NORMAL:0:60}...)"
else
  _bad "el chat NO llamó al agente -- todo lo de abajo no significa nada"
  echo; echo "RESULTADO: $PASS ok, $FALLO fallos."; exit 1
fi

echo "== 2. modo NORMAL: sigue teniendo permiso de escribir (regresión) =="
case "$FLAGS_NORMAL" in
  *-w*) _ok "en modo normal el agente recibe -w, como siempre" ;;
  *)    _bad "el modo normal perdió el permiso de escritura: se rompió el uso de todos los días" ;;
esac

echo "== 3. modo REMOTO: sin escritura, sin cámara, sin pantalla, sin control =="
FLAGS_REMOTO="$(_flags_de -R)"
if [ -z "${FLAGS_REMOTO// }" ]; then
  _bad "con -R el chat no llegó a llamar al agente"
else
  _ok "con -R el chat sigue funcionando (banderas: ${FLAGS_REMOTO:0:60}...)"
  case " $FLAGS_REMOTO " in
    *" -w "*) _bad "EL MODO REMOTO DA PERMISO DE ESCRIBIR Y EJECUTAR (-w)" ;;
    *)        _ok "sin -w: no escribe archivos ni ejecuta comandos" ;;
  esac
  case " $FLAGS_REMOTO " in
    *" -V "*) _bad "el modo remoto le pasa la cámara (-V)" ;;
    *)        _ok "sin -V: no puede prender la cámara" ;;
  esac
  for bandera in -s -c -e -g -x -a; do
    case " $FLAGS_REMOTO " in
      *" $bandera "*) _bad "el modo remoto todavía pasa $bandera" ;;
      *)              _ok "sin $bandera" ;;
    esac
  done
  # Y el prompt tiene que DECIR la verdad. Un prompt que le promete permisos que no tiene lo manda
  # a intentar y chocar: iteraciones quemadas por un mensaje que no describe la realidad (ERR-098).
  case "$FLAGS_REMOTO" in
    *"Tenés permiso para leer, escribir y ejecutar"*)
      _bad "en modo remoto el prompt le sigue prometiendo permiso de escribir y ejecutar" ;;
    *"NO tenés herramientas para escribir archivos"*)
      _ok "el prompt le avisa que en este turno no puede escribir ni ejecutar" ;;
    *) _bad "el prompt del modo remoto no aclara qué NO puede hacer" ;;
  esac
fi

echo "== 4. el orden de las banderas no puede aflojar el candado =="
# "-R -g" no puede volver a encender lo que -R apagó: si el permiso dependiera del orden en que
# se escriben los argumentos, no sería un permiso.
FLAGS_MEZCLA="$(_flags_de -R -g -c -s)"
case " $FLAGS_MEZCLA " in
  *" -g "*|*" -c "*|*" -s "*) _bad "'-R -g -c -s' reactivó permisos: el candado depende del orden" ;;
  *) _ok "'-R -g -c -s' sigue acotado (banderas: ${FLAGS_MEZCLA:0:60}...)" ;;
esac

# ============ PARTE 2: el servidor ============================================================
echo "== 5. el servidor exige token en TODO menos en /salud =="
PY_EXE="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
PUERTO=8791
TOKEN_PRUEBA="token-de-prueba-1234"
if [ -z "$PY_EXE" ]; then
  _bad "no encontré el intérprete de python: no se pudo probar el servidor"
else
  _matar_puerto "$PUERTO"   # que no quede nadie de una corrida anterior contestando por nosotros
  # La raíz es la de VERDAD (no el sandbox): la página sirve archivos reales de la app -- el
  # cuerpo digital y su Three.js -- y con una raíz de mentira esos pedidos darían 404 y el test
  # estaría probando una página que no existe en ningún lado.
  MENTIS_WEB_TOKEN="$TOKEN_PRUEBA" "$PY_EXE" "$(cygpath -w "$DIR/engine/nv_web_server.py")" \
    --raiz "$(cygpath -w "$DIR")" --puerto "$PUERTO" --estado "$(cygpath -w "$SB/estado.json")" \
    > "$SB/servidor.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    curl -s -m 2 "http://127.0.0.1:$PUERTO/salud" >/dev/null 2>&1 && break
  done

  _codigo() { curl -s -o /dev/null -m 10 -w "%{http_code}" "$@"; }
  if [ "$(_codigo "http://127.0.0.1:$PUERTO/salud")" = "200" ]; then
    _ok "/salud contesta sin token (es lo único que puede)"
  else
    _bad "el servidor no arrancó: $(tail -3 "$SB/servidor.log" 2>/dev/null)"
  fi
  chk() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (esperaba $2, dio $1)"; fi; }
  chk "$(_codigo "http://127.0.0.1:$PUERTO/")" "401" "la página sin token rebota"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/?t=cualquiera")" "401" "un token equivocado rebota"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/?t=$TOKEN_PRUEBA")" "200" "con el token correcto entra"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/api/historial")" "401" "el historial sin token rebota"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/api/historial?t=$TOKEN_PRUEBA")" "200" "el historial con token responde"
  chk "$(_codigo -X POST -H 'Content-Type: application/json' -d '{"texto":"hola"}' \
        "http://127.0.0.1:$PUERTO/api/mensaje")" "401" "mandar un mensaje sin token rebota"
  # Un prefijo del token no puede pasar: es la prueba de que no se compara "empieza con".
  chk "$(_codigo "http://127.0.0.1:$PUERTO/?t=${TOKEN_PRUEBA:0:10}")" "401" "un token cortado no entra"

  echo "== 6. un mensaje vacío se rechaza sin molestar a ningún modelo =="
  chk "$(_codigo -X POST -H 'Content-Type: application/json' -d '{"texto":"   "}' \
        "http://127.0.0.1:$PUERTO/api/mensaje?t=$TOKEN_PRUEBA")" "400" "el mensaje vacío da 400"

  echo "== 7. la página que llega al celular es la de Mentis =="
  PAG="$(curl -s -m 10 "http://127.0.0.1:$PUERTO/?t=$TOKEN_PRUEBA")"
  case "$PAG" in
    *"<title>Mentis</title>"*) _ok "la página tiene el título correcto" ;;
    *) _bad "la página no es la esperada" ;;
  esac
  case "$PAG" in
    *"viewport"*) _ok "declara viewport (se ve bien en el celular)" ;;
    *) _bad "sin viewport: en el celular se vería diminuta" ;;
  esac
  case "$PAG" in
    *"$TOKEN_PRUEBA"*) _bad "la página trae el token escrito adentro del HTML" ;;
    *) _ok "el token no viaja escrito en el cuerpo de la página" ;;
  esac

  echo "== 7b. la página usa la MISMA paleta que la app, no una parecida =="
  # el usuario pidió que se vea igual, y "parecido" se va separando solo con el tiempo. Los valores se
  # leen del :root de app/renderer/style.css y se exige que estén en la página servida: si alguien
  # cambia la paleta de la app, este test avisa que el celular quedó atrás.
  for VAR in fondo secundario texto acento border bubble-usuario; do
    VALOR="$(grep -oE "^\s*--$VAR:\s*[^;]+;" "$DIR/app/renderer/style.css" | head -1 \
             | sed -E "s/^\s*--$VAR:\s*//; s/;\s*$//")"
    if [ -z "$VALOR" ]; then
      _bad "no encontré --$VAR en el style.css de la app"
    elif printf '%s' "$PAG" | grep -qF -- "$VALOR"; then
      _ok "--$VAR ($VALOR) es el mismo en la app y en el celular"
    else
      _bad "--$VAR vale '$VALOR' en la app y no aparece en la página del celular"
    fi
  done
  # El cuerpo digital es la cara de Mentis: tiene que ser el MISMO módulo, no un dibujo aparte.
  case "$PAG" in
    *"/estatico/renderer/cuerpo-digital.js"*) _ok "la página monta el cuerpo digital de la app" ;;
    *) _bad "la página no carga el cuerpo digital" ;;
  esac
  # Y los estáticos que necesita ese módulo tienen que servirse SIN token (un import relativo no
  # lo lleva) pero sólo los de la lista: nada de subir por el árbol de directorios.
  chk "$(_codigo "http://127.0.0.1:$PUERTO/estatico/renderer/cuerpo-digital.js")" "200" "el cuerpo digital se sirve sin token"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/estatico/node_modules/three/build/three.module.min.js")" "200" "Three.js se sirve sin token"
  # three.module.min.js importa a three.core.min.js: si sólo se sirviera el primero, el import
  # anidado daba 401 y el cuerpo no aparecía nunca (pasó, 2026-07-30).
  chk "$(_codigo "http://127.0.0.1:$PUERTO/estatico/node_modules/three/build/three.core.min.js")" "200" "el import anidado de Three.js también se sirve"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/estatico/node_modules/three/build/../../../../engine/.nv-secrets")" "401" "no se puede salir de la carpeta permitida"
  chk "$(_codigo "http://127.0.0.1:$PUERTO/estatico/renderer/renderer.js")" "401" "un archivo fuera de la lista no se sirve"
fi

# ============ PARTE 3: el turno en vivo =======================================================
# Se prueba con un mentis-chat.sh DE MENTIRA, no con el real: así los pasos, los tiempos y el
# final son los mismos en cada corrida y no se gasta una sola llamada a ningún modelo. Lo que se
# prueba es MI código -- que los pasos lleguen mientras el turno corre, que el turno cierre, y que
# Detener corte de verdad -- no la inteligencia de Mentis.
echo "== 9. turno en vivo: los pasos llegan mientras trabaja, y el turno cierra =="
PUERTO2=8792
_matar_puerto "$PUERTO2"
SB2="$(mktemp -d)"
cat > "$SB2/mentis-chat.sh" <<'CHATSTUB'
#!/usr/bin/env bash
# Chat de mentira: escupe pasos como el motor real, contesta en el historial y se va.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat > /dev/null   # se traga el mensaje que le mandan por stdin
echo "[nv-agent] iter 1: read notas/pendientes.txt" >&2
sleep 1
echo "[nv-agent] iter 2: search proyecto" >&2
sleep 1
echo "[nv-agent] iter 3: done" >&2
printf '{"role": "usuario", "text": "una pregunta", "ts": "2026-07-30T00:00:00"}\n' >> "$HERE/history.jsonl"
printf '{"role": "mentis", "text": "respuesta de prueba", "ts": "2026-07-30T00:00:01"}\n' >> "$HERE/history.jsonl"
# LA TRAMPA QUE ROMPIÓ ESTO DE VERDAD (2026-07-30): el chat real deja procesos de fondo (el
# demonio del navegador, el puente MCP) que HEREDAN stderr y lo mantienen abierto para siempre.
# Si el servidor esperara el fin de la tubería para dar el turno por cerrado, se colgaría con la
# respuesta ya escrita.
# Tiene que ser un proceso NATIVO de Windows: probado, un "( sleep 120 ) &" de MSYS no retiene la
# tubería y el test pasaba igual con el código roto -- o sea que no probaba nada.
powershell.exe -NoProfile -Command "Start-Sleep -Seconds 90" &
exit 0
CHATSTUB
chmod +x "$SB2/mentis-chat.sh"
: > "$SB2/history.jsonl"

MENTIS_WEB_TOKEN="$TOKEN_PRUEBA" "$PY_EXE" "$(cygpath -w "$DIR/engine/nv_web_server.py")" \
  --raiz "$(cygpath -w "$SB2")" --puerto "$PUERTO2" --estado "$(cygpath -w "$SB2/estado.json")" \
  > "$SB2/servidor.log" 2>&1 &
for _ in 1 2 3 4 5 6 7 8; do sleep 1; curl -s -m 2 "http://127.0.0.1:$PUERTO2/salud" >/dev/null 2>&1 && break; done

BASE2="http://127.0.0.1:$PUERTO2"
ID="$(curl -s -m 15 -X POST "$BASE2/api/mensaje?t=$TOKEN_PRUEBA" -H 'Content-Type: application/json' \
      -d '{"texto":"una pregunta"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
if [ -n "$ID" ]; then _ok "el turno arranca y devuelve un id ($ID)"; else _bad "no arrancó el turno"; fi

# Se sigue como lo hace la página: pidiendo SOLO lo nuevo. (Con desde=0 fijo el servidor contesta
# al instante siempre, porque siempre hay "novedad" -- así me mentí a mí mismo una vez.)
PASOS_VISTOS=""; DESDE=0; CERRADO=0; RESPUESTA=""
for _ in $(seq 1 12); do
  D="$(curl -s -m 25 "$BASE2/api/turno?t=$TOKEN_PRUEBA&id=$ID&desde=$DESDE")"
  [ -n "$D" ] || break
  NUEVO="$(printf '%s' "$D" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("|".join(d.get("pasos") or []))
print(d.get("total",0))
print("1" if d.get("terminado") else "0")
print(d.get("respuesta") or "")')"
  PASOS_VISTOS="$PASOS_VISTOS$(printf '%s' "$NUEVO" | sed -n 1p)|"
  DESDE="$(printf '%s' "$NUEVO" | sed -n 2p)"
  [ "$(printf '%s' "$NUEVO" | sed -n 3p)" = "1" ] && { CERRADO=1; RESPUESTA="$(printf '%s' "$NUEVO" | sed -n 4p)"; break; }
done

if [ "$CERRADO" = "1" ]; then
  _ok "el turno CERRÓ (si esto falla, la página se queda en 'pensando' para siempre)"
else
  _bad "el turno nunca cerró: el servidor espera algo que no llega"
fi
[ "$RESPUESTA" = "respuesta de prueba" ] && _ok "devolvió la respuesta que quedó en el historial" \
  || _bad "la respuesta no es la esperada: '$RESPUESTA'"
case "$PASOS_VISTOS" in
  *"read notas/pendientes.txt"*) _ok "llegó el primer paso" ;;
  *) _bad "no llegó el paso 'read': la página no mostraría nada mientras trabaja" ;;
esac
case "$PASOS_VISTOS" in
  *"search proyecto"*) _ok "llegó el segundo paso" ;;
  *) _bad "no llegó el paso 'search'" ;;
esac
case "$PASOS_VISTOS" in
  *done*) _ok "llegó el paso final" ;;
  *) _bad "no llegó el paso 'done'" ;;
esac
[ "$DESDE" -ge 3 ] && _ok "se contaron los 3 pasos" || _bad "se contaron $DESDE pasos de 3"

echo "== 10. Detener corta el turno de verdad =="
ID2="$(curl -s -m 15 -X POST "$BASE2/api/mensaje?t=$TOKEN_PRUEBA" -H 'Content-Type: application/json' \
       -d '{"texto":"otra"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
sleep 1
curl -s -m 15 -X POST "$BASE2/api/detener?t=$TOKEN_PRUEBA" -H 'Content-Type: application/json' \
     -d "{\"id\":$ID2}" >/dev/null
CORTADO=0
for _ in $(seq 1 10); do
  D="$(curl -s -m 25 "$BASE2/api/turno?t=$TOKEN_PRUEBA&id=$ID2&desde=99")"
  printf '%s' "$D" | grep -q '"terminado": true' && { CORTADO=1; break; }
done
if [ "$CORTADO" = "1" ]; then _ok "el turno cortado queda cerrado (no se queda colgado)"; else _bad "el turno cortado nunca cerró"; fi
printf '%s' "$D" | grep -q '"error": "cortado"' && _ok "y se reporta como cortado, no como error raro" \
  || _bad "el turno cortado no dice 'cortado': $(printf '%s' "$D" | head -c 120)"

# Después de cortar, el candado tiene que estar libre: si no, el mensaje siguiente rebota.
ID3="$(curl -s -m 15 -X POST "$BASE2/api/mensaje?t=$TOKEN_PRUEBA" -H 'Content-Type: application/json' \
       -d '{"texto":"tercera"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
[ -n "$ID3" ] && _ok "se puede mandar otro mensaje después de cortar" \
  || _bad "el candado quedó tomado: el mensaje siguiente rebota"

# Pide un turno reintentando mientras Mentis siga ocupado con el anterior. Sin esto el test depende
# de que el turno previo haya soltado el candado justo a tiempo -- y cuando no, se queda con un id
# vacio y termina "probando" un turno que no existe (me paso: reportaba "frenar dejo el turno
# abierto" cuando lo que fallaba era el pedido).
_nuevo_turno() {
  local texto="$1" intento id
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    id="$(curl -s -m 15 -X POST "$BASE2/api/mensaje?t=$TOKEN_PRUEBA" -H 'Content-Type: application/json'           -d "{\"texto\":\"$texto\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 2
  done
  return 1
}

echo "== 11. Frenar todo ya (lo que la app tiene y el celular no tenia) =="
ID4="$(_nuevo_turno "algo largo")"
[ -n "$ID4" ] || _bad "no se pudo arrancar un turno para probar el frenado"
sleep 1
FRENO="$(curl -s -m 20 -X POST "$BASE2/api/frenar?t=$TOKEN_PRUEBA")"
case "$FRENO" in
  *'"ok": true'*) _ok "frenar responde bien ($FRENO)" ;;
  *) _bad "frenar no respondio como se espera: $FRENO" ;;
esac
# OJO con el ritmo de esta espera: 'cortado' cuenta como novedad, asi que el servidor contesta al
# instante y sin el sleep las diez vueltas se consumen en un segundo -- antes de que el turno
# termine de cerrar. Ya me paso con desde=0; es la misma trampa con otra cara.
CERRO=0
for _ in $(seq 1 20); do
  D="$(curl -s -m 25 "$BASE2/api/turno?t=$TOKEN_PRUEBA&id=$ID4&desde=99")"
  printf '%s' "$D" | grep -q '"terminado": true' && { CERRO=1; break; }
  sleep 1
done
[ "$CERRO" = "1" ] && _ok "el turno queda cerrado despues de frenar" || _bad "frenar dejo el turno abierto"
chk "$(_codigo -X POST "$BASE2/api/frenar")" "401" "frenar sin token rebota"

echo "== 12. limpieza de conversaciones remotas =="
mkdir -p "$SB2/conversations"
: > "$SB2/conversations/remoto-vacia-vieja.jsonl"
printf '{"role":"usuario","text":"algo"}
' > "$SB2/conversations/remoto-con-texto.jsonl"
printf '{"role":"usuario","text":"vieja"}
' > "$SB2/conversations/remoto-vieja.jsonl"
printf '{"role":"usuario","text":"de la app"}
' > "$SB2/conversations/conversacion-de-la-app.jsonl"
# Se envejecen a mano: 20 dias la vieja, 3 dias la vacia (mas que el dia de gracia).
python3 - "$(cygpath -w "$SB2/conversations")" <<'PYEOF'
import os, sys, time
d = sys.argv[1]
os.utime(os.path.join(d, "remoto-vieja.jsonl"), (time.time()-20*86400,)*2)
os.utime(os.path.join(d, "remoto-vacia-vieja.jsonl"), (time.time()-3*86400,)*2)
os.utime(os.path.join(d, "conversacion-de-la-app.jsonl"), (time.time()-40*86400,)*2)
PYEOF
python3 - "$(cygpath -w "$DIR/engine/nv_web_server.py")" "$(cygpath -w "$SB2")" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("srv", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.RAIZ = sys.argv[2]
print("borradas:", m._limpiar_conversaciones_remotas())
PYEOF
[ -f "$SB2/conversations/remoto-con-texto.jsonl" ] && _ok "la conversacion remota con contenido se conserva" || _bad "borro una conversacion con contenido"
[ -f "$SB2/conversations/conversacion-de-la-app.jsonl" ] && _ok "NO toca las conversaciones de la app (aunque sean viejisimas)" || _bad "BORRO UNA CONVERSACION DE LA APP"
[ -f "$SB2/conversations/remoto-vieja.jsonl" ] && _bad "no borro la remota vieja" || _ok "borro la remota vieja"
[ -f "$SB2/conversations/remoto-vacia-vieja.jsonl" ] && _bad "no borro la remota vacia" || _ok "borro la remota vacia"

_matar_puerto "$PUERTO2"; rm -rf "$SB2"

echo "== 8. mentis-web.sh: las tres órdenes =="
bash -n "$DIR/mentis-web.sh" && _ok "mentis-web.sh parsea sin errores" || _bad "sintaxis de mentis-web.sh"
SAL="$(bash "$DIR/mentis-web.sh" 2>&1)"; RC=$?
[ "$RC" = "2" ] && _ok "sin orden muestra el uso y sale con 2" || _bad "sin orden debería salir con 2 (dio $RC)"
SAL="$(bash "$DIR/mentis-web.sh" token 2>&1)"
case "$SAL" in
  [0-9a-f][0-9a-f][0-9a-f]*) _ok "el token existe y es hexadecimal largo (${#SAL} caracteres)" ;;
  *) _bad "el token no tiene la pinta esperada: $SAL" ;;
esac
[ "${#SAL}" -ge 32 ] && _ok "el token es lo bastante largo como para no adivinarse" || _bad "token corto: ${#SAL} caracteres"

# --- La pagina tiene que PARSEAR y el panel tiene que poder cerrarse (regresion 2026-08-06) ---
# Los dos bugs que dejaron la pagina del celular inutil durante semanas, y que ningun chequeo veia
# porque el servidor respondia 200 y el HTML estaba bien formado.
echo "-- la pagina del celular se puede usar de verdad"

TW_JS="$(mktemp -u).js"
if python3 "$HERE/comprobar_js_de_la_pagina.py" "$(cygpath -w "$TW_JS" 2>/dev/null || printf '%s' "$TW_JS")" > "$TW_JS.info" 2>&1; then
  if command -v node >/dev/null 2>&1; then
    if node --check "$TW_JS" 2>"$TW_JS.err"; then
      _ok "el JavaScript de la pagina parsea ($(cat "$TW_JS.info"))"
    else
      _bad "el JavaScript de la pagina NO parsea -> el script entero muere y no se inicializa nada: $(head -2 "$TW_JS.err" | tr '\n' ' ')"
    fi
  else
    echo "  (salteado: no hay node para validar el JS)"
  fi
else
  _bad "no pude extraer el JS de la pagina: $(head -2 "$TW_JS.info" | tr '\n' ' ')"
fi
rm -f "$TW_JS" "$TW_JS.info" "$TW_JS.err" 2>/dev/null

# El panel se abre y se cierra con el atributo `hidden`, pero el CSS le declara un `display`, y una
# regla de autor le gana al display:none que el navegador da a [hidden]. Sin esta regla explicita,
# el panel queda fijo tapando la pantalla entera y no hay forma de cerrarlo -- ni con el boton.
if grep -q '#panel\[hidden\]' "$DIR/engine/nv_web_server.py"; then
  _ok "el panel se puede cerrar (#panel[hidden] pisa el display del CSS)"
else
  _bad "falta '#panel[hidden] { display:none }': el panel va a tapar el chat y no se va a poder cerrar"
fi

# El bloque HTML/JS es un raw string: si no, Python se come los escapes destinados a JavaScript.
if grep -q '^PAGINA = r"""' "$DIR/engine/nv_web_server.py"; then
  _ok "el bloque de la pagina es raw string (Python no toca los escapes del JS)"
else
  _bad "PAGINA no es raw string: los \\n del JavaScript se convierten en saltos reales y rompen el script"
fi

# La pagina vive con la app: si esto se desconecta, el celular deja de tener servidor y parece un
# problema de red.
if grep -q 'encenderPaginaDelCelular()' "$DIR/app/main.js"; then
  _ok "la app enciende la pagina del celular al arrancar"
else
  _bad "la app ya no enciende la pagina del celular: el servidor solo existiria a mano"
fi

echo
echo "RESULTADO: $PASS ok, $FALLO fallos."
[ "$FALLO" -eq 0 ] || exit 1
