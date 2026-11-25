import 'enums.dart';

/// A single load line in the user's appliance list.
///
/// Four fields beyond the obvious ones, each fixing a specific failure mode:
///
///  * [dutyCycle]  — a fridge is plugged in 24 h but its compressor runs about
///    half that. LEONICS enters the worked example as `75 W x 24 x 0.5`.
///    Without this the user types 24 hours and the whole system triples.
///  * [loadType]   — DC loads bypass the inverter entirely. CED R08-002
///    §8.4.1 divides only AC loads by inverter efficiency.
///  * [surgeFactor]— motors draw 3-7x rated for 1-3 s on start. LEONICS
///    requires a minimum of 3x for motor/compressor loads.
///  * [simultaneous] — summing every appliance as concurrent oversizes the
///    inverter badly. Let the user exclude loads that never coincide.
class Appliance {
  final String id;
  final String name;

  /// Nameplate rating of ONE unit, in watts.
  final double watts;

  final int quantity;

  /// Hours per day the appliance is switched on / plugged in.
  final double hoursPerDay;

  /// Fraction of [hoursPerDay] during which it actually draws [watts].
  /// 1.0 for resistive/continuous loads, ~0.5-0.65 for compressor loads.
  final double dutyCycle;

  final LoadType loadType;

  /// Counts toward the simultaneous running load that sizes the inverter.
  final bool simultaneous;

  /// Startup surge multiple. 1.0 = no surge, 3.0 fridge, 4.0 A/C, 6.0 pump.
  final double surgeFactor;

  /// User can mark loads as optional to re-run a cheaper design.
  final bool essential;

  const Appliance({
    required this.id,
    required this.name,
    required this.watts,
    required this.hoursPerDay,
    this.quantity = 1,
    this.dutyCycle = 1.0,
    this.loadType = LoadType.ac,
    this.simultaneous = true,
    this.surgeFactor = 1.0,
    this.essential = true,
  });

  /// Energy at the appliance terminals, Wh/day. No efficiency applied here —
  /// the service adds the inverter adjustment for AC loads only.
  double get dailyWh => watts * quantity * hoursPerDay * dutyCycle;

  /// Simultaneous running power, W.
  double get runningW => watts * quantity;

  /// Peak instantaneous power at startup, W.
  double get surgeW => watts * quantity * surgeFactor;

  /// Surge above the running figure — this is what gets added to the
  /// total running load, not the full surge.
  double get surgeExtraW => surgeW - runningW;

  bool get isMotorLoad => surgeFactor > 1.0;

  /// Effective hours, for display. Matches the appliance-table convention
  /// ("Refrigerator/Freezer 20cf 1.8 kWh per day (15 hours)").
  double get effectiveHours => hoursPerDay * dutyCycle;

  Appliance copyWith({
    String? name,
    double? watts,
    int? quantity,
    double? hoursPerDay,
    double? dutyCycle,
    LoadType? loadType,
    bool? simultaneous,
    double? surgeFactor,
    bool? essential,
  }) {
    return Appliance(
      id: id,
      name: name ?? this.name,
      watts: watts ?? this.watts,
      quantity: quantity ?? this.quantity,
      hoursPerDay: hoursPerDay ?? this.hoursPerDay,
      dutyCycle: dutyCycle ?? this.dutyCycle,
      loadType: loadType ?? this.loadType,
      simultaneous: simultaneous ?? this.simultaneous,
      surgeFactor: surgeFactor ?? this.surgeFactor,
      essential: essential ?? this.essential,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'watts': watts,
        'quantity': quantity,
        'hoursPerDay': hoursPerDay,
        'dutyCycle': dutyCycle,
        'loadType': loadType.name,
        'simultaneous': simultaneous,
        'surgeFactor': surgeFactor,
        'essential': essential,
      };

  factory Appliance.fromJson(Map<String, dynamic> j) => Appliance(
        id: j['id'] as String,
        name: j['name'] as String,
        watts: (j['watts'] as num).toDouble(),
        quantity: (j['quantity'] as num?)?.toInt() ?? 1,
        hoursPerDay: (j['hoursPerDay'] as num).toDouble(),
        dutyCycle: (j['dutyCycle'] as num?)?.toDouble() ?? 1.0,
        loadType: LoadType.values.byName(j['loadType'] as String? ?? 'ac'),
        simultaneous: j['simultaneous'] as bool? ?? true,
        surgeFactor: (j['surgeFactor'] as num?)?.toDouble() ?? 1.0,
        essential: j['essential'] as bool? ?? true,
      );
}

/// One selectable size within a stepped preset family.
///
/// The label is what the user recognises on the nameplate, which is not always
/// a wattage: fans step in watts, televisions in screen diagonal, air
/// conditioners in horsepower. Keeping label and watts separate means the
/// picker can say `55"` while the engine still receives 100 W.
class ApplianceStep {
  final String label;
  final double watts;

  const ApplianceStep(this.label, this.watts);
}

/// Library entry the user picks from.
///
/// Two shapes:
///
///  * The plain constructor is a single appliance with a wattage range;
///    [typicalWatts] is the midpoint. This is how all the CED R08-002 entries
///    are written and none of them changed.
///  * [AppliancePreset.stepped] is a *family* — one entry standing for a
///    ladder of discrete market sizes. The picker shows one chip for the
///    family and opens a sheet of [steps], instead of one chip per size.
///    Without this a 12-step standing-fan ladder is twelve near-identical
///    chips in the Cooling category.
class AppliancePreset {
  final String name;
  final String category;
  final double _minW;
  final double _maxW;

  /// Discrete sizes. Empty for a plain (non-stepped) preset.
  final List<ApplianceStep> steps;

  /// Which step the sheet preselects — the size most people actually own.
  final int defaultStepIndex;

  final double dutyCycle;
  final double surgeFactor;
  final LoadType loadType;
  final double defaultHours;

  const AppliancePreset(
    this.name,
    this.category,
    double minWatts,
    double maxWatts, {
    this.dutyCycle = 1.0,
    this.surgeFactor = 1.0,
    this.loadType = LoadType.ac,
    this.defaultHours = 4,
  })  : _minW = minWatts,
        _maxW = maxWatts,
        steps = const [],
        defaultStepIndex = 0;

  const AppliancePreset.stepped(
    this.name,
    this.category,
    this.steps, {
    this.defaultStepIndex = 0,
    this.dutyCycle = 1.0,
    this.surgeFactor = 1.0,
    this.loadType = LoadType.ac,
    this.defaultHours = 4,
  })  : _minW = 0,
        _maxW = 0;

  bool get isStepped => steps.isNotEmpty;

  double get minWatts => isStepped
      ? steps.map((s) => s.watts).reduce((a, b) => a < b ? a : b)
      : _minW;

  double get maxWatts => isStepped
      ? steps.map((s) => s.watts).reduce((a, b) => a > b ? a : b)
      : _maxW;

  /// Default step for a family, midpoint of the range otherwise.
  double get typicalWatts =>
      isStepped ? steps[_safeIndex].watts : (_minW + _maxW) / 2;

  ApplianceStep? get defaultStep => isStepped ? steps[_safeIndex] : null;

  int get _safeIndex =>
      defaultStepIndex >= 0 && defaultStepIndex < steps.length
          ? defaultStepIndex
          : 0;

  bool get isRange => !isStepped && _maxW > _minW;

  /// Build a load line. [stepLabel] is appended to the name so the load list
  /// and the exported bill of materials both say which size was chosen.
  Appliance toAppliance(
    String id, {
    double? watts,
    int quantity = 1,
    double? hours,
    String? stepLabel,
  }) {
    return Appliance(
      id: id,
      name: stepLabel == null ? name : '$name $stepLabel',
      watts: watts ?? typicalWatts,
      quantity: quantity,
      hoursPerDay: hours ?? defaultHours,
      dutyCycle: dutyCycle,
      loadType: loadType,
      surgeFactor: surgeFactor,
    );
  }
}
