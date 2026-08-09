#!/usr/bin/env bash
# mentis-curator.sh -- auditoria de la memoria de Mentis (calco del curator de Claude Code).
#
# Uso:  mentis-curator.sh [report]              # auditoria (default, solo lee)
#       mentis-curator.sh archive <archivo.md>  # archiva (recuperable, nunca borra)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$DIR/mentis-curator-core.py" "$@"
