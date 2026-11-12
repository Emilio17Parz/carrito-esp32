// CARRITO ESP32 / L298N / Bluetooth Low Energy (BLE)
// ESP32 WROOM-32; Arduino ESP32 Boards core 2.x o 3.x.
// Motores y prueba independiente de servo desacoplado. Sin ignicion, sin GPIO23.
// Pines según el cableado acordado: 16/17/18/19 y 25/26.
// Seguridad: stop al soltar, al desconectar y timeout de 700 ms.

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESP32Servo.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// Puente H L298N
constexpr uint8_t PIN_IN1 = 16;
constexpr uint8_t PIN_IN2 = 17;
constexpr uint8_t PIN_IN3 = 18;
constexpr uint8_t PIN_IN4 = 19;
constexpr uint8_t PIN_ENA = 25;
constexpr uint8_t PIN_ENB = 26;

// Solo prueba en banco: desacoplar de catapulta, palanca y cerillos.
// Conectar solamente la senal del servo a GPIO27; alimentacion externa 5V.
constexpr uint8_t PIN_SERVO_PRUEBA = 27;
Servo servoPrueba;

// Si una oruga / lado gira al revés al pulsar Adelante, cambia su valor a true.
constexpr bool INVERTIR_IZQUIERDA = false;
constexpr bool INVERTIR_DERECHA = false;

constexpr unsigned long TIMEOUT_MOVIMIENTO_MS = 700;
constexpr uint8_t VELOCIDAD_INICIAL = 205;  // de 0 a 255

// Estos UUID también aparecen en Flutter: deben coincidir exactamente.
#define UUID_SERVICIO       "e3c9a5d2-6f70-4c62-97e5-0c1aa84b7720"
#define UUID_CONTROL       "e3c9a5d2-6f70-4c62-97e5-0c1aa84b7721"
#define NOMBRE_BLUETOOTH   "CARRITO-ESP32"

struct Comando {
  char accion; // F, B, L, R, S, V, T (servo en banco)
  uint8_t valor;
};

QueueHandle_t colaComandos = nullptr;  // 1 entrada: siempre se usa el último comando
volatile bool telefonoConectado = false;
volatile bool reiniciarAnuncio = false;
BLEServer *servidorBLE = nullptr;

char direccionActual = 'S';
uint8_t velocidadActual = VELOCIDAD_INICIAL;
unsigned long ultimoComandoMovimiento = 0;

// En Arduino-ESP32 2.x y 3.x analogWrite usa PWM de 8 bits por defecto.
void motor(uint8_t pin1, uint8_t pin2, uint8_t pinEnable,
           int sentido, bool invertir) {
  if (invertir) sentido = -sentido;
  if (sentido == 0) {
    analogWrite(pinEnable, 0);
    digitalWrite(pin1, LOW);
    digitalWrite(pin2, LOW);
    return;
  }
  digitalWrite(pin1, sentido > 0 ? HIGH : LOW);
  digitalWrite(pin2, sentido > 0 ? LOW : HIGH);
  analogWrite(pinEnable, velocidadActual);
}

void detener() {
  analogWrite(PIN_ENA, 0);
  analogWrite(PIN_ENB, 0);
  digitalWrite(PIN_IN1, LOW);
  digitalWrite(PIN_IN2, LOW);
  digitalWrite(PIN_IN3, LOW);
  digitalWrite(PIN_IN4, LOW);
  direccionActual = 'S';
}

void mover(char direccion, bool refrescarTimeout = true) {
  direccionActual = direccion;
  if (refrescarTimeout) ultimoComandoMovimiento = millis();
  switch (direccion) {
    case 'F': // adelante
      motor(PIN_IN1, PIN_IN2, PIN_ENA, +1, INVERTIR_IZQUIERDA);
      motor(PIN_IN3, PIN_IN4, PIN_ENB, +1, INVERTIR_DERECHA);
      break;
    case 'B': // atrás
      motor(PIN_IN1, PIN_IN2, PIN_ENA, -1, INVERTIR_IZQUIERDA);
      motor(PIN_IN3, PIN_IN4, PIN_ENB, -1, INVERTIR_DERECHA);
      break;
    case 'L': // girar sobre su eje a la izquierda
      motor(PIN_IN1, PIN_IN2, PIN_ENA, -1, INVERTIR_IZQUIERDA);
      motor(PIN_IN3, PIN_IN4, PIN_ENB, +1, INVERTIR_DERECHA);
      break;
    case 'R': // girar sobre su eje a la derecha
      motor(PIN_IN1, PIN_IN2, PIN_ENA, +1, INVERTIR_IZQUIERDA);
      motor(PIN_IN3, PIN_IN4, PIN_ENB, -1, INVERTIR_DERECHA);
      break;
    default:
      detener();
      break;
  }
}

bool interpretar(String cadena, Comando &salida) {
  cadena.trim();
  cadena.toUpperCase();
  if (cadena.length() == 1) {
    char c = cadena[0];
    if (c == 'F' || c == 'B' || c == 'L' || c == 'R' || c == 'S') {
      salida = {c, 0};
      return true;
    }
  }
  // V0, V100, V255 (velocidad). Rechaza valores fuera del rango.
  if (cadena.startsWith("V") && cadena.length() >= 2 && cadena.length() <= 4) {
    int numero = 0;
    for (unsigned int i = 1; i < cadena.length(); i++) {
      if (!isDigit(cadena[i])) return false;
      numero = numero * 10 + (cadena[i] - '0');
    }
    if (numero > 255) return false;
    salida = {'V', (uint8_t)numero};
    return true;
  }
  // T0 o T45: prueba limitada de servo en banco.
  // No admite tiempos, secuencias ni actuadores adicionales.
  if (cadena == "T0") {
    salida = {'T', 0};
    return true;
  }
  if (cadena == "T45") {
    salida = {'T', 45};
    return true;
  }
  return false;
}

class ConexionBLE : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    telefonoConectado = true;
    Serial.println("[BLE] Telefono conectado");
  }
  void onDisconnect(BLEServer *server) override {
    telefonoConectado = false;
    reiniciarAnuncio = true;
    Serial.println("[BLE] Desconectado. STOP de seguridad.");
  }
};

class RecepcionBLE : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *caracteristica) override {
    String texto = caracteristica->getValue();
    Comando comando;
    if (interpretar(texto, comando)) {
      // La pila BLE se ejecuta en otra tarea: pasar orden a loop de forma segura.
      xQueueOverwrite(colaComandos, &comando);
    } else {
      Serial.printf("[BLE] Comando ignorado: %s\n", texto.c_str());
    }
  }
};

void procesar(const Comando &comando) {
  if (comando.accion == 'S') {
    detener();
  } else if (comando.accion == 'T') {
    detener(); // Nunca mover motores mientras se prueba el servo
    servoPrueba.write(comando.valor);
    Serial.printf("[SERVO BANCO] Angulo=%u\n", comando.valor);
  } else if (comando.accion == 'V') {
    velocidadActual = comando.valor;
    if (direccionActual != 'S') mover(direccionActual, false); // velocidad NO renueva watchdog
  } else {
    mover(comando.accion);
  }
  Serial.printf("[MOTOR] accion=%c velocidad=%u\n", comando.accion, velocidadActual);
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_IN1, OUTPUT);
  pinMode(PIN_IN2, OUTPUT);
  pinMode(PIN_IN3, OUTPUT);
  pinMode(PIN_IN4, OUTPUT);
  pinMode(PIN_ENA, OUTPUT);
  pinMode(PIN_ENB, OUTPUT);
  detener();
  // No conectar el servo a un mecanismo de lanzamiento ni a fuentes de ignicion.
  servoPrueba.setPeriodHertz(50);
  servoPrueba.attach(PIN_SERVO_PRUEBA, 1000, 2000);
  servoPrueba.write(0);

  colaComandos = xQueueCreate(1, sizeof(Comando));
  if (!colaComandos) {
    Serial.println("ERROR: no se pudo reservar la cola BLE");
    while (true) delay(1000);
  }

  BLEDevice::init(NOMBRE_BLUETOOTH);
  servidorBLE = BLEDevice::createServer();
  servidorBLE->setCallbacks(new ConexionBLE());
  BLEService *servicio = servidorBLE->createService(UUID_SERVICIO);
  BLECharacteristic *control = servicio->createCharacteristic(
    UUID_CONTROL,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  control->setCallbacks(new RecepcionBLE());
  servicio->start();
  BLEAdvertising *anuncio = BLEDevice::getAdvertising();
  anuncio->addServiceUUID(UUID_SERVICIO);
  anuncio->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("Listo: busca CARRITO-ESP32 en la app Flutter.");
}

void loop() {
  // Al perder conexión, PARA de inmediato e ignora paquetes anteriores.
  if (!telefonoConectado) {
    if (direccionActual != 'S') detener();
    xQueueReset(colaComandos);
  } else {
    Comando comando;
    if (xQueueReceive(colaComandos, &comando, 0) == pdTRUE) {
      procesar(comando);
    }
  }

  if (direccionActual != 'S' &&
      (millis() - ultimoComandoMovimiento > TIMEOUT_MOVIMIENTO_MS)) {
    detener();
    Serial.println("[SEGURIDAD] Sin orden reciente: detenido");
  }

  if (reiniciarAnuncio) {
    reiniciarAnuncio = false;
    delay(100);
    servidorBLE->startAdvertising();
  }
  delay(8);
}
