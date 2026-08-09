#!/usr/bin/env bash
# test-memory-vault.sh -- Kai Vault (búsqueda semántica obligatoria antes de cada turno) y
# memoria persistente (/recordar via mentis-memory.sh). Confirma que las citas de fuente son
# reales (archivos que existen de verdad), no inventadas.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "memoria / Kai Vault"

_sk_case "Kai Vault: pregunta real sobre el propio ecosistema, cita fuente" \

_sk_case "Kai Vault: modo lookup interno (el que usa mentis-chat.sh antes de CADA turno)" \
  bash "$MENTIS_ENV_DIR/capabilities/boveda.sh" "__lookup__ como funciona el boton de detener"

_sk_case "Kai Vault: salud del indice" \
  bash "$MENTIS_ENV_DIR/capabilities/boveda.sh" "salud"

_sk_case "memoria persistente: guardar una nota real de prueba" \
  bash "$MENTIS_ENV_DIR/mentis-memory.sh" save "skill-tests: nota de prueba $(date +%s)" project

_sk_case "memoria persistente: listar lo guardado" \
  bash "$MENTIS_ENV_DIR/mentis-memory.sh" list
