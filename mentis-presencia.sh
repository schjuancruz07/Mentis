#!/usr/bin/env bash
# mentis-presencia.sh -- ¿está el usuario frente a la computadora? SIN usar la cámara.
#
# POR QUE SIN CAMARA:
#   Saber si hay alguien es útil para decidir cuándo hablar en voz alta y cuándo esperar. Pero
#   resolverlo mirando por la cámara significaría tener la cámara prendida todo el tiempo, que es
#   exactamente lo contrario de lo que se decidió (ERR-103: la cámara arranca apagada y se prende
#   a pedido). Una función que para funcionar necesita encender la cámara no es una función de
#   presencia: es vigilancia.
#
#   Windows ya sabe hace cuánto que nadie toca el teclado ni el mouse (GetLastInputInfo). Eso no
#   mira, no escucha y no graba nada: es un número de segundos. Alcanza para lo que hace falta.
#
# LIMITE HONESTO: esto detecta ACTIVIDAD, no personas. Si el usuario está leyendo sin tocar nada, a los
# pocos minutos va a figurar como ausente. Por eso el umbral es generoso y el estado intermedio
# existe -- no hay que tratar "no tocó el teclado en 3 minutos" como "no está".
#
# Uso:
#   mentis-presencia.sh            -> presente | quieto | ausente  (y los segundos)
#   mentis-presencia.sh segundos   -> solo el numero de segundos desde la ultima actividad
#   mentis-presencia.sh puede-hablar -> exit 0 si conviene hablar en voz alta, 1 si no
set -uo pipefail

MP_QUIETO="${MENTIS_PRESENCIA_QUIETO:-120}"    # hasta acá se considera que está y activo
MP_AUSENTE="${MENTIS_PRESENCIA_AUSENTE:-600}"  # más que esto, se lo da por ausente

# PowerShell en UNA sola linea y sin barras de continuacion (ERR-101: partido en varias lineas
# desde bash, no parsea).
_mp_segundos() {
  local s
  s="$(powershell.exe -NoProfile -NonInteractive -Command "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public struct LI{public uint cbSize;public uint dwTime;}public class Idle{[DllImport(\"user32.dll\")]public static extern bool GetLastInputInfo(ref LI l);[DllImport(\"kernel32.dll\")]public static extern uint GetTickCount();public static uint Seg(){LI l=new LI();l.cbSize=(uint)Marshal.SizeOf(l);GetLastInputInfo(ref l);return (GetTickCount()-l.dwTime)/1000;}}' -Language CSharp; [Idle]::Seg()" 2>/dev/null | tr -d '\r\n ')"
  # Si PowerShell falla o devuelve cualquier cosa, se informa -1 en vez de inventar un numero:
  # una presencia falsa haria que Mentis hable cuando no hay nadie, o se calle cuando si.
  case "$s" in
    ''|*[!0-9]*) echo "-1" ;;
    *) echo "$s" ;;
  esac
}

MP_SEG="$(_mp_segundos)"

case "${1:-estado}" in
  segundos) echo "$MP_SEG" ;;

  puede-hablar)
    # Ante la duda (-1, no se pudo medir), se habla: quedarse callado por un fallo de medicion es
    # peor que hablar de mas -- el usuario pidio la voz, no el silencio.
    [ "$MP_SEG" = "-1" ] && exit 0
    [ "$MP_SEG" -le "$MP_AUSENTE" ] && exit 0
    exit 1 ;;

  estado|*)
    if [ "$MP_SEG" = "-1" ]; then
      echo "no se pudo medir la presencia (asumo que estas)"
      exit 0
    fi
    if   [ "$MP_SEG" -le "$MP_QUIETO" ];  then echo "presente (ultima actividad hace ${MP_SEG}s)"
    elif [ "$MP_SEG" -le "$MP_AUSENTE" ]; then echo "quieto (hace ${MP_SEG}s que no tocas nada, pero podes estar leyendo)"
    else                                       echo "ausente (hace ${MP_SEG}s sin actividad)"
    fi ;;
esac
