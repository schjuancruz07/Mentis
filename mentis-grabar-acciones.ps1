# mentis-grabar-acciones.ps1 -- anota lo que se HACE en la pantalla para poder repetirlo despues.
#
# QUE GRABA: la ventana activa, los clics (con su posicion) y las teclas de control (Enter, Tab,
# Escape, atajos con Ctrl). El texto que se escribe se anota COMO BLOQUE -- "escribio 14
# caracteres" -- y no letra por letra.
#
# POR QUE ASI Y NO TODO. Un programa que guarda cada tecla es un keylogger, y en algun momento iba
# a pasar por una contrasenia. Para armar una skill lo que hace falta es la SECUENCIA (abri esto,
# clic aca, escribi algo, Enter), no el contenido exacto de lo tipeado. Se pierde poder describir
# "escribio tal cosa"; se gana que esto no pueda usarse para robar nada. Es a proposito.
#
# Se enciende y se apaga a mano. Mientras corre lo dice por pantalla.
param(
  [Parameter(Mandatory=$true)][string]$Salida,
  [Parameter(Mandatory=$true)][string]$Centinela
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class MentisWin32 {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out MentisPoint lpPoint);
}
public struct MentisPoint { public int X; public int Y; }
"@

function Get-VentanaActiva {
  $sb = New-Object System.Text.StringBuilder 512
  $h = [MentisWin32]::GetForegroundWindow()
  [void][MentisWin32]::GetWindowText($h, $sb, 512)
  return $sb.ToString()
}

function Escribir-Evento($obj) {
  $linea = $obj | ConvertTo-Json -Compress
  Add-Content -Path $Salida -Value $linea -Encoding utf8
}

$t0 = Get-Date
$ventanaAnterior = ""
$estado = @{}
$textoAcumulado = 0
$ultimaTecla = Get-Date

# Teclas que SI se anotan por nombre: son las que estructuran una tarea.
$especiales = @{
  0x0D = "Enter"; 0x09 = "Tab"; 0x1B = "Escape"; 0x08 = "Backspace";
  0x25 = "Izquierda"; 0x26 = "Arriba"; 0x27 = "Derecha"; 0x28 = "Abajo";
  0x2E = "Suprimir"; 0x24 = "Inicio"; 0x23 = "Fin"
}

Escribir-Evento @{ t = 0; tipo = "inicio"; ventana = (Get-VentanaActiva) }
Write-Host "GRABANDO. Hace la tarea; para frenar borra el archivo centinela o corre: mentis-aprender-mirando.sh frenar"

while (Test-Path $Centinela) {
  $ahora = Get-Date
  $ms = [int]($ahora - $t0).TotalMilliseconds

  # Cambio de ventana: es el evento que mas dice sobre "en que programa estoy".
  $v = Get-VentanaActiva
  if ($v -ne $ventanaAnterior -and $v -ne "") {
    if ($textoAcumulado -gt 0) {
      Escribir-Evento @{ t = $ms; tipo = "escribio"; caracteres = $textoAcumulado; ventana = $ventanaAnterior }
      $textoAcumulado = 0
    }
    Escribir-Evento @{ t = $ms; tipo = "ventana"; ventana = $v }
    $ventanaAnterior = $v
  }

  # Clics: se anota el flanco (de suelto a apretado), no el estado.
  foreach ($b in @(@{k=0x01; n="izquierdo"}, @{k=0x02; n="derecho"})) {
    $apretado = ([MentisWin32]::GetAsyncKeyState($b.k) -band 0x8000) -ne 0
    $clave = "b" + $b.k
    if ($apretado -and -not $estado[$clave]) {
      $p = New-Object MentisPoint
      [void][MentisWin32]::GetCursorPos([ref]$p)
      if ($textoAcumulado -gt 0) {
        Escribir-Evento @{ t = $ms; tipo = "escribio"; caracteres = $textoAcumulado; ventana = $v }
        $textoAcumulado = 0
      }
      Escribir-Evento @{ t = $ms; tipo = "clic"; boton = $b.n; x = $p.X; y = $p.Y; ventana = $v }
    }
    $estado[$clave] = $apretado
  }

  # Teclas de control y atajos con Ctrl. El resto solo suma al contador.
  $ctrl = ([MentisWin32]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
  foreach ($vk in $especiales.Keys) {
    $apretado = ([MentisWin32]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
    $clave = "k" + $vk
    if ($apretado -and -not $estado[$clave]) {
      if ($textoAcumulado -gt 0) {
        Escribir-Evento @{ t = $ms; tipo = "escribio"; caracteres = $textoAcumulado; ventana = $v }
        $textoAcumulado = 0
      }
      Escribir-Evento @{ t = $ms; tipo = "tecla"; tecla = $especiales[$vk]; ventana = $v }
    }
    $estado[$clave] = $apretado
  }
  # Atajos Ctrl+letra: son acciones con nombre (copiar, pegar, guardar), no texto.
  if ($ctrl) {
    foreach ($letra in 65..90) {
      $apretado = ([MentisWin32]::GetAsyncKeyState($letra) -band 0x8000) -ne 0
      $clave = "c" + $letra
      if ($apretado -and -not $estado[$clave]) {
        Escribir-Evento @{ t = $ms; tipo = "atajo"; tecla = ("Ctrl+" + [char]$letra); ventana = $v }
      }
      $estado[$clave] = $apretado
    }
  } else {
    # Letras y numeros sueltos: SOLO se cuentan. Nunca se guarda cual fue.
    foreach ($vk in @(48..57) + @(65..90) + @(32)) {
      $apretado = ([MentisWin32]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
      $clave = "t" + $vk
      if ($apretado -and -not $estado[$clave]) { $textoAcumulado++ }
      $estado[$clave] = $apretado
    }
  }

  Start-Sleep -Milliseconds 40
}

if ($textoAcumulado -gt 0) {
  Escribir-Evento @{ t = [int]((Get-Date) - $t0).TotalMilliseconds; tipo = "escribio"; caracteres = $textoAcumulado; ventana = $ventanaAnterior }
}
Escribir-Evento @{ t = [int]((Get-Date) - $t0).TotalMilliseconds; tipo = "fin" }
Write-Host "Grabacion terminada."
