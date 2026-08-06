import 'dart:collection';
import 'dart:math' as math;

import '../models/system_config.dart';

/// Severity, with the health deduction attached.
enum FaultSeverity {
  critical(30),
  high(20),
  medium(10),
  low(3);

  const FaultSeverity(this.deduction);
  final int deduction;
}

enum FaultDomain { panel, current, battery, temperature, performance }

class FaultCode {
  final String code;
  final FaultDomain domain;
  final FaultSeverity severity;
  final String title;
  final String cause;
  final String action;

  const FaultCode({
    required this.code,
    required this.domain,
    required this.severity,
    required this.title,
    required this.cause,
    required this.action,
  });
}

/// One BLE telemetry packet.
///
/// Temperatures are nullable and MUST stay that way. The firmware sends JSON
/// `null` for a probe that is not attached (it maps DEVICE_DISCONNECTED_C to
/// null, never 0 and never -99). Coercing that to 0.0 was the old behaviour and
/// it silently corrupted the daylight gate: `panelTemp > 0 + 3` is true for
/// essentially any panel in Lagos, so every daylight-only check ran around the
/// clock, including at night. Treat absent as absent.
class SensorData {
  final double panelVoltage;
  final double batteryVoltage;
  final double current;

  /// Back-of-module temperature, degC. Null when the probe is not attached.
  final double? panelTemp;

  /// Shaded ambient temperature, degC. Null when the probe is not attached.
  final double? ambientTemp;

  final double power;

  /// Device uptime in seconds (`ts`), monotonic since boot. Null on firmware
  /// that predates the field. Used to detect a stalled feed — a link that is
  /// still open but no longer producing fresh packets.
  final int? uptimeSeconds;

  /// When this packet arrived on the phone.
  final DateTime timestamp;

  const SensorData({
    required this.panelVoltage,
    required this.batteryVoltage,
    required this.current,
    required this.panelTemp,
    required this.ambientTemp,
    required this.power,
    this.uptimeSeconds,
    required this.timestamp,
  });

  bool get hasPanelTemp => panelTemp != null;
  bool get hasAmbientTemp => ambientTemp != null;

  /// Both probes reporting — the precondition for any daylight inference.
  bool get hasBothTemps => panelTemp != null && ambientTemp != null;
}

class DiagnosisReport {
  final List<FaultCode> faults;
  final int healthScore;
  final Map<FaultDomain, int> domainScores;
  final bool isDaytime;
  final bool controllerRegulating;
  final bool performanceEvaluated;
  final double? performanceRatio;
  final String summary;

  /// Whether the daylight gate could be evaluated at all. False means a
  /// temperature probe was missing, so `isDaytime` is "unknown" rather than
  /// "night" — the distinction matters, because the UI must not present a
  /// suppressed panel diagnosis as a clean bill of health.
  final bool daylightDetermined;

  final bool panelTempAvailable;
  final bool ambientTempAvailable;

  const DiagnosisReport({
    required this.faults,
    required this.healthScore,
    required this.domainScores,
    required this.isDaytime,
    required this.controllerRegulating,
    required this.performanceEvaluated,
    required this.performanceRatio,
    required this.summary,
    required this.daylightDetermined,
    required this.panelTempAvailable,
    required this.ambientTempAvailable,
  });

  /// Fault domains that could not be assessed with the probes reporting.
  /// Empty when the hardware is complete.
  List<FaultDomain> get unavailableDomains => daylightDetermined
      ? const []
      : const [FaultDomain.panel, FaultDomain.current, FaultDomain.performance];

  /// True when the health score covers only part of the system, and so must
  /// not be shown as a whole-system verdict.
  bool get isPartialAssessment => !daylightDetermined || !panelTempAvailable;
}

/// Rule-based diagnostic engine.
///
/// FIVE CORRECTIONS TO THE ORIGINAL IMPLEMENTATION
///
/// 1. PV-001 was unreachable. The old daylight gate was
///    `panelVoltage > 1.0 && panelTemp > ambientTemp + 5`, while PV-001 fires
///    on `voltage < 1V in daylight`. A disconnected panel at noon reads 0 V,
///    so the gate closed and the fault could never raise — the condition being
///    tested was part of the test for whether to test it. The gate is now
///    thermal only, which is valid because a disconnected panel still heats in
///    the sun.
///
/// 2. Performance ratio corrected for temperature but not irradiance. Rated
///    power is defined at 1000 W/m2. At 08:00 or under cloud a healthy panel
///    produces a fraction of rating, which tripped PERF-001 CRITICAL on
///    working systems. The ratio is now only evaluated when panel-above-
///    ambient rise indicates strong irradiance.
///
/// 3. No awareness of charge controller state. When the bank is full the
///    controller deliberately throttles current: voltage stays high, current
///    collapses, power drops. That tripped CURR-001 and PERF-001 together —
///    fifty health points off a healthy system, every sunny afternoon.
///    Current and performance checks are now suppressed in absorption/float.
///
/// 4. Health score double-counted. A shaded panel raised PV-002 and PERF-001
///    for one root cause. Scoring is now worst-fault-per-domain, with the
///    per-domain breakdown exposed for display.
///
/// 5. A missing temperature probe was indistinguishable from 0 degC. The BLE
///    layer coerced the firmware's `null` to 0.0, which turned the daylight
///    gate into `panelTemp > 3` — true for any panel in Lagos, day or night.
///    Daylight-only checks therefore ran around the clock against a fabricated
///    ambient reading. Temperatures are now nullable end to end, and the
///    daylight gate is tri-state: true, false, or undetermined. Undetermined
///    suppresses the panel, current and performance domains and is surfaced to
///    the UI via [DiagnosisReport.isPartialAssessment], so a suppressed
///    diagnosis is never rendered as a passing one.
class FaultDiagnosisService {
  final SystemConfig config;

  /// Consecutive readings a condition must persist before a code is raised.
  /// One noisy ADC sample should not declare a fault.
  final int debounceCount;

  final Map<String, int> _streaks = HashMap<String, int>();

  FaultDiagnosisService(this.config, {this.debounceCount = 3});

  DiagnosisReport diagnose(SensorData d) {
    final t = config.thresholds;
    final faults = <FaultCode>[];

    // Daylight inference needs BOTH probes — it is a differential measurement,
    // so one probe is not "half" the signal, it is none of it. When either is
    // missing the gate is undetermined and every daylight-only check is
    // suppressed rather than guessed at. See correction 5.
    final daylightDetermined = d.hasBothTemps;

    // Daylight: thermal signal only. See correction 1.
    final isDaytime = daylightDetermined &&
        d.panelTemp! > d.ambientTemp! + t.daylightDeltaT;

    // Controller in absorption or float — it is throttling on purpose.
    final controllerRegulating =
        d.batteryVoltage > t.absorptionThreshold;

    // Irradiance proxy for the performance ratio. See correction 2.
    final strongIrradiance = daylightDetermined &&
        d.panelTemp! > d.ambientTemp! + t.performanceDeltaT;

    double? performanceRatio;
    var performanceEvaluated = false;

    // ------------------------------------------------------- panel voltage
    if (isDaytime) {
      // Bands are made mutually exclusive and hoisted so each debounce streak
      // accumulates on its own. A shared `else { _clear() }` would zero a
      // streak that is still building and make the severe code unreachable.
      final pvNoOutput = d.panelVoltage < 1.0;
      final pvLow = !pvNoOutput && d.panelVoltage < t.arrayVoc * 0.40;
      if (_trip('PV-001', pvNoOutput)) {
        faults.add(const FaultCode(
          code: 'PV-001',
          domain: FaultDomain.panel,
          severity: FaultSeverity.critical,
          title: 'No panel output in daylight',
          cause: 'Panel disconnected, blown string fuse, open MC4 connector, '
              'or module failure.',
          action: 'Isolate the array and check continuity from the module '
              'junction box to the controller input. Inspect the string fuse.',
        ));
      } else if (_trip('PV-002', pvLow)) {
        faults.add(const FaultCode(
          code: 'PV-002',
          domain: FaultDomain.panel,
          severity: FaultSeverity.high,
          title: 'Panel voltage well below expected',
          cause: 'Shading, heavy soiling, or module degradation.',
          action: 'Clean the modules in the early morning while cool. Check '
              'for new shading from vegetation or construction.',
        ));
      }

      // ----------------------------------------------------- current starved
      // Suppressed while the controller regulates. See correction 3.
      if (!controllerRegulating) {
        final voltageHealthy = d.panelVoltage > t.arrayVmpp * 0.50;
        final currentStarved = d.current < t.arrayIsc * 0.20;
        if (_trip('CURR-001', voltageHealthy && currentStarved)) {
          faults.add(const FaultCode(
            code: 'CURR-001',
            domain: FaultDomain.current,
            severity: FaultSeverity.high,
            title: 'Voltage present but no current flowing',
            cause: 'Loose or corroded connection, failed blocking diode, or '
                'charge controller input fault.',
            action: 'Check every DC termination for looseness and '
                'discolouration. Re-seat MC4 connectors.',
          ));
        }
      } else {
        _clear('CURR-001');
      }

      // ------------------------------------------------- performance ratio
      if (!controllerRegulating && strongIrradiance) {
        performanceEvaluated = true;
        // Temperature-corrected expected power, from the project's MATLAB
        // single-diode coefficient, further reduced for module age.
        // Safe to force: strongIrradiance implies daylightDetermined, which
        // implies both probes reported.
        final expected =
            t.arrayRatedW * config.panel.temperatureDerate(d.panelTemp!);
        performanceRatio = expected > 0 ? d.power / expected : null;

        if (performanceRatio != null) {
          final perfCritical = performanceRatio < 0.30;
          final perfHigh = !perfCritical && performanceRatio < 0.50;
          final perfMedium =
              !perfCritical && !perfHigh && performanceRatio < 0.75;
          if (_trip('PERF-001', perfCritical)) {
            faults.add(const FaultCode(
              code: 'PERF-001',
              domain: FaultDomain.performance,
              severity: FaultSeverity.critical,
              title: 'Output far below expectation',
              cause: 'Multiple module failure, major shading, or string '
                  'disconnection.',
              action: 'Measure each string individually at the combiner box.',
            ));
          } else if (_trip('PERF-002', perfHigh)) {
            faults.add(const FaultCode(
              code: 'PERF-002',
              domain: FaultDomain.performance,
              severity: FaultSeverity.high,
              title: 'Output substantially below expectation',
              cause: 'Partial shading, heavy soiling, or one failed module.',
              action: 'Clean the array and compare string currents.',
            ));
          } else if (_trip('PERF-003', perfMedium)) {
            faults.add(const FaultCode(
              code: 'PERF-003',
              domain: FaultDomain.performance,
              severity: FaultSeverity.medium,
              title: 'Output moderately below expectation',
              cause: 'Soiling, mild shading, or gradual degradation.',
              action: 'Clean the modules and re-check. Log the reading to '
                  'track the trend.',
            ));
          }
        }
      }
    } else {
      // Night: clear all daylight-only streaks so nothing carries over.
      for (final c in const [
        'PV-001', 'PV-002', 'CURR-001', 'PERF-001', 'PERF-002', 'PERF-003'
      ]) {
        _clear(c);
      }
    }

    // ------------------------------------------------------------- battery
    // Always active, but gated on low load current so that voltage sag under
    // a heavy inverter draw is not misread as deep discharge.
    if (d.batteryVoltage > 0.5 * config.seriesBlocks) {
      final underHeavyLoad = d.current.abs() > t.arrayIsc * 0.6;
      final deepDischarge =
          d.batteryVoltage < t.batteryCritical && !underHeavyLoad;
      final lowCharge = !deepDischarge &&
          d.batteryVoltage < t.batteryLow &&
          !underHeavyLoad;

      if (_trip('BATT-002', deepDischarge)) {
        faults.add(const FaultCode(
          code: 'BATT-002',
          domain: FaultDomain.battery,
          severity: FaultSeverity.critical,
          title: 'Battery deeply discharged',
          cause: 'Sustained deficit between generation and consumption, or a '
              'failed cell.',
          action: 'Reduce load immediately and allow a full recharge. Repeated '
              'deep discharge permanently reduces capacity.',
        ));
      } else if (_trip('BATT-001', lowCharge)) {
        faults.add(const FaultCode(
          code: 'BATT-001',
          domain: FaultDomain.battery,
          severity: FaultSeverity.medium,
          title: 'Battery state of charge low',
          cause: 'Consumption exceeding generation, or several overcast days.',
          action: 'Shed non-essential loads until the bank recovers.',
        ));
      }

      if (_trip('BATT-003', d.batteryVoltage > t.batteryOvercharge)) {
        faults.add(const FaultCode(
          code: 'BATT-003',
          domain: FaultDomain.battery,
          severity: FaultSeverity.high,
          title: 'Battery overcharging',
          cause: 'Charge controller not regulating, or set for the wrong '
              'battery chemistry.',
          action: 'Check the controller battery-type setting immediately. '
              'Overcharging boils electrolyte and destroys plates.',
        ));
      }
    }

    // --------------------------------------------------------- temperature
    // Absolute thresholds, so these need only the panel probe — they survive a
    // missing ambient probe and stay active at night (a module cooking after
    // dark is a genuine finding). Suppressed entirely if the panel probe itself
    // is absent, since there is nothing to compare.
    final panelTempCrit =
        d.hasPanelTemp && d.panelTemp! > t.tempCritical;
    final panelTempHot =
        d.hasPanelTemp && !panelTempCrit && d.panelTemp! > t.tempHigh;
    if (_trip('TEMP-001', panelTempCrit)) {
      faults.add(const FaultCode(
        code: 'TEMP-001',
        domain: FaultDomain.temperature,
        severity: FaultSeverity.critical,
        title: 'Panel temperature critical',
        cause: 'Cell hotspot, bypass diode failure, or a severely obstructed '
            'mounting with no airflow.',
        action: 'Inspect for hotspots. A failed bypass diode allows shaded '
            'cells to dissipate the full string current as heat and is a fire '
            'risk.',
      ));
    } else if (_trip('TEMP-002', panelTempHot)) {
      faults.add(const FaultCode(
        code: 'TEMP-002',
        domain: FaultDomain.temperature,
        severity: FaultSeverity.medium,
        title: 'Panel temperature high',
        cause: 'Insufficient ventilation behind the modules.',
        action: 'Increase the standoff gap. Ventilated mounting recovers '
            'meaningful output in Lagos conditions.',
      ));
    }

    // ---------------------------------------------------------- scoring
    // Worst fault per domain, not the sum of all faults. See correction 4.
    final domainWorst = <FaultDomain, int>{};
    for (final f in faults) {
      final current = domainWorst[f.domain] ?? 0;
      domainWorst[f.domain] =
          math.max(current, f.severity.deduction);
    }

    var health = 100;
    for (final deduction in domainWorst.values) {
      health -= deduction;
    }
    health = health.clamp(0, 100);

    final domainScores = <FaultDomain, int>{};
    for (final domain in FaultDomain.values) {
      domainScores[domain] = (100 - (domainWorst[domain] ?? 0)).clamp(0, 100);
    }

    return DiagnosisReport(
      faults: faults,
      healthScore: health,
      domainScores: domainScores,
      isDaytime: isDaytime,
      controllerRegulating: controllerRegulating,
      performanceEvaluated: performanceEvaluated,
      performanceRatio: performanceRatio,
      daylightDetermined: daylightDetermined,
      panelTempAvailable: d.hasPanelTemp,
      ambientTempAvailable: d.hasAmbientTemp,
      summary: _summarise(
        faults: faults,
        health: health,
        isDaytime: isDaytime,
        regulating: controllerRegulating,
        perfEvaluated: performanceEvaluated,
        daylightDetermined: daylightDetermined,
        panelTempAvailable: d.hasPanelTemp,
        ambientTempAvailable: d.hasAmbientTemp,
      ),
    );
  }

  /// Increment the streak for [code] and report whether it has persisted long
  /// enough to raise. Resets when the condition clears.
  bool _trip(String code, bool condition) {
    if (!condition) {
      _streaks[code] = 0;
      return false;
    }
    final n = (_streaks[code] ?? 0) + 1;
    _streaks[code] = n;
    return n >= debounceCount;
  }

  void _clear(String code) => _streaks[code] = 0;

  /// Reset all streaks, e.g. on reconnecting to a different device.
  void reset() => _streaks.clear();

  String _summarise({
    required List<FaultCode> faults,
    required int health,
    required bool isDaytime,
    required bool regulating,
    required bool perfEvaluated,
    required bool daylightDetermined,
    required bool panelTempAvailable,
    required bool ambientTempAvailable,
  }) {
    // Degraded sensing is reported before anything else, and never as "no
    // faults detected" — the panel, current and performance domains were not
    // examined at all, so silence about them is absence of evidence.
    if (!daylightDetermined) {
      final missing = !panelTempAvailable && !ambientTempAvailable
          ? 'Neither temperature probe is reporting.'
          : !ambientTempAvailable
              ? 'The ambient temperature probe is not reporting.'
              : 'The panel temperature probe is not reporting.';
      return '$missing Panel, current and performance checks are '
          'suppressed — without both temperatures the tool cannot tell whether '
          'the array is in sunlight, and those checks are only valid in '
          'daylight. Battery and panel-temperature checks are unaffected. '
          '${faults.isEmpty ? 'No faults found in the domains still covered' : '${faults.length} fault(s) found in the domains still covered'}; '
          'this is a partial assessment, not a clean bill of health.';
    }

    if (faults.isEmpty) {
      if (!isDaytime) {
        return 'No faults detected. Panel checks are inactive — the array is '
            'not in sunlight, which is normal at night and under heavy cloud.';
      }
      if (regulating) {
        return 'No faults detected. The battery is full and the charge '
            'controller is limiting current, so current and performance '
            'checks are paused. This is correct behaviour, not a fault.';
      }
      if (!perfEvaluated) {
        return 'No faults detected. Irradiance is too low for a meaningful '
            'performance comparison; the array is being monitored but not '
            'scored.';
      }
      return 'No faults detected. All domains reporting normal.';
    }

    final worst = faults.reduce((a, b) =>
        a.severity.deduction >= b.severity.deduction ? a : b);
    return '${faults.length} fault(s) detected. Most severe: '
        '${worst.code} — ${worst.title}. System health $health%.';
  }
}
