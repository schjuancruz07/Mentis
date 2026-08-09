#!/usr/bin/env bash
# test-cap-where.sh -- /where (graphify where, ubica donde vive algo en el ecosistema GLOBAL de
# ~/.claude/tools/ -- memorias, skills, bitácora, y el dossier de herramientas top-level). OJO
# (hallazgo real, 2026-07-17): graphify indexa "tool" solo desde una tabla curada a mano en
# DOSSIER-meta-claude.md, NO escanea Mentis/*.sh -- buscar un script interno de Mentis
# código de Mentis, la herramienta correcta es Kai Vault (/boveda), no /where -- ver
# test-memory-vault.sh / test-cap-boveda.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MENTIS_ENV_DIR="$HERE/.."
source "$HERE/_lib.sh"

_sk_section "/where (ubicar algo real del ecosistema global, NO del código interno de Mentis)"

_sk_case "buscar algo que sabemos que existe en el dossier global (curator)" \
  bash "$MENTIS_ENV_DIR/capabilities/where.sh" "curator"

_sk_case "buscar algo que NO existe (caso negativo real)" \
  bash "$MENTIS_ENV_DIR/capabilities/where.sh" "cosa-inventada-que-no-existe-xyz123"
