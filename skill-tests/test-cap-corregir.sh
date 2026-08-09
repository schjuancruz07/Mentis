#!/usr/bin/env bash
# test-cap-corregir.sh -- /corregir (correccion de ortografia/gramatica, modelo de apoyo NVIDIA).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/corregir (ortografía y gramática)"

_sk_case "texto real con errores reales de ortografia/tildes/puntuacion" \
  bash "$MENTIS_ENV_DIR/capabilities/corregir.sh" "hola komo andas quiero preguntarte algo sobre el proyecto q estamos asiendo, no se si ba a andar bien"
