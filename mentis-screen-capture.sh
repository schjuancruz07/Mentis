#!/usr/bin/env bash
# mentis-screen-capture.sh -o <archivo.jpg> -- saca una captura de pantalla real (todos los
# monitores) y la guarda en la ruta pedida. Sin dependencias externas (System.Drawing de.NET).
set -uo pipefail

OUT=""
while getopts ":o:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    *) echo "ERROR: opcion invalida"; exit 1 ;;
  esac
done
if [ -z "$OUT" ]; then
  echo "ERROR: falta -o <ruta_de_salida.jpg>"
  exit 1
fi

WIN_OUT="$(cygpath -w "$OUT" 2>/dev/null)" || { echo "ERROR: ruta de salida invalida"; exit 1; }
mkdir -p "$(dirname "$OUT")"

if MRO_OUT="$WIN_OUT" powershell.exe -NoProfile -NonInteractive -Command '
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$screens = [System.Windows.Forms.Screen]::AllScreens
$top    = [int](($screens | ForEach-Object {$_.Bounds.Top}    | Measure-Object -Minimum).Minimum)
$left   = [int](($screens | ForEach-Object {$_.Bounds.Left}   | Measure-Object -Minimum).Minimum)
$right  = [int](($screens | ForEach-Object {$_.Bounds.Right}  | Measure-Object -Maximum).Maximum)
$bottom = [int](($screens | ForEach-Object {$_.Bounds.Bottom} | Measure-Object -Maximum).Maximum)
$width = [int]($right - $left)
$height = [int]($bottom - $top)
$bmp = New-Object System.Drawing.Bitmap $width, $height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
$bmp.Save($env:MRO_OUT, [System.Drawing.Imaging.ImageFormat]::Jpeg)
$g.Dispose(); $bmp.Dispose()
' >/dev/null 2>&1 && [ -s "$OUT" ]; then
  printf '%s\n' "$OUT"
  exit 0
else
  echo "ERROR: no se pudo capturar la pantalla"
  exit 1
fi
