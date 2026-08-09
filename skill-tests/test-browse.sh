#!/usr/bin/env bash
# test-browse.sh -- tool 'browse' de nv-agent.sh (busqueda web real + apertura de pagina real).
# Limite conocido y documentado en el roadmap: los buscadores pueden challengear con CAPTCHA a
# un navegador automatizado -- no siempre confiable, se documenta el resultado tal cual sale.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSDIR="$(cd "$HERE/../engine" && pwd)"
source "$HERE/_lib.sh"

ROOT="$HERE/scratch-workspace"
mkdir -p "$ROOT"

_sk_section "browse (busqueda y apertura web real)"

_sk_case "search: buscar algo real y devolver resultados" \
  bash "$TOOLSDIR/nv-agent.sh" -b -d "$ROOT" -m general -i 6 \
  "Buscá en la web 'sitio oficial de Node.js' y decime qué resultado apareció primero (título y link)."

_sk_case "open: abrir una URL real y leer contenido" \
  bash "$TOOLSDIR/nv-agent.sh" -b -d "$ROOT" -m general -i 6 \
  "Abrí la página https://nodejs.org y decime de qué se trata el sitio en una oración."
