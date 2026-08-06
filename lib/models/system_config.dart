import 'enums.dart';
import 'panel_spec.dart';
import 'sizing_result.dart';

/// The single source of truth about the installed system, shared by the sizing
/// calculator and the fault diagnosis engine.
///
/// WHY THIS EXISTS
/// Before this class, the sizer supported 12/24/48 V and both chemistries
/// while the fault engine was hardcoded to a 300 W panel on a 12 V lead-acid
/// bank. On a 24 V LiFePO4 system every battery threshold in the diagnosis
/// service was simply wrong, and the panel reference values described a
/// 36-cell 12 V-class module rather than the 60-cell 300 W module the sizer
/// assumed.
///
/// Persist one of these after a sizing run and have the diagnosis service read
/// its thresholds from it. This is also what turns two separate features into
/// one integrated platform, which is the claim Chapter 2 makes about the
/// integration gap in existing tools.
class SystemConfig {
  final PanelSpec panel;
  final int panelCount;
  final int panelsInSeries;
  final int parallelStrings;
  final int systemVoltage;
  final BatteryChemistry chemistry;
  final double batteryBankAh;
  final int inverterW;
  final int controllerA;
  final ControllerType controllerType;

  /// Commissioning date. Used to decay the expected-output baseline in the
  /// performance checks — CED R08-002 §2.4.1 gives 0.7-1% per year.
  final DateTime? commissionedOn;

  /// Design ambient temperature at the site, degC.
  final double designAmbientC;

  const SystemConfig({
    required this.panel,
    required this.panelCount,
    required this.panelsInSeries,
    required this.parallelStrings,
    required this.systemVoltage,
    required this.chemistry,
    required this.batteryBankAh,
    required this.inverterW,
    required this.controllerA,
    required this.controllerType,
    this.commissionedOn,
    this.designAmbientC = 32,
  });

  /// Build the config from a sizing run, so the monitoring side inherits the
  /// design assumptions automatically.
  factory SystemConfig.fromSizingResult(SizingResult r,
      {DateTime? commissionedOn}) {
    return SystemConfig(
      panel: r.panel,
      panelCount: r.panelCount,
      panelsInSeries: r.panelsInSeries,
      parallelStrings: r.parallelStrings,
      systemVoltage: r.systemVoltage,
      chemistry: r.chemistry,
      batteryBankAh: r.installedBatteryAh,
      inverterW: r.inverterW,
      controllerA: r.controllerA,
      controllerType: r.controllerType,
      commissionedOn: commissionedOn ?? DateTime.now(),
    );
  }

  /// Number of 12 V blocks in series.
  int get seriesBlocks => (systemVoltage / 12).round().clamp(1, 8);

  /// Rated array power at STC, W.
  double get arrayWp => panelCount * panel.watts;

  /// Years in service.
  double get ageYears {
    if (commissionedOn == null) return 0;
    return DateTime.now().difference(commissionedOn!).inDays / 365.25;
  }

  /// Degradation factor from age. CED R08-002 §2.4.1: 0.7-1% per year.
  double get degradationFactor =>
      (1 - 0.008 * ageYears).clamp(0.70, 1.0);

  /// Array power the panels should still be capable of, allowing for age.
  double get arrayWpAged => arrayWp * degradationFactor;

  DiagnosticThresholds get thresholds => DiagnosticThresholds.forConfig(this);

  Map<String, dynamic> toJson() => {
        'panel': panel.toJson(),
        'panelCount': panelCount,
        'panelsInSeries': panelsInSeries,
        'parallelStrings': parallelStrings,
        'systemVoltage': systemVoltage,
        'chemistry': chemistry.name,
        'batteryBankAh': batteryBankAh,
        'inverterW': inverterW,
        'controllerA': controllerA,
        'controllerType': controllerType.name,
        'commissionedOn': commissionedOn?.toIso8601String(),
        'designAmbientC': designAmbientC,
      };

  factory SystemConfig.fromJson(Map<String, dynamic> j) => SystemConfig(
        panel: PanelSpec.fromJson(j['panel'] as Map<String, dynamic>),
        panelCount: (j['panelCount'] as num).toInt(),
        panelsInSeries: (j['panelsInSeries'] as num).toInt(),
        parallelStrings: (j['parallelStrings'] as num).toInt(),
        systemVoltage: (j['systemVoltage'] as num).toInt(),
        chemistry: BatteryChemistry.values.byName(j['chemistry'] as String),
        batteryBankAh: (j['batteryBankAh'] as num).toDouble(),
        inverterW: (j['inverterW'] as num).toInt(),
        controllerA: (j['controllerA'] as num).toInt(),
        controllerType: ControllerType.values.byName(j['controllerType'] as String),
        commissionedOn: j['commissionedOn'] == null
            ? null
            : DateTime.parse(j['commissionedOn'] as String),
        designAmbientC: (j['designAmbientC'] as num?)?.toDouble() ?? 32,
      );
}

/// Every threshold the fault engine needs, derived from the actual system
/// rather than hardcoded for one configuration.
class DiagnosticThresholds {
  // -------------------------------------------------------------- battery, V
  final double batteryLow;
  final double batteryCritical;
  final double batteryOvercharge;

  /// Above this the controller is in absorption or float and is deliberately
  /// throttling current. Current-starvation and performance checks must be
  /// suppressed here or a healthy system reports faults every sunny afternoon.
  final double absorptionThreshold;

  // ---------------------------------------------------------------- panel, V
  final double arrayVoc;
  final double arrayVmpp;
  final double arrayIsc;
  final double arrayRatedW;

  // ----------------------------------------------------------- temperature, C
  final double tempHigh;
  final double tempCritical;

  /// Panel-above-ambient rise that indicates the sun is actually on the array.
  final double daylightDeltaT;

  /// Panel-above-ambient rise indicating irradiance high enough for the
  /// performance ratio to mean anything.
  final double performanceDeltaT;

  const DiagnosticThresholds({
    required this.batteryLow,
    required this.batteryCritical,
    required this.batteryOvercharge,
    required this.absorptionThreshold,
    required this.arrayVoc,
    required this.arrayVmpp,
    required this.arrayIsc,
    required this.arrayRatedW,
    required this.tempHigh,
    required this.tempCritical,
    required this.daylightDeltaT,
    required this.performanceDeltaT,
  });

  factory DiagnosticThresholds.forConfig(SystemConfig c) {
    final blocks = c.seriesBlocks;
    final isLithium = c.chemistry == BatteryChemistry.lithium;

    return DiagnosticThresholds(
      // Per-12V-block figures scaled to the bus voltage.
      // LiFePO4 sits on a much flatter curve than lead-acid and its useful
      // thresholds are entirely different numbers.
      batteryLow: (isLithium ? 12.8 : 12.2) * blocks,
      batteryCritical: (isLithium ? 12.0 : 11.5) * blocks,
      batteryOvercharge: (isLithium ? 14.6 : 14.8) * blocks,
      absorptionThreshold: (isLithium ? 13.9 : 13.8) * blocks,

      // Array electrical references from the real module spec.
      arrayVoc: c.panel.voc * c.panelsInSeries,
      arrayVmpp: c.panel.vmpp * c.panelsInSeries,
      arrayIsc: c.panel.isc * c.parallelStrings,
      arrayRatedW: c.arrayWpAged,

      // Thermal thresholds from the project's ANSYS work.
      tempHigh: 70,
      tempCritical: 85,

      // Daylight gate: a disconnected panel still heats in the sun, so
      // temperature alone is a valid daylight signal and — unlike voltage —
      // does not make the dead-panel fault unreachable.
      daylightDeltaT: 3.0,
      performanceDeltaT: 15.0,
    );
  }
}
