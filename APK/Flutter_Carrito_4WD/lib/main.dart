import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const CarritoApp());

const String kDeviceName = 'CARRITO-ESP32';
final Uuid kServiceUuid = Uuid.parse('e3c9a5d2-6f70-4c62-97e5-0c1aa84b7720');
final Uuid kControlUuid = Uuid.parse('e3c9a5d2-6f70-4c62-97e5-0c1aa84b7721');

const Color kAccent = Color(0xFF66E5C1);
const Color kBackground = Color(0xFF0D1320);
const Color kPanel = Color(0xFF182334);

class CarritoApp extends StatelessWidget {
  const CarritoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Carrito BLE',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBackground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kAccent,
          brightness: Brightness.dark,
        ),
        cardTheme: const CardThemeData(color: kPanel),
      ),
      home: const CarritoHome(),
    );
  }
}

class CarritoHome extends StatefulWidget {
  const CarritoHome({super.key});

  @override
  State<CarritoHome> createState() => _CarritoHomeState();
}

class _CarritoHomeState extends State<CarritoHome>
    with WidgetsBindingObserver {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Map<String, DiscoveredDevice> _devices = {};

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<BleStatus>? _statusSubscription;
  Timer? _scanTimer;
  Timer? _heartbeat;

  Future<void> _writeChain = Future<void>.value();
  QualifiedCharacteristic? _control;
  String? _connectedId;
  String? _connectingId;
  String? _direction;
  BleStatus _bleStatus = BleStatus.unknown;
  bool _scanning = false;
  double _speed = 205;
  int _servoPreviewDegrees = 0;
  String _notice = 'Enciende el ESP32 por USB para comenzar.';

  bool get _connected => _connectedId != null && _control != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bleStatus = _ble.status;
    _statusSubscription = _ble.statusStream.listen((status) {
      if (mounted) setState(() => _bleStatus = status);
      if (status != BleStatus.ready && _direction != null) {
        _stopMotion();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopMotion();
  }

  Future<bool> _requestBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.every((status) => status.isGranted)) return true;
    if (mounted) {
      setState(() {
        _notice = 'Autoriza Dispositivos cercanos en los permisos de Android.';
      });
    }
    return false;
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    final allowed = await _requestBluetoothPermissions();
    if (!allowed || !mounted) return;
    if (_ble.status != BleStatus.ready) {
      setState(() {
        _notice = 'Activa Bluetooth en el teléfono y vuelve a buscar.';
      });
      return;
    }
    await _stopScan();
    setState(() {
      _devices.clear();
      _scanning = true;
      _notice = 'Buscando CARRITO-ESP32…';
    });
    _scanSubscription = _ble.scanForDevices(
      withServices: [kServiceUuid],
      scanMode: ScanMode.lowLatency,
    ).listen(
      (device) {
        if (!mounted) return;
        setState(() => _devices[device.id] = device);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _notice = 'Error al buscar: $error');
        _stopScan();
      },
    );
    _scanTimer = Timer(const Duration(seconds: 10), _stopScan);
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    final subscription = _scanSubscription;
    _scanSubscription = null;
    await subscription?.cancel();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(DiscoveredDevice device) async {
    if (_connectingId != null || _connected) return;
    final allowed = await _requestBluetoothPermissions();
    if (!allowed || !mounted) return;

    await _stopScan();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    if (!mounted) return;
    setState(() {
      _connectingId = device.id;
      _notice = 'Localizando anuncio BLE activo…';
    });

    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    try {
      _connectionSubscription = _ble.connectToAdvertisingDevice(
        id: device.id,
        withServices: [kServiceUuid],
        prescanDuration: const Duration(seconds: 7),
        servicesWithCharacteristicsToDiscover: {
          kServiceUuid: [kControlUuid],
        },
        connectionTimeout: const Duration(seconds: 12),
      ).listen(
        (update) {
          debugPrint('[CARRITO BLE] ${update.connectionState}; ${update.failure}');
          if (!mounted) return;
          switch (update.connectionState) {
            case DeviceConnectionState.connecting:
              setState(() => _notice = 'Conectando mediante GATT…');
              break;
            case DeviceConnectionState.connected:
              setState(() {
                _connectedId = device.id;
                _connectingId = null;
                _control = QualifiedCharacteristic(
                  serviceId: kServiceUuid,
                  characteristicId: kControlUuid,
                  deviceId: device.id,
                );
                _notice = 'Conectado. Mantén presionada una flecha para conducir.';
              });
              _queueWrite('V${_speed.round()}');
              break;
            case DeviceConnectionState.disconnecting:
              _stopMotion();
              break;
            case DeviceConnectionState.disconnected:
              _heartbeat?.cancel();
              _heartbeat = null;
              final failure = update.failure;
              setState(() {
                _connectedId = null;
                _connectingId = null;
                _control = null;
                _direction = null;
                _notice = failure == null
                    ? 'Desconectado. Busca el carrito otra vez.'
                    : 'Error BLE (${failure.code}): ${failure.message}';
              });
              break;
          }
        },
        onError: (Object error) {
          _heartbeat?.cancel();
          _heartbeat = null;
          if (!mounted) return;
          setState(() {
            _connectedId = null;
            _connectingId = null;
            _control = null;
            _direction = null;
            _notice = 'Error GATT: $error';
          });
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connectingId = null;
        _notice = 'No fue posible iniciar GATT: $error';
      });
    }
  }

  Future<void> _queueWrite(String text) {
    final target = _control;
    if (target == null) return Future<void>.value();
    _writeChain = _writeChain.then((_) async {
      if (_control?.deviceId != target.deviceId) return;
      await _ble.writeCharacteristicWithResponse(
        target,
        value: utf8.encode(text),
      );
    }).catchError((Object error) {
      if (mounted) {
        setState(() => _notice = 'Error enviando comando BLE: $error');
      }
    });
    return _writeChain;
  }

  void _startMotion(String direction) {
    if (!_connected) return;
    if (_direction == direction) return;
    _heartbeat?.cancel();
    setState(() => _direction = direction);
    _queueWrite(direction);
    _heartbeat = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_connected && _direction == direction) _queueWrite(direction);
    });
  }

  void _releaseMotion(String direction) {
    if (_direction == direction) _stopMotion();
  }

  void _stopMotion({bool force = false}) {
    final wasMoving = _direction != null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _direction = null;
    if (_connected && (wasMoving || force)) _queueWrite('S');
    if (mounted && wasMoving) setState(() {});
  }

  void _testServo(int degrees) {
    if (!_connected) {
      setState(() => _notice = 'Conecta el ESP32 primero.');
      return;
    }
    if (degrees != 0 && degrees != 45) return;
    _stopMotion(force: true);
    _queueWrite('T$degrees');
    setState(() {
      _servoPreviewDegrees = degrees;
      _notice = 'Solicitud de servo $degrees° enviada (prueba en banco).';
    });
  }

  // Método para disparar el arco de plasma (Pin 23) enviando 'I'
  void _triggerIgnition() {
    if (!_connected) {
      setState(() => _notice = 'Conecta el ESP32 primero.');
      return;
    }
    _stopMotion(force: true);
    _queueWrite('I');
    setState(() {
      _notice = '¡Comando de ignición enviado (Pin 23)!';
    });
  }

  Future<void> _disconnect() async {
    _stopMotion(force: true);
    await _writeChain;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    if (!mounted) return;
    setState(() {
      _connectedId = null;
      _control = null;
      _connectingId = null;
      _notice = 'Desconectado.';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _scanTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBackground,
        title: const Row(children: [
          Icon(Icons.directions_car_filled_rounded, color: kAccent),
          SizedBox(width: 12),
          Text('Carrito · ESP32', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _connectionCard(devices),
                  const SizedBox(height: 18),
                  _speedCard(),
                  const SizedBox(height: 20),
                  _controlCard(),
                  const SizedBox(height: 20),
                  _servoDemoCard(),
                  const SizedBox(height: 16),
                  _ignitionCard(), // Tarjeta actualizada con el botón de encendido/arco
                  const SizedBox(height: 20),
                  Text(
                    'Al soltar una flecha, al desconectarse o si el ESP32 deja '
                    'de recibir órdenes por 700 ms, los motores se detienen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.blueGrey.shade200,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionCard(List<DiscoveredDevice> devices) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bluetooth_rounded,
                    color: _connected ? kAccent : Colors.white70),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _connected
                        ? 'CARRITO CONECTADO'
                        : _connectingId != null
                            ? 'CONECTANDO…'
                            : 'SIN CONEXIÓN',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                Icon(Icons.circle, size: 11,
                    color: _connected ? kAccent : Colors.orangeAccent),
              ],
            ),
            const SizedBox(height: 10),
            Text(_notice, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            Text('Bluetooth: ${_bleStatus.name}',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 16),
            if (_connected)
              OutlinedButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Desconectar'),
              )
            else
              FilledButton.icon(
                onPressed: (_scanning || _connectingId != null) ? null : _startScan,
                icon: _scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching_rounded),
                label: Text(_scanning ? 'Buscando…' : 'Buscar carrito'),
              ),
            if (!_connected && devices.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...devices.map((device) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.memory_rounded, color: kAccent),
                title: Text(device.name.isEmpty ? 'ESP32 BLE' : device.name),
                subtitle: Text('${device.id} · RSSI ${device.rssi} dBm',
                    style: const TextStyle(fontSize: 11)),
                trailing: FilledButton.tonal(
                  onPressed: _connectingId == null ? () => _connect(device) : null,
                  child: const Text('Conectar'),
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _speedCard() {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(
                child: Text('Potencia de motores',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              Text('${(_speed / 255 * 100).round()}%',
                  style: const TextStyle(
                      color: kAccent, fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
            Slider(
              min: 0,
              max: 255,
              divisions: 51,
              value: _speed,
              label: '${(_speed / 255 * 100).round()}%',
              onChanged: (value) => setState(() => _speed = value),
              onChangeEnd: (value) {
                if (_connected) _queueWrite('V${value.round()}');
              },
            ),
            const Text('Desliza para ajustar la velocidad (PWM).',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _servoDemoCard() {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(children: [
              Icon(Icons.settings_input_component, color: kAccent),
              SizedBox(width: 10),
              Expanded(child: Text('SERVOMOTOR · PRUEBA EN BANCO',
                style: TextStyle(fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: 10),
            Text('Posición ilustrativa: $_servoPreviewDegrees°',
              style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _servoPreviewDegrees / 90,
              backgroundColor: Colors.white12,
              color: kAccent,
              minHeight: 8,
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: _connected ? () => _testServo(0) : null,
                icon: const Icon(Icons.keyboard_arrow_down),
                label: const Text('Reposo'),
              )),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(
                onPressed: _connected ? () => _testServo(45) : null,
                icon: const Icon(Icons.keyboard_arrow_up),
                label: const Text('Prueba 45°'),
              )),
            ]),
          ],
        ),
      ),
    );
  }

  // Tarjeta interactiva de encendido / arco de plasma vinculada al pin 23
  Widget _ignitionCard() {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(children: [
              Icon(Icons.local_fire_department_rounded, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Expanded(child: Text('SISTEMA DE IGNICIÓN (PIN 23)',
                style: TextStyle(fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: 10),
            const Text('Activa el arco de plasma durante 1.5 segundos.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _connected ? _triggerIgnition : null,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orangeAccent.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.flash_on_rounded),
              label: const Text('DISPARAR ARCO / IGNICIÓN'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlCard() {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(children: [
          const Text('CONTROLES DE MOVIMIENTO',
              style: TextStyle(
                  fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 12,
                  color: Colors.white70)),
          const SizedBox(height: 18),
          Text(_connected ? 'Mantén presionado para avanzar' : 'Conecta el carrito',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 14),
          DriveKey(
            icon: Icons.keyboard_arrow_up_rounded,
            label: 'Adelante',
            isActive: _direction == 'F',
            enabled: _connected,
            onDown: () => _startMotion('F'),
            onUp: () => _releaseMotion('F'),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            DriveKey(
              icon: Icons.keyboard_arrow_left_rounded,
              label: 'Izquierda',
              isActive: _direction == 'L',
              enabled: _connected,
              onDown: () => _startMotion('L'),
              onUp: () => _releaseMotion('L'),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 86,
              width: 86,
              child: FilledButton(
                onPressed: _connected ? () => _stopMotion(force: true) : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(10),
                  backgroundColor: const Color(0xFFCD394C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.stop_circle_outlined, size: 32),
                    SizedBox(height: 3),
                    Text('STOP', style: TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            DriveKey(
              icon: Icons.keyboard_arrow_right_rounded,
              label: 'Derecha',
              isActive: _direction == 'R',
              enabled: _connected,
              onDown: () => _startMotion('R'),
              onUp: () => _releaseMotion('R'),
            ),
          ]),
          const SizedBox(height: 8),
          DriveKey(
            icon: Icons.keyboard_arrow_down_rounded,
            label: 'Atrás',
            isActive: _direction == 'B',
            enabled: _connected,
            onDown: () => _startMotion('B'),
            onUp: () => _releaseMotion('B'),
          ),
        ]),
      ),
    );
  }
}

class DriveKey extends StatelessWidget {
  const DriveKey({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.enabled,
    required this.onDown,
    required this.onUp,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final bool enabled;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: enabled ? (_) => onDown() : null,
      onPointerUp: enabled ? (_) => onUp() : null,
      onPointerCancel: enabled ? (_) => onUp() : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: isActive ? kAccent : const Color(0xFF2B3A4F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isActive ? kAccent : Colors.white12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 38,
                color: !enabled ? Colors.white24 : isActive ? kBackground : Colors.white),
            Text(label, style: TextStyle(
                fontSize: 11,
                color: !enabled ? Colors.white24 : isActive ? kBackground : Colors.white70,
                fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}