#!/usr/bin/env bash
# nv-idioma-lib.sh -- en que idioma Mentis escribe, habla y escucha (2026-08-13).
#
# POR QUE EXISTE: el idioma estaba en tres lugares distintos y ninguno se podia cambiar sin editar
# codigo -- la voz clavada en mentis-tts.sh, el idioma de escucha clavado adentro de la llamada a
# transcribe() del servidor de voz, y el de escritura implicito en que toda la persona esta en
# espaniol. el usuario pidio poder elegir "idiomas de habla y de lectura", y para eso los tres tienen
# que salir del mismo lugar.
#
# DOS AJUSTES, NO UNO: 'lectura' es en que idioma te escribe; 'habla' es con que voz suena y en
# que idioma te entiende. Van separados porque no siempre coinciden -- se puede leer en espaniol
# y practicar escuchando ingles.
#
# LA TABLA VIVE EN engine/idiomas.json, no aca: la app tambien la necesita para dibujar el
# selector, y una lista en bash no la puede leer el renderer.
NVIDIOMA_RAIZ="${MENTIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NVIDIOMA_TABLA="$NVIDIOMA_RAIZ/engine/idiomas.json"
NVIDIOMA_SETTINGS="${MENTIS_SETTINGS_FILE:-$NVIDIOMA_RAIZ/mentis-settings.json}"

# _nv_idioma_campo <cual: lectura|habla> <campo: voz|whisper|instruccion|nombre>
# Devuelve vacio si algo no esta -- nunca rompe: quedarse sin idioma tiene que caer en espaniol,
# no dejar a Mentis sin voz.
_nv_idioma_campo() {
  local cual="$1" campo="$2"
  NVI_CUAL="$cual" NVI_CAMPO="$campo" NVI_T="$NVIDIOMA_TABLA" NVI_S="$NVIDIOMA_SETTINGS" python3 -c '
import json, os, sys
try:
    with open(os.environ["NVI_T"], encoding="utf-8") as f:
        t = json.load(f)
except Exception:
    sys.exit(0)
cual = os.environ["NVI_CUAL"]
cod = (t.get("por_defecto") or {}).get(cual, "es")
try:
    with open(os.environ["NVI_S"], encoding="utf-8") as f:
        cod = ((json.load(f).get("idioma") or {}).get(cual)) or cod
except Exception:
    pass
d = (t.get("idiomas") or {}).get(cod) or (t.get("idiomas") or {}).get("es") or {}
print(d.get(os.environ["NVI_CAMPO"], ""), end="")
' 2>/dev/null | tr -d '\r'
}

nv_idioma_voz()         { _nv_idioma_campo habla voz; }
nv_idioma_whisper()     { _nv_idioma_campo habla whisper; }
nv_idioma_instruccion() { _nv_idioma_campo lectura instruccion; }
nv_idioma_nombre()      { _nv_idioma_campo "${1:-lectura}" nombre; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-todo}" in
    voz)         nv_idioma_voz; echo ;;
    whisper)     nv_idioma_whisper; echo ;;
    instruccion) nv_idioma_instruccion; echo ;;
    *) echo "lectura: $(nv_idioma_nombre lectura)"; echo "habla:   $(nv_idioma_nombre habla)"
       echo "voz:     $(nv_idioma_voz)"; echo "whisper: $(nv_idioma_whisper)" ;;
  esac
fi
