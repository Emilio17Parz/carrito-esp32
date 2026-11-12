# Carrito 4WD ESP32 + Flutter — generador de APK

**Se conserva el código original** del ZIP recibido (`.ino`, `lib/main.dart` y el script `Instalar-y-Ejecutar.ps1`). Se agrega `Generar-APK.ps1` para crear un proyecto Flutter Android completo en `Flutter_Carrito_4WD/App_Flutter` y compilar el APK en `APK/Carrito_4WD_ESP32.apk`.

## Generar APK en Windows (PowerShell)

1. Descomprime este ZIP y abre PowerShell dentro de la carpeta principal descomprimida.
2. Asegura que Flutter y Android SDK están instalados y configurados (`flutter doctor`).
3. Ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Flutter_Carrito_4WD\Generar-APK.ps1"
```

Para generar **e instalar** en el teléfono conectado por USB con depuración USB habilitada:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Flutter_Carrito_4WD\Generar-APK.ps1" -Instalar -DeviceId 2c28dea2
```

**Salida:** `APK/Carrito_4WD_ESP32.apk`. Al ejecutar por primera vez, el script crea automáticamente la estructura Android que faltaba en el ZIP original, instala las dependencias Flutter, agrega permisos BLE y compila en modo release. No modifica el firmware ni la lógica original Dart; el proyecto anterior fuera de esta carpeta permanece intacto.

**Nota:** El APK no está compilado dentro del ZIP. Este entorno no dispone de Flutter ni del SDK Android, por lo que la compilación ocurre en tu PC. Si `flutter doctor` reporta problemas, arréglalos antes de ejecutar el script.

---

# Carrito ESP32 4WD — códigos actualizados

## Archivos
- `ESP32_Carrito_4WD_BLE/Carrito4WD_BLE/Carrito4WD_BLE.ino`: firmware del ESP32 WROOM-32 con BLE, control de dos canales de motores y un servo de prueba en banco.
- `Flutter_Carrito_4WD/lib/main.dart`: pantalla Flutter para el teléfono OPPO.
- `Flutter_Carrito_4WD/Instalar-y-Ejecutar.ps1`: script para reemplazar solo `lib/main.dart` en el proyecto Flutter que ya funciona.

## Protocolo BLE compartido
- Nombre `CARRITO-ESP32`
- Servicio `e3c9a5d2-6f70-4c62-97e5-0c1aa84b7720`
- Característica de escritura `e3c9a5d2-6f70-4c62-97e5-0c1aa84b7721`
- `F`, `B`, `L`, `R`, `S`: mover y detener
- `V0` a `V255`: velocidad PWM
- `T0`, `T45`: posiciones limitadas de servo **solo para prueba desacoplada en banco**

## Conexiones
|ESP32|L298N|
|--|--|
|GPIO16|IN1|
|GPIO17|IN2|
|GPIO18|IN3|
|GPIO19|IN4|
|GPIO25|ENA (retirar jumper ENA para PWM)|
|GPIO26|ENB (retirar jumper ENB para PWM)|
|GND|GND común|

Servo de prueba: **GPIO27 a señal del servo**, 5V externo regulado a positivo, y GND común con ESP32. Nunca alimentar el servo desde GPIO. Mantenerlo **desacoplado de cualquier catapulta o cerillos**. No conectar fuente de ignición.

Los cuatro motores 4WD se agruparían por lado (2 canales). Comprobar las corrientes de arranque y bloqueo: puede ser necesaria una segunda etapa controladora o drivers de mayor corriente; NO asumir que un L298N admite dos motores en paralelo por canal.

## Requisitos
1. Arduino IDE con paquete ESP32 de Espressif compatible. Instalar biblioteca `ESP32Servo` (p. ej., 3.2.1 para Arduino-ESP32 3.x) desde Gestor de bibliotecas. El firmware requiere ESP32Servo.h. Alternativa: mantener el firmware anterior de solo motores si no se dispone de la biblioteca.
2. Abrir `Carrito4WD_BLE.ino` y subirlo a la ESP32.
3. En PowerShell, descomprimir, entrar en carpeta `Flutter_Carrito_4WD` y ejecutar:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Instalar-y-Ejecutar.ps1 -Proyecto 'C:\Users\jecal\Downloads\CarritoESP32_BLE_Completo\CarritoESP32_BLE_Completo\Flutter_Carrito_BLE' -DeviceId 2c28dea2
```

## Importante
El código **no configura ni activa GPIO23** y no contiene funciones ni temporizadores de ignición. Desconecta físicamente cualquier sistema de alta tensión y no acoples el brazo mecánico en pruebas del servo.

Este firmware no implementa Wi-Fi; comunica por BLE. En pruebas anteriores la aplicación instaló bien, pero `failedToConnect` indicaba un problema GATT sin resolver. Estas actualizaciones no garantizan que la conexión se resuelva. Probar nRF Connect y monitor serie a 115200 baudios si persiste.

## Seguridad
- Alimentación USB de ESP32 para la prueba. L298N con alimentación adecuada aparte; masas comunes. Nunca introducir tensión de motores directamente a pines del ESP32.
- Ruedas elevadas. Desconectar físicamente el circuito de plasma y quitar cerillos del mecanismo.
- El firmware detiene motores con desconexión y watchdog de 700 ms; la app detiene al soltar botón.
