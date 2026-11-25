import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
// SensorData now lives with the rebuilt fault engine (models/ no longer owns it).
import 'fault_diagnosis_service.dart' show SensorData;

/// Connection states for the BLE service
enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  reconnecting,
  simulating,
}

/// BLE Service for communicating with the SolarDiag ESP32 tool.
/// Falls back to simulation mode when no real device is available.
///
/// FIRMWARE CONTRACT (verified against hardware 2026-07-24)
///   Device name  SolarDiag
///   Service      6e400001-… (Nordic UART)
///   TX (notify)  6e400003-…   device -> app, one JSON packet per second
///   RX (write)   6e400002-…   app -> device, accepts the text "CAL"
///   Packet       {"v_panel":21.8,"v_batt":12.71,"current":2.18,
///                 "power":47.5,"t_panel":41.5,"t_amb":33.0,"ts":142}
///
/// A disconnected temperature probe arrives as JSON `null` — never 0, never
/// -99. That distinction is load-bearing: see correction 5 in
/// [FaultDiagnosisService].
class BleService extends ChangeNotifier {
  // Nordic UART Service UUIDs (must match ESP32 firmware)
  static const String _serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _txCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _rxCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  /// Advertised name of the tool.
  static const String kDeviceName = 'SolarDiag';

  /// The firmware notifies once per second. Beyond this with no packet, the
  /// displayed numbers are history, not telemetry.
  static const Duration kStaleAfter = Duration(seconds: 3);

  /// Packet is ~95 bytes; the default 23-byte ATT MTU truncates it and every
  /// frame fails to parse. 247 is the common ceiling and leaves headroom.
  static const int kPreferredMtu = 247;

  // State
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  BluetoothDevice? _connectedDevice;
  SensorData? _latestData;
  String? _errorMessage;
  List<ScanResult> _scanResults = [];

  // Streams & subscriptions
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _dataSubscription;
  Timer? _simulationTimer;
  Timer? _stalenessTimer;
  Timer? _reconnectTimer;

  BluetoothCharacteristic? _rxChar;

  // Buffer for incoming BLE data (may arrive in chunks)
  String _dataBuffer = '';

  // Staleness / reconnect bookkeeping
  DateTime? _lastPacketAt;
  int? _lastUptimeSeconds;
  bool _uptimeStalled = false;
  bool _intentionalDisconnect = false;
  int _reconnectAttempts = 0;
  bool _permissionsPermanentlyDenied = false;

  final _readings = StreamController<SensorData>.broadcast();

  /// Every successfully parsed packet. Feed the fault engine from this.
  Stream<SensorData> get readings => _readings.stream;

  // Getters
  BleConnectionState get connectionState => _connectionState;
  SensorData? get latestData => _latestData;
  String? get errorMessage => _errorMessage;
  List<ScanResult> get scanResults => _scanResults;
  bool get isConnected =>
      _connectionState == BleConnectionState.connected ||
      _connectionState == BleConnectionState.simulating;
  bool get isReconnecting =>
      _connectionState == BleConnectionState.reconnecting;
  String get deviceName => _connectedDevice?.platformName ?? kDeviceName;

  /// True when the RX characteristic was found, i.e. [recalibrate] will work.
  bool get supportsRecalibration => _rxChar != null;

  /// How long since the last packet, or null if none has arrived.
  Duration? get dataAge => _lastPacketAt == null
      ? null
      : DateTime.now().difference(_lastPacketAt!);

  /// No packet for [kStaleAfter] while nominally connected. The link may be up
  /// but the feed is dead — do not present [latestData] as live.
  bool get isStale {
    if (!isConnected) return false;
    final age = dataAge;
    return age == null || age > kStaleAfter;
  }

  /// Packets are arriving but the device's own uptime counter has stopped
  /// advancing — the firmware's sensor loop is wedged even though BLE is fine.
  bool get isFeedStalled => _uptimeStalled;

  // ===== PERMISSIONS =====

  /// Which runtime permission actually gates a BLE scan depends on the Android
  /// version, and the two cases are mutually exclusive:
  ///
  ///   * **Android 12+ (API 31+)** — BLUETOOTH_SCAN / BLUETOOTH_CONNECT. The
  ///     manifest declares `neverForLocation`, so no location grant is needed.
  ///   * **Android 11 and older** — those two permissions *do not exist*.
  ///     permission_handler finds no matching manifest entry and returns
  ///     `denied` for both **without ever showing a dialog**
  ///     (`PermissionManager.requestPermissions`, empty-names branch). There,
  ///     BLE scanning is gated on ACCESS_FINE_LOCATION instead.
  ///
  /// Gating on the Bluetooth grants alone therefore made scanning impossible on
  /// every Android 11-or-older device, while telling the user to go and enable
  /// a "Nearby devices" permission the system never offers them.
  Future<bool> _ensurePermissions() async {
    if (kIsWeb) return true;

    // Phase 1 — the modern path. If this succeeds we never prompt for location.
    final bt = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final scan = bt[Permission.bluetoothScan];
    final connect = bt[Permission.bluetoothConnect];

    if ((scan?.isGranted ?? false) && (connect?.isGranted ?? false)) {
      _permissionsPermanentlyDenied = false;
      return true;
    }

    // `permanentlyDenied` is only reachable for a permission the OS actually
    // knows about, so seeing it here proves we are on Android 12+ and the user
    // has locked us out. Asking for location would be a pointless extra dialog.
    final lockedOut =
        (scan?.isPermanentlyDenied ?? false) ||
        (connect?.isPermanentlyDenied ?? false);

    if (!lockedOut) {
      // Phase 2 — the Android 11-and-older path.
      final location = await Permission.locationWhenInUse.request();
      if (location.isGranted) {
        _permissionsPermanentlyDenied = false;
        return true;
      }
      _permissionsPermanentlyDenied = location.isPermanentlyDenied;
    } else {
      _permissionsPermanentlyDenied = true;
    }

    _errorMessage = _permissionsPermanentlyDenied
        ? 'Bluetooth permission is blocked. Open Settings → Permissions and '
            'allow "Nearby devices" (or "Location" on Android 11 and older), '
            'then scan again.'
        : 'Bluetooth permission denied. Allow "Nearby devices" — or '
            '"Location" on Android 11 and older — to scan for the '
            '$kDeviceName tool.';
    notifyListeners();
    return false;
  }

  /// True when a permission was denied with "don't ask again", so prompting
  /// again is futile and the user must be sent to system settings.
  bool get permissionsPermanentlyDenied => _permissionsPermanentlyDenied;

  /// Open this app's system settings page so the user can grant a permission
  /// that can no longer be requested in-app.
  Future<void> openSettings() => openAppSettings();

  // ===== SCANNING =====

  /// Start scanning for BLE devices
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (_connectionState != BleConnectionState.disconnected) return;

    _errorMessage = null;
    _scanResults = [];
    _connectionState = BleConnectionState.scanning;
    notifyListeners();

    try {
      if (!await _ensurePermissions()) {
        _connectionState = BleConnectionState.disconnected;
        notifyListeners();
        return;
      }

      // Check if Bluetooth is on
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        _errorMessage = 'Bluetooth is turned off. Please enable Bluetooth.';
        _connectionState = BleConnectionState.disconnected;
        notifyListeners();
        return;
      }

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        // Keep anything named, plus anything advertising the UART service even
        // if it arrived nameless. Android caches device names and sometimes
        // resolves them a beat late; filtering on the name alone can hide the
        // very device we are looking for.
        _scanResults = results
            .where((r) =>
                r.device.platformName.isNotEmpty || _advertisesUart(r))
            .toList();
        // Surface the tool first — techs shouldn't hunt for it in a list.
        _scanResults.sort((a, b) {
          final aIsTool = isTool(a) ? 0 : 1;
          final bIsTool = isTool(b) ? 0 : 1;
          return aIsTool.compareTo(bIsTool);
        });
        notifyListeners();
      });

      // Pass 1: filtered to the UART service, which is the reliable way to find
      // the tool — Android caches stale device names, so the name is for
      // display only.
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: [Guid(_serviceUuid)],
      );
      await _scanFinished();

      // Pass 2: some adapters don't surface 128-bit service UUIDs in the
      // advertisement, so the filtered pass can come back empty even with the
      // tool sitting right there. Fall back to an unfiltered sweep.
      //
      // This has to wait for pass 1 to actually finish: startScan returns as
      // soon as scanning *begins*, so testing _scanResults straight after it
      // always saw an empty list and restarted the scan unfiltered, discarding
      // the filtered pass every time.
      if (_scanResults.isEmpty &&
          _connectionState == BleConnectionState.scanning) {
        await FlutterBluePlus.startScan(timeout: timeout);
        await _scanFinished();
      }
    } catch (e) {
      _errorMessage = 'Scan failed: ${e.toString()}';
    }

    if (_connectionState == BleConnectionState.scanning) {
      _connectionState = BleConnectionState.disconnected;
      notifyListeners();
    }
  }

  /// True when this advertisement carries the Nordic UART service, i.e. it is
  /// one of our tools whatever name the OS reports.
  static bool _advertisesUart(ScanResult r) => r
      .advertisementData.serviceUuids
      .any((u) => u.str128.toLowerCase() == _serviceUuid);

  /// Whether a scan result is the diagnostic tool. Checks the advertised
  /// service first; the name is a fallback because Android caches it.
  static bool isTool(ScanResult r) =>
      _advertisesUart(r) || r.device.platformName == kDeviceName;

  /// Completes when the current scan stops — on timeout, or because
  /// [stopScan] was called. `startScan` itself returns as soon as scanning
  /// starts, so awaiting it tells you nothing about the results.
  Future<void> _scanFinished() =>
      FlutterBluePlus.isScanning.where((scanning) => !scanning).first;

  /// Stop scanning
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_connectionState == BleConnectionState.scanning) {
      _connectionState = BleConnectionState.disconnected;
      notifyListeners();
    }
  }

  // ===== CONNECTION =====

  /// Connect to a specific BLE device
  Future<void> connectToDevice(BluetoothDevice device) async {
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    await _connect(device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    _errorMessage = null;
    if (_connectionState != BleConnectionState.reconnecting) {
      _connectionState = BleConnectionState.connecting;
    }
    notifyListeners();

    try {
      await stopScan();
      await device.connect(
        timeout: const Duration(seconds: 10),
        license: License.free,
      );
      _connectedDevice = device;

      // Listen for disconnection
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Negotiate a larger MTU BEFORE subscribing. The ~95-byte packet does not
      // fit the default 23-byte ATT payload; without this every frame arrives
      // truncated and fails to parse. Not supported on iOS (the OS negotiates
      // automatically), so a failure here is non-fatal.
      await _requestMtu(device);

      // Discover services and subscribe to data
      await _subscribeToData(device);

      _connectionState = BleConnectionState.connected;
      _reconnectAttempts = 0;
      _startStalenessWatch();
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Connection failed: ${e.toString()}';
      _connectedDevice = null;
      if (!_intentionalDisconnect && _reconnectAttempts > 0) {
        _scheduleReconnect(device);
      } else {
        _connectionState = BleConnectionState.disconnected;
        notifyListeners();
      }
    }
  }

  Future<void> _requestMtu(BluetoothDevice device) async {
    try {
      await device.requestMtu(kPreferredMtu);
    } catch (e) {
      // iOS handles MTU itself and throws here; that is expected and fine.
      debugPrint('[BLE] MTU request not honoured (harmless on iOS): $e');
    }
  }

  /// Discover the UART service and subscribe to TX characteristic
  Future<void> _subscribeToData(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();

    BluetoothCharacteristic? txChar;
    _rxChar = null;

    for (var service in services) {
      if (service.uuid.toString().toLowerCase() == _serviceUuid) {
        for (var char in service.characteristics) {
          final id = char.uuid.toString().toLowerCase();
          if (id == _txCharUuid) txChar = char;
          if (id == _rxCharUuid) _rxChar = char;
        }
      }
    }

    if (txChar == null) {
      throw Exception('UART TX characteristic not found on device');
    }

    // Enable notifications. The firmware only transmits while a client is
    // subscribed, so nothing arrives until this succeeds.
    await txChar.setNotifyValue(true);

    // Listen for incoming data
    _dataSubscription?.cancel();
    _dataSubscription = txChar.lastValueStream.listen((value) {
      if (value.isNotEmpty) {
        _processIncomingData(value);
      }
    });
  }

  // ===== PARSING =====

  /// Map one decoded telemetry packet to the engine's [SensorData].
  ///
  /// Returns null if a required electrical field is missing. This is
  /// deliberate: the previous implementation defaulted every absent key to 0.0,
  /// so a firmware key rename produced a connected device streaming a full
  /// packet of zeros with no error anywhere. A missing required key is a
  /// protocol fault and is reported as one.
  ///
  /// Temperatures are the exception — absent or `null` means "probe not
  /// attached", which is a legitimate state, and is preserved as null.
  SensorData? _sensorFromJson(Map<String, dynamic> json) {
    double? req(String key) {
      final v = json[key];
      return v is num ? v.toDouble() : null;
    }

    double? opt(String key) {
      final v = json[key];
      return v is num ? v.toDouble() : null;
    }

    final vPanel = req('v_panel');
    final vBatt = req('v_batt');
    final current = req('current');
    final power = req('power');

    if (vPanel == null || vBatt == null || current == null || power == null) {
      final missing = <String>[
        if (vPanel == null) 'v_panel',
        if (vBatt == null) 'v_batt',
        if (current == null) 'current',
        if (power == null) 'power',
      ];
      _errorMessage = 'Malformed packet from device: missing '
          '${missing.join(', ')}. Check the firmware JSON keys match the '
          'contract (v_panel, v_batt, current, power, t_panel, t_amb, ts).';
      debugPrint('[BLE] $_errorMessage');
      return null;
    }

    final ts = json['ts'];

    return SensorData(
      panelVoltage: vPanel,
      batteryVoltage: vBatt,
      current: current,
      power: power,
      // Null propagates: probe absent stays absent all the way to the engine.
      panelTemp: opt('t_panel'),
      ambientTemp: opt('t_amb'),
      uptimeSeconds: ts is num ? ts.toInt() : null,
      timestamp: DateTime.now(),
    );
  }

  /// Process raw BLE data bytes into SensorData.
  ///
  /// Extracts every complete JSON object in the buffer, in order. The previous
  /// version took `lastIndexOf('{')`, which silently discarded an earlier
  /// packet whenever two arrived in one read — and since the fault engine
  /// debounces over 3 consecutive packets, dropped packets delay every fault.
  void _processIncomingData(List<int> rawData) {
    try {
      _dataBuffer += utf8.decode(rawData, allowMalformed: true);
    } catch (e) {
      debugPrint('[BLE] Decode error: $e');
      _dataBuffer = '';
      return;
    }

    // Guard against unbounded growth if we never see a closing brace.
    if (_dataBuffer.length > 4096) {
      debugPrint('[BLE] Buffer overflow without a complete frame; resetting');
      _dataBuffer = '';
      return;
    }

    for (final frame in _extractFrames()) {
      try {
        final decoded = jsonDecode(frame);
        if (decoded is! Map<String, dynamic>) continue;
        final data = _sensorFromJson(decoded);
        if (data != null) {
          _recordPacket(data);
        }
      } catch (e) {
        // A garbled frame is not worth surfacing; the next one is 1s away.
        debugPrint('[BLE] Frame parse error: $e');
      }
    }
    notifyListeners();
  }

  /// Pull every balanced `{...}` object out of the buffer, leaving any partial
  /// trailing frame in place for the next chunk.
  List<String> _extractFrames() {
    final frames = <String>[];
    var depth = 0;
    int? start;

    for (var i = 0; i < _dataBuffer.length; i++) {
      final ch = _dataBuffer[i];
      if (ch == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (ch == '}') {
        if (depth > 0) {
          depth--;
          if (depth == 0 && start != null) {
            frames.add(_dataBuffer.substring(start, i + 1));
            start = null;
          }
        }
      }
    }

    // Keep only the unterminated tail.
    if (start != null) {
      _dataBuffer = _dataBuffer.substring(start);
    } else if (frames.isNotEmpty) {
      _dataBuffer = '';
    }

    return frames;
  }

  void _recordPacket(SensorData data) {
    // The device's own clock is the honest staleness signal: if `ts` stops
    // advancing, the sensor loop is wedged even though BLE keeps delivering.
    final ts = data.uptimeSeconds;
    if (ts != null && _lastUptimeSeconds != null) {
      _uptimeStalled = ts == _lastUptimeSeconds;
    } else {
      _uptimeStalled = false;
    }
    if (ts != null) _lastUptimeSeconds = ts;

    _lastPacketAt = DateTime.now();
    _latestData = data;
    _errorMessage = null;
    if (!_readings.isClosed) _readings.add(data);
  }

  // ===== STALENESS =====

  /// Ticks once a second so the UI can grey out numbers that have stopped
  /// updating, rather than showing a frozen reading as if it were live.
  void _startStalenessWatch() {
    _stalenessTimer?.cancel();
    var wasStale = false;
    _stalenessTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
      final nowStale = isStale || isFeedStalled;
      if (nowStale != wasStale) {
        wasStale = nowStale;
        notifyListeners();
      } else if (nowStale) {
        // Keep the age counter live while stale.
        notifyListeners();
      }
    });
  }

  void _stopStalenessWatch() {
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
  }

  // ===== RECALIBRATION =====

  /// App -> device: re-zero the ACS712 current sensor without a reboot.
  ///
  /// IMPORTANT: the zero-calibration assumes no current is flowing. The caller
  /// must confirm the DC path is open before invoking this — calibrating under
  /// load bakes the load current in as the new zero, and every subsequent
  /// current reading is wrong by that offset. See the confirmation dialog in
  /// the scanner screen.
  Future<bool> recalibrate() async {
    final rx = _rxChar;
    if (rx == null) {
      _errorMessage = 'This device does not expose the calibration '
          'characteristic.';
      notifyListeners();
      return false;
    }
    try {
      await rx.write(utf8.encode('CAL'), withoutResponse: false);
      return true;
    } catch (e) {
      _errorMessage = 'Calibration command failed: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  // ===== DISCONNECT / RECONNECT =====

  /// Disconnect from the current device
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _simulationTimer?.cancel();
    _simulationTimer = null;
    _stopStalenessWatch();
    _dataSubscription?.cancel();
    _dataSubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;

    try {
      await _connectedDevice?.disconnect();
    } catch (e) {
      debugPrint('[BLE] Disconnect error: $e');
    }

    _resetLinkState();
    _connectionState = BleConnectionState.disconnected;
    notifyListeners();
  }

  void _resetLinkState() {
    _connectedDevice = null;
    _latestData = null;
    _dataBuffer = '';
    _rxChar = null;
    _lastPacketAt = null;
    _lastUptimeSeconds = null;
    _uptimeStalled = false;
  }

  void _handleDisconnection() {
    _dataSubscription?.cancel();
    _dataSubscription = null;
    _stopStalenessWatch();

    final device = _connectedDevice;
    _latestData = null;
    _dataBuffer = '';
    _rxChar = null;
    _lastPacketAt = null;
    _lastUptimeSeconds = null;
    _uptimeStalled = false;

    // This is a portable tool — it gets switched off between jobs, and the
    // firmware re-advertises on power-up. An unrequested drop should recover on
    // its own rather than stranding the tech on a frozen screen.
    if (!_intentionalDisconnect && device != null) {
      _scheduleReconnect(device);
    } else {
      _connectedDevice = null;
      _connectionState = BleConnectionState.disconnected;
      _errorMessage = 'Device disconnected';
      notifyListeners();
    }
  }

  /// Retry with backoff: 2s, 4s, 8s, capped at 15s, indefinitely. The tool may
  /// be off for a whole coffee break; give up on the attempt, never on the
  /// device.
  void _scheduleReconnect(BluetoothDevice device) {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;

    final delaySeconds = min(15, 1 << min(_reconnectAttempts, 4));
    _connectionState = BleConnectionState.reconnecting;
    _errorMessage = 'Connection lost. Reconnecting to $kDeviceName '
        '(attempt $_reconnectAttempts)…';
    notifyListeners();

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (_intentionalDisconnect) return;
      await _connect(device);
    });
  }

  /// Give up on automatic reconnection and return to the disconnected state.
  void cancelReconnect() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _resetLinkState();
    _connectionState = BleConnectionState.disconnected;
    _errorMessage = null;
    notifyListeners();
  }

  // ===== SIMULATION MODE =====

  /// Start generating simulated sensor data (for demo/testing)
  void startSimulation() {
    _simulationTimer?.cancel();
    _connectionState = BleConnectionState.simulating;
    _errorMessage = null;
    notifyListeners();

    final random = Random();
    int tick = 0;

    _simulationTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      tick++;

      // Generate realistic-looking sensor data with some variance
      double baseVoltage = 17.0 + 4.0 * sin(tick * 0.1); // Simulate sun arc
      double panelVoltage = baseVoltage + (random.nextDouble() - 0.5) * 1.0;
      panelVoltage = panelVoltage.clamp(0.0, 22.0);

      double batteryVoltage = 12.0 + (random.nextDouble() * 2.5);
      double current = (panelVoltage > 5) ? 2.0 + random.nextDouble() * 6.0 : 0.1;
      double panelTemp = 40.0 + random.nextDouble() * 25.0;
      double ambientTemp = 28.0 + random.nextDouble() * 8.0;

      _recordPacket(SensorData(
        panelVoltage: double.parse(panelVoltage.toStringAsFixed(2)),
        batteryVoltage: double.parse(batteryVoltage.toStringAsFixed(2)),
        current: double.parse(current.toStringAsFixed(2)),
        panelTemp: double.parse(panelTemp.toStringAsFixed(1)),
        ambientTemp: double.parse(ambientTemp.toStringAsFixed(1)),
        power: double.parse((panelVoltage * current).toStringAsFixed(2)),
        uptimeSeconds: tick * 2,
        timestamp: DateTime.now(),
      ));
      notifyListeners();
    });
  }

  /// Stop simulation
  void stopSimulation() {
    _simulationTimer?.cancel();
    _simulationTimer = null;
    _latestData = null;
    _lastPacketAt = null;
    _lastUptimeSeconds = null;
    _connectionState = BleConnectionState.disconnected;
    notifyListeners();
  }

  // ===== CLEANUP =====

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _stalenessTimer?.cancel();
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _dataSubscription?.cancel();
    _connectionSubscription?.cancel();
    _connectedDevice?.disconnect();
    _readings.close();
    super.dispose();
  }
}
