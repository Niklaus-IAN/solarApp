import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/saved_system.dart';
import '../services/fault_diagnosis_service.dart';
import '../services/ble_service.dart';
import '../services/database_service.dart';
import 'add_system_screen.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  /// Rebuilt whenever the monitored system changes. Holds debounce state
  /// across packets, so it must be a single long-lived instance per device.
  FaultDiagnosisService? _diag;
  SavedSystem? _activeSystem;

  int _healthScore = 100;
  List<FaultCode> _activeFaults = [];
  DiagnosisReport? _report;
  SensorData? _lastProcessedData;
  BleConnectionState? _prevConnState;

  // Track previous fault codes to detect new/cleared faults for the DB.
  Set<String> _previousFaultCodes = {};

  /// Cached so it can be used in [dispose], where an inherited-widget lookup
  /// (Provider.of) is no longer safe.
  BleService? _bleService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadActiveSystem();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bleService = Provider.of<BleService>(context, listen: false);
    if (_bleService != bleService) {
      _bleService?.removeListener(_onBleDataChanged);
      _bleService = bleService;
      _bleService!.addListener(_onBleDataChanged);
    }
  }

  @override
  void dispose() {
    _bleService?.removeListener(_onBleDataChanged);
    super.dispose();
  }

  /// Load the system currently selected for monitoring (falling back to a
  /// sensible default) and build the diagnosis engine around its thresholds.
  Future<void> _loadActiveSystem() async {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final sys = await db.getActiveSystem();
    if (!mounted) return;
    setState(() {
      _activeSystem = sys;
      _diag = FaultDiagnosisService(sys?.config ?? defaultSystemConfig());
    });
  }

  void _onBleDataChanged() {
    final bleService = Provider.of<BleService>(context, listen: false);

    // Reset debounce streaks when a fresh connection begins.
    final state = bleService.connectionState;
    final becameLive = _prevConnState != state &&
        (state == BleConnectionState.connected ||
            state == BleConnectionState.simulating);
    if (becameLive) _diag?.reset();
    _prevConnState = state;

    final data = bleService.latestData;
    if (data != null && data != _lastProcessedData) {
      _lastProcessedData = data;
      _runDiagnosis(data);
    }
  }

  void _runDiagnosis(SensorData data) {
    final diag = _diag ??= FaultDiagnosisService(defaultSystemConfig());
    final report = diag.diagnose(data);

    setState(() {
      _report = report;
      _healthScore = report.healthScore;
      _activeFaults = report.faults;
    });

    _saveToDB(data, report);
  }

  Future<void> _saveToDB(SensorData data, DiagnosisReport report) async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    await dbService.insertReading(
      data: data,
      healthScore: report.healthScore,
      faultCount: report.faults.length,
    );

    final currentFaultCodes = report.faults.map((f) => f.code).toSet();
    final newFaults = currentFaultCodes.difference(_previousFaultCodes);
    for (final fault in report.faults) {
      if (newFaults.contains(fault.code)) {
        await dbService.insertFault(fault);
      }
    }

    if (currentFaultCodes.isNotEmpty) {
      await dbService.clearFaults(currentFaultCodes.toList());
    } else if (_previousFaultCodes.isNotEmpty) {
      await dbService.clearFaults([]);
    }

    _previousFaultCodes = currentFaultCodes;
  }

  // ===== SYSTEM PICKER =====

  void _showSystemPicker() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.primaryMid,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return FutureBuilder<List<SavedSystem>>(
          future: db.getSavedSystems(),
          builder: (ctx, snapshot) {
            final systems = snapshot.data ?? [];
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.textMuted,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Monitored System',
                      style: Theme.of(ctx).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  const Text(
                    'Fault thresholds are derived from the selected system.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  if (systems.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.accentBlue.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'No systems saved yet. A sensible default 24 V lithium '
                        'system is being used.\n\nSize a system on the Sizing tab '
                        'and tap "Save as system", or add an existing system, to '
                        'monitor against real thresholds.',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13),
                      ),
                    )
                  else
                    ...systems.map((s) => _buildSystemTile(ctx, s, db)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final added = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                              builder: (_) => const AddSystemScreen()),
                        );
                        if (added == true) await _loadActiveSystem();
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add existing system'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.accentBlue,
                        side: const BorderSide(color: AppTheme.accentBlue),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSystemTile(
      BuildContext ctx, SavedSystem s, DatabaseService db) {
    final selected = _activeSystem?.id == s.id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? AppTheme.accentGreen : AppTheme.textMuted,
      ),
      title: Text(s.name,
          style: const TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${s.source.label} · ${s.config.systemVoltage}V · '
        '${s.config.chemistry.label} · ${s.config.panelCount}×'
        '${s.config.panel.watts.toStringAsFixed(0)}W',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline,
            size: 20, color: AppTheme.textMuted),
        onPressed: () async {
          await db.deleteSystem(s.id);
          if (ctx.mounted) Navigator.pop(ctx);
          await _loadActiveSystem();
        },
      ),
      onTap: () async {
        await db.setActiveSystem(s.id);
        if (ctx.mounted) Navigator.pop(ctx);
        await _loadActiveSystem();
      },
    );
  }

  // ===== CONNECTION =====

  void _showConnectionOptions() {
    final bleService = Provider.of<BleService>(context, listen: false);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.primaryMid,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text('Connect to Device',
                  style: Theme.of(ctx).textTheme.headlineSmall),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    _startBLEScan();
                  },
                  icon: const Icon(Icons.bluetooth_searching, size: 20),
                  label: const Text('Scan for ESP32'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    bleService.startSimulation();
                  },
                  icon: const Icon(Icons.play_circle_outline, size: 20),
                  label: const Text('Simulate (Demo Mode)'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accentGreen,
                    side: const BorderSide(color: AppTheme.accentGreen),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _startBLEScan() {
    final bleService = Provider.of<BleService>(context, listen: false);
    bleService.startScan();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return ChangeNotifierProvider.value(
          value: bleService,
          child: Consumer<BleService>(
            builder: (ctx, ble, _) {
              bool isScanning =
                  ble.connectionState == BleConnectionState.scanning;
              bool isConnecting =
                  ble.connectionState == BleConnectionState.connecting;

              return AlertDialog(
                backgroundColor: AppTheme.primaryMid,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: Row(
                  children: [
                    if (isScanning || isConnecting)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    if (isScanning || isConnecting) const SizedBox(width: 12),
                    Text(
                      isConnecting
                          ? 'Connecting...'
                          : isScanning
                              ? 'Scanning...'
                              : 'Scan Complete',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 250,
                  child: ble.scanResults.isEmpty
                      ? Center(
                          child: Text(
                            isScanning
                                ? 'Looking for SolarOBD devices...'
                                : 'No devices found',
                            style: const TextStyle(
                                color: AppTheme.textSecondary),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: ble.scanResults.length,
                          itemBuilder: (ctx, i) {
                            final result = ble.scanResults[i];
                            final name = result.device.platformName;
                            final isSolarOBD = name.contains('SolarOBD');

                            return ListTile(
                              leading: Icon(
                                Icons.bluetooth,
                                color: isSolarOBD
                                    ? AppTheme.accentGreen
                                    : AppTheme.textMuted,
                              ),
                              title: Text(
                                name,
                                style: TextStyle(
                                  color: isSolarOBD
                                      ? AppTheme.accentGreen
                                      : AppTheme.textPrimary,
                                  fontWeight: isSolarOBD
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                              subtitle: Text(
                                'RSSI: ${result.rssi} dBm',
                                style: const TextStyle(
                                    color: AppTheme.textMuted, fontSize: 12),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                ble.connectToDevice(result.device);
                              },
                            );
                          },
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      ble.stopScan();
                      Navigator.pop(ctx);
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, bleService, _) {
        final isConnected = bleService.isConnected;
        final data = bleService.latestData;
        // Link may be open while the feed has died. Numbers on screen are then
        // history, and must not be styled as live telemetry.
        final stale = bleService.isStale || bleService.isFeedStalled;
        final connectionState = bleService.connectionState;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 8),

              // Monitored-system selector
              _buildSystemChip(),

              const SizedBox(height: 12),

              // Connection button
              GestureDetector(
                onTap: isConnected
                    ? () => bleService.disconnect()
                    : _showConnectionOptions,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: isConnected
                        ? AppTheme.accentGreen.withOpacity(0.15)
                        : connectionState == BleConnectionState.scanning
                            ? AppTheme.accentOrange.withOpacity(0.15)
                            : AppTheme.accentBlue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isConnected
                          ? AppTheme.accentGreen.withOpacity(0.3)
                          : connectionState == BleConnectionState.scanning
                              ? AppTheme.accentOrange.withOpacity(0.3)
                              : AppTheme.accentBlue.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (connectionState == BleConnectionState.scanning ||
                          connectionState == BleConnectionState.connecting)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.accentOrange),
                        )
                      else
                        Icon(
                          isConnected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth_searching,
                          color: isConnected
                              ? AppTheme.accentGreen
                              : AppTheme.accentBlue,
                          size: 20,
                        ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          connectionState == BleConnectionState.connected
                              ? 'Connected to ${bleService.deviceName}'
                              : connectionState == BleConnectionState.simulating
                                  ? 'Simulating — Tap to stop'
                                  : connectionState ==
                                          BleConnectionState.scanning
                                      ? 'Scanning...'
                                      : connectionState ==
                                              BleConnectionState.connecting
                                          ? 'Connecting...'
                                          : 'Tap to connect',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isConnected
                                ? AppTheme.accentGreen
                                : AppTheme.accentBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Error message
              if (bleService.errorMessage != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.accentRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bleService.errorMessage!,
                    style: const TextStyle(
                        color: AppTheme.accentRed, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],

              // Feed stalled / stale — shown above the numbers it applies to.
              if (isConnected && stale) ...[
                const SizedBox(height: 8),
                _buildNoticeCard(
                  icon: Icons.pause_circle_outline,
                  color: AppTheme.accentOrange,
                  title: bleService.isFeedStalled
                      ? 'Device feed stalled'
                      : 'No data from device',
                  body: bleService.isFeedStalled
                      ? 'Packets are still arriving but the device clock has '
                          'stopped advancing — its sensor loop is not running. '
                          'Power-cycle the tool.'
                      : 'Last reading '
                          '${_ageLabel(bleService.dataAge)} ago. The readings '
                          'below are frozen, not live.',
                ),
              ],

              // Reconnecting after an unrequested drop.
              if (bleService.isReconnecting) ...[
                const SizedBox(height: 8),
                _buildNoticeCard(
                  icon: Icons.bluetooth_searching,
                  color: AppTheme.accentBlue,
                  title: 'Reconnecting…',
                  body: bleService.errorMessage ??
                      'Lost the link to the tool. Retrying automatically.',
                  action: TextButton(
                    onPressed: bleService.cancelReconnect,
                    child: const Text('Stop'),
                  ),
                ),
              ],

              // Partial assessment — a suppressed diagnosis must never be
              // presented as a passing one.
              if (_report != null && _report!.isPartialAssessment) ...[
                const SizedBox(height: 8),
                _buildNoticeCard(
                  icon: Icons.thermostat,
                  color: AppTheme.accentYellow,
                  title: 'Partial assessment — probe missing',
                  body: 'Panel, current and performance checks need both '
                      'temperature probes to confirm the array is in sunlight. '
                      'With one probe they are suppressed, so the health score '
                      'below covers the battery and panel temperature only.',
                ),
              ],

              const SizedBox(height: 16),

              // Health Score
              _buildHealthScoreCard(),

              const SizedBox(height: 16),

              // Re-zero the current sensor. Guarded by a confirmation because
              // the calibration is only valid with the DC path open.
              if (isConnected && bleService.supportsRecalibration) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmRecalibrate(bleService),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Re-zero current sensor'),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Sensor Readings Grid
              Row(
                children: [
                  Expanded(
                      child: _buildGaugeCard(
                          'Panel V',
                          data != null
                              ? data.panelVoltage.toStringAsFixed(2)
                              : '--',
                          'V',
                          AppTheme.accentBlue,
                          dimmed: stale)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _buildGaugeCard(
                          'Battery V',
                          data != null
                              ? data.batteryVoltage.toStringAsFixed(2)
                              : '--',
                          'V',
                          AppTheme.accentGreen,
                          dimmed: stale)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                      child: _buildGaugeCard(
                          'Current',
                          data != null
                              ? data.current.toStringAsFixed(2)
                              : '--',
                          'A',
                          AppTheme.accentOrange,
                          dimmed: stale)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _buildGaugeCard(
                          'Power',
                          data != null ? data.power.toStringAsFixed(1) : '--',
                          'W',
                          AppTheme.accentYellow,
                          dimmed: stale)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  // A null temperature means the probe is not attached — a
                  // different thing from "no reading yet", and it disables the
                  // daylight-gated checks, so it is labelled rather than shown
                  // as a bare dash.
                  Expanded(
                      child: _buildGaugeCard(
                          'Panel Temp',
                          data?.panelTemp?.toStringAsFixed(1) ?? '--',
                          '°C',
                          AppTheme.accentRed,
                          note: data != null && !data.hasPanelTemp
                              ? 'probe not fitted'
                              : null,
                          dimmed: stale)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _buildGaugeCard(
                          'Ambient',
                          data?.ambientTemp?.toStringAsFixed(1) ?? '--',
                          '°C',
                          AppTheme.accentBlue,
                          note: data != null && !data.hasAmbientTemp
                              ? 'probe not fitted'
                              : null,
                          dimmed: stale)),
                ],
              ),

              const SizedBox(height: 20),

              // Active Fault Codes
              if (_activeFaults.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Active Fault Codes',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 10),
                ..._activeFaults.map((fault) => _buildFaultCard(fault)),
              ] else if (isConnected) ...[
                _buildHealthyCard(),
              ],

              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSystemChip() {
    final name = _activeSystem?.name ?? 'Default system';
    final sub = _activeSystem == null
        ? '24 V · Lithium · no system saved'
        : '${_activeSystem!.config.systemVoltage} V · '
            '${_activeSystem!.config.chemistry.label} · '
            '${_activeSystem!.source.label}';
    return GestureDetector(
      onTap: _showSystemPicker,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.cardBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.tune, size: 18, color: AppTheme.accentBlue),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Monitoring',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
                  Text(name,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  Text(sub,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.expand_more, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  String _ageLabel(Duration? age) {
    if (age == null) return 'never';
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    return '${age.inHours}h';
  }

  /// Inline banner for conditions the tech must see before trusting the
  /// numbers: stale feed, reconnection in progress, degraded sensing.
  Widget _buildNoticeCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.4),
                ),
              ],
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  /// The ACS712 zero-calibration assumes no current is flowing. Calibrating
  /// under load bakes the load current in as the new zero and silently offsets
  /// every subsequent reading — so the DC path must be opened first, and that
  /// is a physical step only the tech can perform.
  Future<void> _confirmRecalibrate(BleService bleService) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.primaryMid,
        title: const Text('Re-zero current sensor'),
        content: const Text(
          'Open the DC line before continuing — disconnect the panel or switch '
          'off the isolator so no current is flowing.\n\n'
          'Calibrating while current flows records that current as zero, and '
          'every reading afterwards will be wrong by the same amount.',
          style: TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DC line is open — calibrate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final ok = await bleService.recalibrate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Calibration command sent. Reconnect the DC line.'
            : bleService.errorMessage ?? 'Calibration failed.'),
        backgroundColor:
            ok ? AppTheme.accentGreen : AppTheme.accentRed,
      ),
    );
  }

  Widget _buildHealthScoreCard() {
    Color scoreColor = AppTheme.healthScoreColor(_healthScore);
    String scoreLabel = AppTheme.healthScoreLabel(_healthScore);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scoreColor.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          const Text(
            'System Health',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            '$_healthScore%',
            style: GoogleFonts.orbitron(
              fontSize: 52,
              fontWeight: FontWeight.w700,
              color: scoreColor,
              letterSpacing: -1,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: scoreColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              scoreLabel,
              style: TextStyle(
                color: scoreColor,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                letterSpacing: 1.5,
              ),
            ),
          ),
          if (_report != null) ...[
            const SizedBox(height: 12),
            Text(
              _report!.summary,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHealthyCard() {
    final regulating = _report?.controllerRegulating ?? false;
    // "Undetermined" is not "night". When a probe is missing the daylight gate
    // cannot be evaluated at all, so this card must not claim the array was
    // checked and found fine — it renders amber, not green.
    final partial = _report?.isPartialAssessment ?? false;
    final night =
        _report != null && _report!.daylightDetermined && !_report!.isDaytime;

    final tone = partial ? AppTheme.accentYellow : AppTheme.accentGreen;
    final icon = partial ? Icons.info_outline : Icons.check_circle;
    final title = partial
        ? 'No faults in the domains checked'
        : night
            ? 'Array not in sunlight'
            : regulating
                ? 'Battery full — controller regulating'
                : 'No faults detected';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Icon(icon, color: tone, size: 40),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: tone,
                fontSize: 16,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _report?.summary ?? 'System is operating normally',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// [note] annotates why a value is absent (e.g. "probe not fitted") so a
  /// dash is never ambiguous between "no data yet" and "no sensor".
  /// [dimmed] greys the value when the feed has gone stale — a frozen number
  /// must not read as a live one.
  Widget _buildGaugeCard(
    String label,
    String value,
    String unit,
    Color color, {
    String? note,
    bool dimmed = false,
  }) {
    final effective = dimmed ? AppTheme.textMuted : color;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: GoogleFonts.orbitron(
                  color: effective,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(unit,
                    style: TextStyle(
                        color: effective.withOpacity(0.7), fontSize: 14)),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note,
              style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFaultCard(FaultCode fault) {
    final severityName = fault.severity.name.toUpperCase();
    final severityColor = AppTheme.severityColor(severityName);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: severityColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: severityColor.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: severityColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  fault.code,
                  style: TextStyle(
                      color: severityColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: severityColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  severityName,
                  style: TextStyle(
                      color: severityColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11),
                ),
              ),
              const Spacer(),
              Text(
                '-${fault.severity.deduction} pts',
                style: TextStyle(
                    color: severityColor.withOpacity(0.7), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            fault.title,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14),
          ),
          const SizedBox(height: 10),
          _buildFaultDetail(Icons.help_outline, 'Cause', fault.cause),
          const SizedBox(height: 6),
          _buildFaultDetail(Icons.build, 'Action', fault.action),
        ],
      ),
    );
  }

  Widget _buildFaultDetail(IconData icon, String label, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12),
                ),
                TextSpan(
                  text: text,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
