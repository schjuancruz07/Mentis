#!/usr/bin/env bash
# nv-firma-lib.sh -- firmar y verificar las actualizaciones de Mentis.
#
# POR QUE ESTO ES EL CORAZON DE TODO (2026-08-07):
# Mentis pasa a actualizarse solo en maquinas que no son la del usuario. Eso es, literalmente, un canal
# para ejecutar codigo en la computadora de otra persona. Si alguien pudiera poner un paquete en ese
# canal, tendria la maquina de cinco personas.
#
# LA SEGURIDAD NO ESTA EN LA INTERFAZ. El "modo administrador" de la app es una comodidad para el usuario:
# el switch va a estar en el codigo de las cinco copias y cualquiera puede activarlo. Lo que impide
# de verdad que otro publique es esto: solo quien tiene la CLAVE PRIVADA puede firmar algo que las
# demas Mentis acepten. Sin la clave, se pueden apretar todos los botones que se quiera y el
# resultado va a ser rechazado del otro lado.
#
# POR QUE OPENSSL Y NO GPG NI SSH:
#   - gpg necesita un keyring y un agente configurados; en Windows eso falla de maneras raras y
#     dificiles de diagnosticar en la maquina de otra persona.
#   - ssh-keygen -Y sign existe, pero necesita un archivo de "allowed signers" con su propio formato.
#   - openssl esta en todos lados (3.5.7 en esta maquina), firma con un comando y verifica con otro.
# Se usa Ed25519: claves cortas, firmas cortas, y no hay que elegir tamaño ni algoritmo de hash.
#
# QUE SE FIRMA: el SHA-256 del paquete, no el paquete. Asi la firma es chica y verificarla no
# depende de volver a leer 5 MB.

# --- nv_firma_generar_par <dir> ---------------------------------------------------------------
# Crea el par de claves. Se corre UNA vez, en la máquina del usuario.
nv_firma_generar_par() {
  local dir="${1:?falta el directorio}"
  local priv="$dir/mentis-firma-privada.pem"
  local pub="$dir/mentis-firma-publica.pem"

  if [ -f "$priv" ]; then
    echo "ERROR: ya existe una clave privada en $priv" >&2
    echo "       Si la reemplazas, TODAS las copias de Mentis van a rechazar tus" >&2
    echo "       actualizaciones hasta que les llegue la clave publica nueva." >&2
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || true
  openssl genpkey -algorithm ed25519 -out "$priv" 2>/dev/null || {
    echo "ERROR: no pude generar la clave (¿esta openssl?)" >&2; return 1; }
  # 600: solo el dueño. En Windows/MSYS el permiso es parcial, pero no cuesta nada y en un futuro
  # Mac o Linux si vale.
  chmod 600 "$priv" 2>/dev/null || true
  openssl pkey -in "$priv" -pubout -out "$pub" 2>/dev/null || {
    echo "ERROR: no pude derivar la clave publica" >&2; return 1; }
  printf '%s\n' "$pub"
}

# --- nv_firma_firmar <archivo> <clave-privada> ------------------------------------------------
# Devuelve la firma en base64, en una linea.
nv_firma_firmar() {
  local archivo="${1:?falta el archivo}" priv="${2:?falta la clave privada}"
  [ -f "$archivo" ] || { echo "ERROR: no existe $archivo" >&2; return 1; }
  [ -f "$priv" ] || { echo "ERROR: no existe la clave privada" >&2; return 1; }
  # -rawin porque Ed25519 en openssl firma el mensaje entero, no un digest pre-calculado.
  openssl pkeyutl -sign -inkey "$priv" -rawin -in "$archivo" 2>/dev/null | openssl base64 -A 2>/dev/null
}

# --- nv_firma_verificar <archivo> <firma-base64> <clave-publica> ------------------------------
# 0 si la firma es valida, 1 si no. NO imprime nada: el que llama decide que decir.
#
# Este es el chequeo que decide si se ejecuta codigo ajeno en la maquina de alguien. Ante CUALQUIER
# duda -- archivo que no existe, firma vacia, openssl que falla -- devuelve 1. Un "no se" tiene que
# significar "no", nunca "dale".
nv_firma_verificar() {
  local archivo="$1" firma="$2" pub="$3"
  [ -n "$archivo" ] && [ -f "$archivo" ] || return 1
  [ -n "$firma" ] || return 1
  [ -n "$pub" ] && [ -f "$pub" ] || return 1
  local tmp; tmp="$(mktemp)" || return 1
  printf '%s' "$firma" | openssl base64 -d -A > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # Sin -rawin la verificacion de Ed25519 falla siempre, aunque la firma sea buena.
  if openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$archivo" -sigfile "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# --- nv_firma_huella <clave-publica> ----------------------------------------------------------
# Huella corta para mostrar y comparar a ojo: sirve para que el usuario pueda confirmar por teléfono que
# la clave que tiene un familiar es la suya y no la de otro.
nv_firma_huella() {
  local pub="${1:?falta la clave publica}"
  [ -f "$pub" ] || return 1
  openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null \
    | sed -E 's/.*= *//' | cut -c1-16
}
