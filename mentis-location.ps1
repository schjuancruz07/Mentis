# mentis-location.ps1 -- coordenadas reales via la API nativa de Windows (Windows.Devices.Geolocation).
# Lo llama mentis-location.sh. Vive en su propio archivo a proposito: embebido en el bash con
# -Command, el backtick de 'IAsyncOperation`1' lo consumia el parser de PowerShell (dentro de
# comillas dobles el backtick es un escape), $asTaskGeneric quedaba $null y fallaba con
# "No se puede llamar a un metodo en una expresion con valor NULL". Con -File no hay dos capas
# de quoting peleandose.
#
# Salida (una linea, para que el bash la parsee facil):
#   OK|<lat>|<lon>|<precision_metros>|<fuente>
#   ERROR:<motivo>

Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Las operaciones asincronicas de WinRT no se pueden esperar directo desde PowerShell 5.1:
# hay que sacar el AsTask generico por reflection y aplicarlo al tipo de resultado concreto.
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and
  $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

if ($null -eq $asTaskGeneric) {
  Write-Output 'ERROR:no se pudo resolver AsTask de WinRT en este PowerShell'
  exit 0
}

function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  # 20 s: la primera medicion tras arrancar la maquina puede tardar mientras el servicio de
  # ubicacion escanea las redes WiFi de alrededor.
  $netTask.Wait(20000) | Out-Null
  $netTask.Result
}

try {
  [void][Windows.Devices.Geolocation.Geolocator, Windows.Devices, ContentType = WindowsRuntime]
  [void][Windows.Devices.Geolocation.Geoposition, Windows.Devices, ContentType = WindowsRuntime]

  $acceso = Await ([Windows.Devices.Geolocation.Geolocator]::RequestAccessAsync()) ([Windows.Devices.Geolocation.GeolocationAccessStatus])
  if ($acceso -ne 'Allowed') {
    Write-Output ("ERROR:Windows nego el permiso de ubicacion (estado: $acceso). Activalo en Configuracion > Privacidad y seguridad > Ubicacion.")
    exit 0
  }

  $geo = New-Object Windows.Devices.Geolocation.Geolocator
  $geo.DesiredAccuracyInMeters = 20
  $pos = Await ($geo.GetGeopositionAsync()) ([Windows.Devices.Geolocation.Geoposition])
  if ($null -eq $pos) {
    Write-Output 'ERROR:la medicion de ubicacion no devolvio resultado (timeout)'
    exit 0
  }

  $c = $pos.Coordinate
  Write-Output ('OK|' + $c.Point.Position.Latitude + '|' + $c.Point.Position.Longitude + '|' + $c.Accuracy + '|' + $c.PositionSource)
} catch {
  Write-Output ('ERROR:' + $_.Exception.Message)
}
