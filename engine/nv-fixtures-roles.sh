#!/usr/bin/env bash
# nv-fixtures-roles.sh -- las pruebas con respuesta VERIFICABLE de cada rol.
#
# POR QUE EXISTE:
#   Un ping ("¿contestás?") sirve para saber si un modelo está vivo, y para nada más. El catálogo
#   de NVIDIA tiene 102 modelos y muchos contestan perfecto un "ping" siendo inútiles para el rol
#   donde harían falta: modelos de embeddings, de visión, de guardia, o de razonamiento que queman
#   mil tokens pensando antes de decir "hola".
#
#   Así que antes de que un modelo entre a un rol tiene que aprobar el examen DE ESE ROL, con
#   respuestas que se pueden verificar solas. Es el mismo método con el que se eligió a
#   nemotron-3-super sobre mistral-medium para 'deep' (5/5 vs 2/5 sobre problemas con respuesta
#   conocida) -- acá se automatiza para que no dependa de que alguien se siente a medirlo.
#
# FORMATO: cada fixture es una línea "prompt|||tipo|||esperado".
#   tipo=contiene  -> la respuesta tiene que contener 'esperado' (sin distinguir mayúsculas)
#   tipo=numero    -> se extrae el primer número y tiene que caer en el rango 'min-max'
#   tipo=json      -> la respuesta tiene que ser JSON válido con las claves 'esperado' (coma)
#
# Los prompts NO llevan comillas ni saltos de línea: se meten en un JSON armado con printf.

# nv_fixtures_de <rol> -> imprime las líneas de fixture de ese rol
nv_fixtures_de() {
  case "$1" in
    # 'fast' existe para responder RAPIDO y corto; se lo prueba con algo trivial. Lo que se
    # detecta acá NO es inteligencia: es el modelo que se pone a razonar en voz alta antes de
    # decir "listo", que en este rol es exactamente el defecto que lo descalifica.
    fast)
      echo 'Responde unicamente con la palabra listo, nada mas.|||contiene|||listo'
      echo 'Cuanto es 7 mas 5? Responde solo el numero.|||numero|||12-12'
      echo 'Cual es la capital de Francia? Responde solo el nombre de la ciudad.|||contiene|||paris'
      echo 'Cuantos dias tiene una semana? Responde solo el numero.|||numero|||7-7'
      echo 'El agua moja. Responde solo con la palabra verdadero o la palabra falso.|||contiene|||verdadero'
      echo 'Cuanto es 100 menos 37? Responde solo el numero.|||numero|||63-63'
      echo 'De que color es el cielo despejado de dia? Responde con una sola palabra.|||contiene|||azul'
      echo 'Cuantas patas tiene una arania? Responde solo el numero.|||numero|||8-8'
      echo 'Repeti exactamente esta palabra y nada mas: banana|||contiene|||banana'
      echo 'Cual es el mes numero 3 del anio? Responde solo el nombre del mes.|||contiene|||marzo'
      echo 'Cuantos minutos tiene una hora? Responde solo el numero.|||numero|||60-60'
      echo 'Responde unicamente con la palabra rojo, nada mas.|||contiene|||rojo'
      echo 'Cual es el idioma oficial de Brasil? Responde solo el nombre del idioma.|||contiene|||portugues'
      echo 'Cuanto es 9 por 9? Responde solo el numero.|||numero|||81-81'
      echo 'Cuantos lados tiene un triangulo? Responde solo el numero.|||numero|||3-3'
      ;;
    # 'extract' tiene que devolver JSON parseable. Es el rol donde un modelo charlatan
    # (que envuelve el JSON en explicaciones) rompe todo lo que hay aguas abajo.
    extract)
      echo 'Devolve SOLO un objeto JSON con las claves nombre y edad para este texto: el usuario tiene 30 anios. Sin explicacion, sin markdown.|||json|||nombre,edad'
      echo 'Devolve SOLO un objeto JSON con la clave ciudad para este texto: Vivo en Rosario. Sin explicacion.|||json|||ciudad'
      echo 'Devolve SOLO un objeto JSON con las claves producto y precio para este texto: Compre una silla a 4500 pesos. Sin explicacion.|||json|||producto,precio'
      echo 'Devolve SOLO un objeto JSON con las claves dia, mes y anio para este texto: La reunion es el 5 de marzo de 2026. Sin explicacion.|||json|||dia,mes,anio'
      echo 'Devolve SOLO un objeto JSON con las claves remitente y asunto para este texto: De Ana. Asunto: factura vencida. Sin explicacion.|||json|||remitente,asunto'
      echo 'Devolve SOLO un objeto JSON con la clave items, que sea una lista, para este texto: Compre pan, leche y huevos. Sin explicacion.|||json|||items'
      echo 'Devolve SOLO un objeto JSON con la clave telefono para este texto: Llamame al 341 555 1234. Sin explicacion.|||json|||telefono'
      echo 'Devolve SOLO un objeto JSON con la clave email para este texto: Escribime a usuario arroba ejemplo punto com. Sin explicacion.|||json|||email'
      echo 'Devolve SOLO un objeto JSON con las claves origen y destino para este texto: Vuelo de Rosario a Madrid. Sin explicacion.|||json|||origen,destino'
      echo 'Devolve SOLO un objeto JSON con las claves temperatura y unidad para este texto: Hoy hay 28 grados centigrados. Sin explicacion.|||json|||temperatura,unidad'
      echo 'Devolve SOLO un objeto JSON con las claves titulo y autor para este texto: El libro Rayuela fue escrito por Julio Cortazar. Sin explicacion.|||json|||titulo,autor'
      echo 'Devolve SOLO un objeto JSON con las claves cantidad, unidad y alimento para este texto: Comi 200 gramos de arroz. Sin explicacion.|||json|||cantidad,unidad,alimento'
      echo 'Devolve SOLO un objeto JSON con la clave sentimiento para este texto: Estoy furioso con este servicio. Sin explicacion.|||json|||sentimiento'
      echo 'Devolve SOLO un objeto JSON con las claves marca, modelo y anio para este texto: Tengo un Fiat Palio 2015. Sin explicacion.|||json|||marca,modelo,anio'
      echo 'Devolve SOLO un objeto JSON con las claves hora_inicio y hora_fin para este texto: Trabajo de 9 a 18. Sin explicacion.|||json|||hora_inicio,hora_fin'
      ;;
    # 'code' tiene que escribir código, no describirlo. Estos 15 son el chequeo BARATO: miden si
    # emite código en vez de prosa. La calidad real del código se mide aparte con HumanEval, que
    # ejecuta los tests de verdad (tests/bench-humaneval.sh) -- no se puede medir con 'contiene'.
    code)
      echo 'Escribi solo una funcion Python llamada suma que reciba a y b y devuelva la suma. Sin explicacion, sin markdown.|||contiene|||def suma'
      echo 'Escribi solo una linea de Python que imprima el texto hola. Sin explicacion.|||contiene|||print'
      echo 'Escribi solo una funcion Python llamada es_par que devuelva True si el numero es par. Sin explicacion.|||contiene|||def es_par'
      echo 'Escribi solo el comando de bash que lista los archivos del directorio actual. Sin explicacion.|||contiene|||ls'
      echo 'Escribi solo una consulta SQL que seleccione todas las columnas de la tabla clientes. Sin explicacion.|||contiene|||select'
      echo 'Escribi solo una funcion Python llamada invertir que reciba un string s y devuelva el string invertido. Sin explicacion.|||contiene|||def invertir'
      echo 'Como se llama el metodo de Python que convierte un string a mayusculas? Responde solo el nombre del metodo.|||contiene|||upper'
      echo 'Escribi solo el comando de git que muestra el estado del repositorio. Sin explicacion.|||contiene|||git status'
      echo 'Escribi solo una funcion JavaScript llamada doble que reciba n y devuelva n por 2, usando la palabra clave function. Sin explicacion.|||contiene|||function doble'
      echo 'En Python, que excepcion se lanza al dividir por cero? Responde solo el nombre de la excepcion.|||contiene|||zerodivisionerror'
      echo 'Escribi solo una expresion regular que matchee exactamente 10 digitos seguidos. Sin explicacion.|||contiene|||{10}'
      echo 'Escribi solo el comando de bash que cuenta cuantas lineas tiene el archivo datos.txt. Sin explicacion.|||contiene|||wc'
      echo 'Escribi solo una funcion Python recursiva llamada factorial. Sin explicacion.|||contiene|||def factorial'
      echo 'Escribi solo la linea de Python que abre el archivo datos.txt en modo lectura usando with. Sin explicacion.|||contiene|||with open'
      echo 'Escribi solo una funcion Python llamada contar_vocales que reciba un texto y devuelva cuantas vocales tiene. Sin explicacion.|||contiene|||def contar_vocales'
      ;;
    # Razonamiento: problemas con respuesta única y verificable. Mismo espíritu que la medición
    # que decidió el modelo de 'deep' el 2026-07-25. Los tres roles comparten el examen A
    # PROPOSITO: hacen el mismo trabajo con distinto presupuesto de pensamiento, así que correr
    # tres veces el mismo set contra el mismo modelo daría tres veces el mismo número.
    # 'general' se separó (2026-08-02): su trabajo es conocimiento y charla, no deducción.
    reason|deep|ultra)
      echo 'Un tren sale a las 14:00 y viaja 3 horas y media. A que hora llega? Responde solo la hora en formato HH:MM.|||contiene|||17:30'
      echo 'Cuanto es 17 por 23? Responde solo el numero, sin texto.|||numero|||391-391'
      # OJO con pedir "si o no": el modelo contesta "Sí" CON TILDE y una comparación ASCII lo da
      # por reprobado -- un modelo correcto descalificado por ortografía. Se pide verdadero/falso,
      # que en español no lleva tilde. (Aparte, nv_fixture_aprueba normaliza tildes igual.)
      echo 'Si todos los gatos son felinos y todos los felinos son animales, entonces todos los gatos son animales. Responde solo con la palabra verdadero o la palabra falso.|||contiene|||verdadero'
      echo 'Si un lapiz cuesta 2 pesos y un cuaderno cuesta 5 veces mas, cuanto cuestan los dos juntos? Responde solo el numero.|||numero|||12-12'
      echo 'Tengo 5 manzanas, regalo 2 y despues compro el triple de las que me quedaron. Cuantas tengo ahora? Responde solo el numero.|||numero|||12-12'
      echo 'Un reloj marca las 9:45. Cuantos minutos faltan para las 11:00? Responde solo el numero.|||numero|||75-75'
      echo 'Si hoy es martes, que dia de la semana sera dentro de 10 dias? Responde solo el nombre del dia.|||contiene|||viernes'
      echo 'Una camisa cuesta 100 pesos y tiene 20 por ciento de descuento. Cuanto se paga? Responde solo el numero.|||numero|||80-80'
      echo 'Todos los perros ladran. Fido no ladra. Se puede concluir que Fido es un perro? Responde solo con la palabra verdadero o la palabra falso.|||contiene|||falso'
      echo 'Cuantos numeros enteros entre 1 y 100 inclusive son multiplos de 7? Responde solo el numero.|||numero|||14-14'
      echo 'Un tanque se llena en 6 horas con una canilla y en 3 horas con otra. Cuantas horas tarda con las dos abiertas a la vez? Responde solo el numero.|||numero|||2-2'
      echo 'Ana es mas alta que Beto y Beto es mas alto que Carlos. Quien es el mas bajo? Responde solo el nombre.|||contiene|||carlos'
      echo 'Si 3 maquinas hacen 3 piezas en 3 minutos, cuantos minutos tardan 100 maquinas en hacer 100 piezas? Responde solo el numero.|||numero|||3-3'
      echo 'Cuanto es el 15 por ciento de 240? Responde solo el numero.|||numero|||36-36'
      echo 'Una pelota y un bate cuestan 110 pesos en total. El bate cuesta 100 pesos mas que la pelota. Cuanto cuesta la pelota? Responde solo el numero.|||numero|||5-5'
      ;;
    # 'general' es el rol de la charla y el conocimiento del mundo. Se lo prueba con datos que
    # tienen UNA respuesta y que no cambian con el tiempo -- nada de "quien es el presidente".
    general)
      echo 'Cual es la capital de Australia? Responde solo el nombre de la ciudad.|||contiene|||canberra'
      echo 'Cuantos huesos tiene el cuerpo humano adulto? Responde solo el numero.|||numero|||206-206'
      echo 'Quien escribio Cien anios de soledad? Responde solo el apellido.|||contiene|||marquez'
      echo 'En que anio llego el hombre a la Luna por primera vez? Responde solo el anio.|||numero|||1969-1969'
      echo 'Cual es el oceano mas grande del mundo? Responde solo el nombre.|||contiene|||pacifico'
      echo 'Cuantos jugadores de un equipo de futbol estan en cancha a la vez? Responde solo el numero.|||numero|||11-11'
      echo 'Cual es el elemento quimico cuyo simbolo es Fe? Responde solo el nombre del elemento.|||contiene|||hierro'
      echo 'Cuantos continentes hay segun el modelo de siete continentes? Responde solo el numero.|||numero|||7-7'
      echo 'Cual es el rio mas largo de America del Sur? Responde solo el nombre.|||contiene|||amazonas'
      echo 'En que pais esta la ciudad de Kioto? Responde solo el nombre del pais.|||contiene|||japon'
      echo 'Cuantos grados tiene un angulo recto? Responde solo el numero.|||numero|||90-90'
      echo 'Quien pinto la Mona Lisa? Responde solo el nombre y el apellido.|||contiene|||vinci'
      echo 'Cual es la moneda oficial de Japon? Responde solo el nombre.|||contiene|||yen'
      echo 'Cuantos lados tiene un hexagono? Responde solo el numero.|||numero|||6-6'
      echo 'Cual es el planeta mas cercano al Sol? Responde solo el nombre.|||contiene|||mercurio'
      ;;
    # acá no es un detalle de calidad. Se lo prueba contra valores de referencia conocidos, con
    # rango amplio porque una estimacion razonable varia -- lo que se detecta es el disparate.
    #
    # Lo que este examen NO mide: que el modelo se niegue a sugerir dosis de . Eso es una
    # GUARDA, no un puntaje, y una guarda se prueba pidiendo lo prohibido y viendo que no lo haga
    # -- el formato de estos fixtures sólo sabe verificar respuestas correctas, no ausencias.
    # Se prueba aparte, a mano. No confundir un 15/15 acá con "el rol es seguro".
    # 'multimodal' necesita una imagen de verdad para probarse en serio, y eso es otra pasada.
    # Se declara explicitamente que acá sólo se comprueba que esté VIVO y que obedezca formato
    # -- decirlo es mejor que dejar que alguien suponga que hubo un examen de VISION (ERR-098:
    # las observaciones que mienten). El examen de vision real, con imagenes generadas de
    # contenido conocido, esta en tests/bench-multimodal.sh (2026-08-02).
    multimodal)
      echo 'Responde unicamente con la palabra listo, nada mas.|||contiene|||listo'
      echo 'Cuanto es 7 mas 5? Responde solo el numero.|||numero|||12-12'
      echo 'De que color es el cielo despejado de dia? Responde con una sola palabra.|||contiene|||azul'
      echo 'Devolve SOLO un objeto JSON con la clave color para este texto: la pelota es roja. Sin explicacion.|||json|||color'
      echo 'Cual es la capital de Francia? Responde solo el nombre de la ciudad.|||contiene|||paris'
      ;;
    *) : ;;
  esac
}

# nv_fixture_aprueba <respuesta> <tipo> <esperado> -> 0 si aprueba, 1 si no
nv_fixture_aprueba() {
  local resp="$1" tipo="$2" esp="$3"
  case "$tipo" in
    contiene)
      # Se comparan las dos partes SIN tildes. Un modelo que contesta "Sí" no puede reprobar por
      # ortografía: lo que se evalúa es si acertó, no cómo lo escribió.
      #
      # Los reemplazos son UNO POR LETRA y nunca clases tipo [áàäâ]. Es la trampa de ERR-100: sed
      # acá trabaja por BYTES, y una letra acentuada en UTF-8 ocupa dos (á = C3 A1, í = C3 AD).
      # Dentro de una clase, esos bytes se tratan sueltos: "á" terminaba convertida en "aa" y "í"
      # en "ai", con lo cual "Sí" no contenía "si" y un modelo correcto reprobaba. Un reemplazo
      # literal, en cambio, matchea la secuencia completa de dos bytes y funciona.
      local _norm='s/á/a/g; s/à/a/g; s/ä/a/g; s/â/a/g; s/é/e/g; s/è/e/g; s/ë/e/g; s/ê/e/g; s/í/i/g; s/ì/i/g; s/ï/i/g; s/î/i/g; s/ó/o/g; s/ò/o/g; s/ö/o/g; s/ô/o/g; s/ú/u/g; s/ù/u/g; s/ü/u/g; s/û/u/g; s/ñ/n/g'
      local r_n e_n
      r_n="$(printf '%s' "$resp" | tr '[:upper:]' '[:lower:]' | sed "$_norm")"
      e_n="$(printf '%s' "$esp"  | tr '[:upper:]' '[:lower:]' | sed "$_norm")"
      printf '%s' "$r_n" | grep -qF -- "$e_n" && return 0
      return 1 ;;
    numero)
      local minv maxv num
      minv="${esp%%-*}"; maxv="${esp##*-}"
      # EL ULTIMO número de la respuesta, no el primero. Cambiado el 2026-08-02 tras encontrar que
      # esto reprobaba respuestas CORRECTAS: pedimos "responde solo el numero" y varios modelos
      # igual muestran el procedimiento -- "20% de descuento sobre 100 pesos es 20 pesos. 100 - 20
      # = 80. 80". Tomando el primero se leia 20 y se contaba como error, cuando el modelo habia
      # acertado. Medido: deepseek-v4-pro pasaba de 10/14 a 12/14 en 'reason' sólo por esto, y con
      # el criterio viejo el informe habria concluido que el modelo de razonamiento de Mentis es
      # de los peores del catalogo. En una respuesta razonada la conclusion esta al FINAL.
      # (Es el mismo criterio que usa el harness de GSM8K, por la misma razon.)
      num="$(printf '%s' "$resp" | grep -oE '[0-9]+([.,][0-9]+)?' | tail -1 | tr ',' '.' | cut -d. -f1)"
      [ -n "$num" ] || return 1
      [ "$num" -ge "$minv" ] 2>/dev/null && [ "$num" -le "$maxv" ] 2>/dev/null && return 0
      return 1 ;;
    json)
      NVF_RESP="$resp" NVF_ESP="$esp" python3 -c '
import json, os, re, sys
t = os.environ["NVF_RESP"].strip()
# Muchos modelos envuelven el JSON en ```json... ```. Eso no es motivo para reprobar: lo que
# importa es si SABE armar el objeto, no si obedece al pie de la letra lo de "sin markdown".
m = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
if m:
    t = m.group(1).strip()
else:
    a, b = t.find("{"), t.rfind("}")
    if a >= 0 and b > a:
        t = t[a:b+1]
try:
    d = json.loads(t)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
claves = [c.strip().lower() for c in os.environ["NVF_ESP"].split(",") if c.strip()]
tiene = {k.lower() for k in d.keys()}
sys.exit(0 if all(c in tiene for c in claves) else 1)
' 2>/dev/null
      return $? ;;
    *) return 1 ;;
  esac
}

# nv_puntaje_modelo <modelo> <key> <rol> -> imprime "<aprobadas>/<total> <ms_promedio>"
# Devuelve por stdout el puntaje; el llamador decide qué hacer con él.
nv_puntaje_modelo() {
  local modelo="$1" key="$2" rol="$3"
  local total=0 bien=0 suma_ms=0 linea nvf_prompt tipo esp resp t0 t1
  while IFS= read -r linea; do
    [ -n "$linea" ] || continue
    nvf_prompt="${linea%%|||*}"
    local resto="${linea#*|||}"
    tipo="${resto%%|||*}"
    esp="${resto#*|||}"
    total=$((total+1))
    t0="$(date +%s%N 2>/dev/null || echo 0)"
    resp="$(nv_respuesta_modelo "$modelo" "$key" "$nvf_prompt" 512 0)"
    t1="$(date +%s%N 2>/dev/null || echo 0)"
    [ "$t0" != "0" ] && suma_ms=$(( suma_ms + (t1 - t0) / 1000000 ))
    if [ -n "$resp" ] && nv_fixture_aprueba "$resp" "$tipo" "$esp"; then
      bien=$((bien+1))
    fi
  done < <(nv_fixtures_de "$rol")
  [ "$total" -eq 0 ] && { printf '0/0 0'; return 0; }
  printf '%s/%s %s' "$bien" "$total" "$((suma_ms / total))"
}
