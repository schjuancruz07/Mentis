# mentis-computer-control.ps1 -- control REAL de mouse/teclado via User32 (P/Invoke) y
# System.Windows.Forms.SendKeys. Invocado por mentis-computer-control.sh (nunca directo por
# el usuario). Acciones: move | click | type | key | scroll.
param(
  [Parameter(Mandatory = $true)][string]$Action,
  [int]$X = 0,
  [int]$Y = 0,
  [string]$Text = "",
  [string]$Keys = "",
  [string]$ClickType = "left"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace MentisNative -Name Input -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, int dwExtraInfo);
"@

$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010
$MOUSEEVENTF_WHEEL = 0x0800

function Do-Click([string]$type) {
  switch ($type) {
    "right" {
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0)
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0)
    }
    "double" {
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
      Start-Sleep -Milliseconds 80
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    }
    default {
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
      [MentisNative.Input]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    }
  }
}

# SendKeys trata +^%~(){}[] como caracteres de control -- hay que envolver cada uno entre
# llaves para que se tipeen literal (texto libre, no combinaciones de teclas).
function Escape-SendKeys([string]$s) {
  $special = '+^%~(){}[]'
  $out = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ($special.IndexOf($ch) -ge 0) { [void]$out.Append("{$ch}") } else { [void]$out.Append($ch) }
  }
  return $out.ToString()
}

# Combo simplificado "ctrl+shift+esc" / "alt+tab" / "enter" -- el ULTIMO token es la tecla,
# los anteriores son modificadores. Traduce a la sintaxis de SendKeys (^ = ctrl, % = alt,
# + = shift, teclas especiales entre llaves).
function Translate-KeyCombo([string]$combo) {
  $parts = $combo -split '\+'
  $key = $parts[-1].Trim().ToLower()
  $mods = @()
  if ($parts.Length -gt 1) { $mods = $parts[0..($parts.Length - 2)] | ForEach-Object { $_.Trim().ToLower() } }
  $named = @{
    enter = "{ENTER}"; tab = "{TAB}"; esc = "{ESC}"; escape = "{ESC}"; space = "{SPACE}"
    backspace = "{BACKSPACE}"; delete = "{DELETE}"; del = "{DELETE}"; home = "{HOME}"; end = "{END}"
    up = "{UP}"; down = "{DOWN}"; left = "{LEFT}"; right = "{RIGHT}"
    pageup = "{PGUP}"; pagedown = "{PGDN}"
    f1 = "{F1}"; f2 = "{F2}"; f3 = "{F3}"; f4 = "{F4}"; f5 = "{F5}"; f6 = "{F6}"
    f7 = "{F7}"; f8 = "{F8}"; f9 = "{F9}"; f10 = "{F10}"; f11 = "{F11}"; f12 = "{F12}"
  }
  $keySend = if ($named.ContainsKey($key)) { $named[$key] } else { Escape-SendKeys $key }
  $prefix = ""
  foreach ($m in $mods) {
    switch ($m) {
      "ctrl" { $prefix += "^" }
      "control" { $prefix += "^" }
      "alt" { $prefix += "%" }
      "shift" { $prefix += "+" }
      default { } # "win" no tiene equivalente en SendKeys -- se ignora en vez de fallar
    }
  }
  return $prefix + $keySend
}

switch ($Action) {
  "launch" {
    # Bug real (2026-07-18, verificacion supervisada en vivo): sin esto, el modelo intentaba
    # "abrir" una app con la herramienta de lectura de archivos (tratando "Calculadora.exe" como
    # ruta), rechazado siempre -- no existia una forma legitima de abrir un programa. Start-Process
    # resuelve nombres cortos conocidos (calc, notepad, explorer) igual que el dialogo Ejecutar.
    Start-Process -FilePath $Text
  }
  "move" {
    [MentisNative.Input]::SetCursorPos($X, $Y)
  }
  "click" {
    [MentisNative.Input]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 50
    Do-Click $ClickType
  }
  "type" {
    [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys $Text))
  }
  "key" {
    [System.Windows.Forms.SendKeys]::SendWait((Translate-KeyCombo $Keys))
  }
  "scroll" {
    $delta = if ($Text -eq "down") { -120 } else { 120 }
    $bytes = [BitConverter]::GetBytes([int32]$delta)
    $udata = [BitConverter]::ToUInt32($bytes, 0)
    [MentisNative.Input]::mouse_event($MOUSEEVENTF_WHEEL, 0, 0, $udata, 0)
  }
  default {
    Write-Error "accion desconocida: $Action"
    exit 1
  }
}
Write-Output "OK"
