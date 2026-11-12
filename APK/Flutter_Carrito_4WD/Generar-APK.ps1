param(
    [string]$DeviceId = '2c28dea2',
    [switch]$Instalar
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$DartSource = Join-Path $PSScriptRoot 'lib\main.dart'
$AppDir = Join-Path $PSScriptRoot 'App_Flutter'
$ApkFolder = Join-Path $Root 'APK'
$ApkFinal = Join-Path $ApkFolder 'Carrito_4WD_ESP32.apk'

function FlutterRun([string[]]$Parameters) {
    Write-Host ("`n> flutter " + ($Parameters -join ' ')) -ForegroundColor Cyan
    & flutter @Parameters
    if ($LASTEXITCODE -ne 0) {
        throw ('Flutter devolvio error al ejecutar: ' + ($Parameters -join ' '))
    }
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'No se encontro Flutter en PATH. Instala Flutter y agrega su carpeta bin al PATH; luego verifica con flutter doctor.'
}
if (-not (Test-Path -LiteralPath $DartSource)) {
    throw "No se encontro: $DartSource"
}

# Genera el andamiaje Android porque el ZIP original solo contiene main.dart.
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'pubspec.yaml'))) {
    FlutterRun -Parameters @('create', '--platforms=android', '--project-name', 'carrito_4wd_ble', $AppDir)
}

# Preserva exactamente el codigo Flutter suministrado en el ZIP original.
$DestDart = Join-Path $AppDir 'lib\main.dart'
Copy-Item -LiteralPath $DartSource -Destination $DestDart -Force

Push-Location $AppDir
try {
    # Mantener BLE 5.x evita saltos no probados en la API del archivo original.
    FlutterRun -Parameters @('pub', 'add', 'flutter_reactive_ble:^5.5.0', 'permission_handler:^12.0.1')

    $Manifest = Join-Path $AppDir 'android\app\src\main\AndroidManifest.xml'
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "No se encontro AndroidManifest.xml: $Manifest"
    }
    $Xml = [System.IO.File]::ReadAllText($Manifest)
    if ($Xml -notmatch 'android\.permission\.BLUETOOTH_SCAN') {
        $Permissions = @'
    <!-- Bluetooth Low Energy / Android 12+ -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <!-- Android 11 y anteriores -->
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
'@
        if (-not $Xml.Contains('<application')) {
            throw 'No se encontro el elemento application en AndroidManifest.xml.'
        }
        $Xml = $Xml.Replace('<application', $Permissions + "`n    <application")
        [System.IO.File]::WriteAllText($Manifest, $Xml, (New-Object System.Text.UTF8Encoding($false)))
    }

    FlutterRun -Parameters @('pub', 'get')
    FlutterRun -Parameters @('build', 'apk', '--release')

    $BuiltApk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path -LiteralPath $BuiltApk)) {
        throw "No se genero el archivo esperado: $BuiltApk"
    }
    New-Item -ItemType Directory -Force -Path $ApkFolder | Out-Null
    Copy-Item -LiteralPath $BuiltApk -Destination $ApkFinal -Force

    Write-Host "`nAPK generado correctamente:" -ForegroundColor Green
    Write-Host $ApkFinal -ForegroundColor Green
    Write-Host ('Tamano: {0:N2} MB' -f ((Get-Item -LiteralPath $ApkFinal).Length / 1MB))

    if ($Instalar) {
        if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
            throw 'APK generado, pero no se encontro adb en PATH para instalarlo. Puedes pasar el APK al telefono e instalarlo manualmente.'
        }
        Write-Host "`n> adb -s $DeviceId install -r $ApkFinal" -ForegroundColor Cyan
        & adb -s $DeviceId install -r $ApkFinal
        if ($LASTEXITCODE -ne 0) {
            throw 'APK generado, pero fallo la instalacion por ADB. Verifica el dispositivo y la depuracion USB.'
        }
        Write-Host 'APK instalado en el dispositivo.' -ForegroundColor Green
    }
} finally {
    Pop-Location
}
