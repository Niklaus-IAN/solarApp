import '../data/derating.dart';
import 'enums.dart';
import 'panel_spec.dart';

/// A single sized cable run.
class CableRun {
  final String label;
  final double amps;
  final double volts;
  final double lengthM;

  /// Size demanded by the voltage-drop budget alone, mm^2.
  final double byVoltageDropMm2;

  /// Size demanded by current-carrying capacity alone, mm^2.
  final double byAmpacityMm2;

  /// The one to buy: the larger of the two, rounded up to standard.
  final double selectedMm2;

  /// Share of the total drop budget allocated to this run, fraction.
  final double dropBudget;

  /// Actual drop achieved with the selected conductor, fraction.
  final double actualDrop;

  final bool isDc;

  const CableRun({
    required this.label,
    required this.amps,
    required this.volts,
    required this.lengthM,
    required this.byVoltageDropMm2,
    required this.byAmpacityMm2,
    required this.selectedMm2,
    required this.dropBudget,
    required this.actualDrop,
    required this.isDc,
  });

  /// True when ampacity, not voltage drop, set the size. Common on short runs
  /// and the reason a drop-only calculation is unsafe.
  bool get ampacityGoverned => byAmpacityMm2 >= byVoltageDropMm2;

  String get rationale => ampacityGoverned
      ? 'Sized by current-carrying capacity (${amps.toStringAsFixed(0)} A); '
          'voltage drop alone would have allowed '
          '${byVoltageDropMm2.toStringAsFixed(1)} mm2'
      : 'Sized by voltage drop over ${lengthM.toStringAsFixed(0)} m at '
          '${amps.toStringAsFixed(0)} A';
}

/// Overcurrent, surge and isolation devices.
class ProtectionSpec {
  /// Per-string PV fuse, A. Null when fewer than three parallel strings.
  final int? pvStringFuseA;

  /// Array combiner output breaker, A, and its DC voltage class.
  final int arrayBreakerA;
  final int arrayBreakerVdc;

  final int controllerBreakerA;
  final int batteryBreakerA;
  final int batteryIsolatorA;

  final int acBreakerA;
  final int rcdMilliamps;

  final int dcSpdVdc;
  final int dcSpdKa;
  final int acSpdVac;
  final int acSpdKa;

  final double earthCableMm2;
  final int earthRodCount;

  const ProtectionSpec({
    required this.pvStringFuseA,
    required this.arrayBreakerA,
    required this.arrayBreakerVdc,
    required this.controllerBreakerA,
    required this.batteryBreakerA,
    required this.batteryIsolatorA,
    required this.acBreakerA,
    required this.rcdMilliamps,
    required this.dcSpdVdc,
    required this.dcSpdKa,
    required this.acSpdVac,
    required this.acSpdKa,
    required this.earthCableMm2,
    required this.earthRodCount,
  });

  /// Protection chain as text, for the results screen.
  static const List<String> chain = [
    'PV array  ->  DC isolator  ->  string fuses + DC SPD  ->  DC breaker  ->  controller',
    'Battery bank  ->  battery fuse/breaker  ->  battery isolator  ->  inverter',
    'Inverter  ->  AC SPD  ->  AC MCB + RCD  ->  distribution board',
    'All frames, rails, chassis and SPDs  ->  earth rod',
  ];
}

/// A non-blocking design advisory.
class SizingWarning {
  final WarningLevel level;
  final String title;
  final String detail;
  final String? action;

  const SizingWarning(this.level, this.title, this.detail, {this.action});
}

/// Itemised cost estimate, naira.
class CostEstimate {
  final double panels;
  final double batteries;
  final double inverter;
  final double controller;
  final double cabling;
  final double protection;
  final double mounting;
  final double labour;

  const CostEstimate({
    required this.panels,
    required this.batteries,
    required this.inverter,
    required this.controller,
    required this.cabling,
    required this.protection,
    required this.mounting,
    required this.labour,
  });

  double get total =>
      panels + batteries + inverter + controller + cabling + protection +
      mounting + labour;

  Map<String, double> get lines => {
        'Panels': panels,
        'Batteries': batteries,
        'Inverter': inverter,
        'Charge controller': controller,
        'Cabling': cabling,
        'Protection devices': protection,
        'Mounting': mounting,
        'Installation': labour,
      };
}

/// Complete output of a sizing run.
class SizingResult {
  // ------------------------------------------------------------ Step 1: load
  /// Energy at the appliance terminals, AC loads, Wh/day.
  final double acLoadWh;

  /// Energy at the appliance terminals, DC loads, Wh/day.
  final double dcLoadWh;

  /// Total at the terminals, Wh/day.
  final double totalLoadWh;

  /// Energy that must leave the battery, inverter losses included for AC
  /// loads only, Wh/day.
  final double busEnergyWh;

  /// Simultaneous running power, W.
  final double runningLoadW;

  /// Running load plus the largest single motor surge, W.
  final double requiredSurgeW;

  final String? largestMotorName;

  // ------------------------------------------------- Step 2/3: losses and sun
  final double designPsh;
  final String designMonth;
  final double annualAveragePsh;
  final double arrayDerateFactor;

  /// Panel generation factor: design PSH x array derate.
  final double panelGenerationFactor;

  final double balanceOfSystemFactor;
  final double totalSystemFactor;
  final List<DerateLine> derateBreakdown;

  // ----------------------------------------------------------- Step 4: array
  final double requiredGenerationWh;
  final double requiredArrayWp;

  /// What the array would have been if sized on the annual average instead of
  /// the design month. Shown side by side so the user sees the cost of
  /// year-round reliability rather than having it imposed silently.
  final double requiredArrayWpAnnualAverage;
  final int panelCount;
  final int panelsInSeries;
  final int parallelStrings;
  final double installedWp;
  final double arrayIsc;
  final double stringVmpp;
  final double stringVocCold;
  final double arrayAreaM2;
  final PanelSpec panel;

  // --------------------------------------------------------- Step 5: battery
  final int systemVoltage;
  final bool systemVoltageWasRecommended;
  final double requiredBatteryAh;
  final int batteryCount;
  final int batteriesInSeries;
  final int batteryParallelStrings;
  final double installedBatteryAh;
  final double usableStorageWh;
  final BatteryChemistry chemistry;
  final double autonomyDays;

  // -------------------------------------------------------- Step 6: inverter
  final double inverterMinimumW;
  final int inverterW;
  final double inverterRequiredSurgeW;

  // ------------------------------------------------------ Step 7: controller
  final ControllerType controllerType;
  final double controllerRawA;
  final int controllerA;

  /// Number of controllers in parallel. Greater than one when a single unit
  /// cannot carry the array current.
  final int controllerCount;

  final int controllerMinVocRating;

  // ---------------------------------------------------------- Step 8/9: BOS
  final List<CableRun> cableRuns;
  final ProtectionSpec protection;

  // ----------------------------------------------------------- Step 10/11
  final List<SizingWarning> warnings;
  final CostEstimate cost;
  final Map<String, String> rationale;

  const SizingResult({
    required this.acLoadWh,
    required this.dcLoadWh,
    required this.totalLoadWh,
    required this.busEnergyWh,
    required this.runningLoadW,
    required this.requiredSurgeW,
    required this.largestMotorName,
    required this.designPsh,
    required this.designMonth,
    required this.annualAveragePsh,
    required this.arrayDerateFactor,
    required this.panelGenerationFactor,
    required this.balanceOfSystemFactor,
    required this.totalSystemFactor,
    required this.derateBreakdown,
    required this.requiredGenerationWh,
    required this.requiredArrayWp,
    required this.requiredArrayWpAnnualAverage,
    required this.panelCount,
    required this.panelsInSeries,
    required this.parallelStrings,
    required this.installedWp,
    required this.arrayIsc,
    required this.stringVmpp,
    required this.stringVocCold,
    required this.arrayAreaM2,
    required this.panel,
    required this.systemVoltage,
    required this.systemVoltageWasRecommended,
    required this.requiredBatteryAh,
    required this.batteryCount,
    required this.batteriesInSeries,
    required this.batteryParallelStrings,
    required this.installedBatteryAh,
    required this.usableStorageWh,
    required this.chemistry,
    required this.autonomyDays,
    required this.inverterMinimumW,
    required this.inverterW,
    required this.inverterRequiredSurgeW,
    required this.controllerType,
    required this.controllerRawA,
    required this.controllerA,
    required this.controllerCount,
    required this.controllerMinVocRating,
    required this.cableRuns,
    required this.protection,
    required this.warnings,
    required this.cost,
    required this.rationale,
  });

  bool get hasCriticalWarnings =>
      warnings.any((w) => w.level == WarningLevel.critical);

  /// Estimated generation on a design-month day, Wh.
  double get estimatedDailyGenerationWh =>
      installedWp * designPsh * arrayDerateFactor;

  /// Extra capacity bought by designing on the worst month rather than the
  /// annual average, as a percentage.
  double get worstMonthPremiumPercent =>
      (requiredArrayWp / requiredArrayWpAnnualAverage - 1) * 100;

  /// Headroom of installed capacity over the calculated requirement.
  double get arrayOversizePercent =>
      (installedWp / requiredArrayWp - 1) * 100;
}
