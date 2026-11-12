param(
  [string]$Proyecto = 'C:\Users\jecal\Downloads\CarritoESP32_BLE_Completo\CarritoESP32_BLE_Completo\Flutter_Carrito_BLE',
  [string]$DeviceId = '2c28dea2'
)
$ErrorActionPreference = 'Stop'
$Origen = Join-Path $PSScriptRoot 'lib\main.dart'
$Destino = Join-Path $Proyecto 'lib\main.dart'
$Pubspec = Join-Path $Proyecto 'pubspec.yaml'
if (!(Test-Path -LiteralPath $Origen)) { throw 'No se encontro main.dart junto al script.' }
if (!(Test-Path -LiteralPath $Destino)) { throw "No se encontro $Destino" }
if (!(Test-Path -LiteralPath $Pubspec)) { throw 'pubspec.yaml no encontrado.' }
$Bak = "$Destino.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item -LiteralPath $Destino -Destination $Bak
Copy-Item -LiteralPath $Origen -Destination $Destino -Force
Write-Host "Interfaz instalada. Respaldo: $Bak" -ForegroundColor Green
Write-Host 'Se reemplazo SOLO lib/main.dart. No se modifica Android/Gradle/vendor/pubspec.' -ForegroundColor Cyan
Push-Location $Proyecto
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Fallo flutter pub get.' }
  & flutter run -d $DeviceId
  if ($LASTEXITCODE -ne 0) { throw 'Fallo flutter run.' }
} finally {
  Pop-Location
}
