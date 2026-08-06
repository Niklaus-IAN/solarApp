import '../data/derating.dart';
import '../data/standard_sizes.dart';
import 'appliance.dart';
import 'enums.dart';
import 'panel_spec.dart';

/// Everything the sizing engine needs. Anything not supplied falls back to a
/// documented default so the calculator still runs from a bare appliance list.
class SizingInput {
  final List<Appliance> appliances;

  final String city;
  final PshMode pshMode;

  /// 12, 24 or 48. If null, the service recommends one from daily energy
  /// (CED R08-002 §8.4.1 parameter A2) and uses it.
  final int? systemVoltage;

  final BatteryChemistry chemistry;

  /// Days the bank must carry the load with no PV input.
  /// CED §1.5.2 and §6.4.10: 2-6 days typical for non-critical loads.
  final double autonomyDays;

  final PanelSpec panel;

  /// Nameplate capacity of one battery unit, Ah at 12 V.
  final double batteryUnitAh;

  final ControllerType controllerPreference;

  /// Inverter DC-to-AC conversion efficiency. CED §8.4.1: 0.85-0.90.
  final double inverterEfficiency;

  /// Loss model. Defaults to the CED-derived table with a computed
  /// temperature term.
  final DerateModel derate;

  /// Usable unshaded roof area, m^2. Null skips the fit check.
  final double? availableRoofM2;

  /// One-way cable run lengths, metres.
  final double lenPvToController;
  final double lenControllerToBattery;
  final double lenBatteryToInverter;
  final double lenInverterToBoard;

  /// Design ambient for cable ampacity derating, degC.
  final double cableAmbientC;

  /// Additional load the user expects to add later, Wh/day.
  /// The field guide's Chapter 6 is emphatic that expansion headroom is
  /// decided at design time.
  final double futureLoadWh;

  final UnitCosts costs;

  /// Ignore appliances flagged non-essential. Drives the "what if I drop the
  /// air conditioner" comparison.
  final bool essentialOnly;

  SizingInput({
    required this.appliances,
    this.city = 'Lagos',
    this.pshMode = PshMode.worstMonth,
    this.systemVoltage,
    this.chemistry = BatteryChemistry.lithium,
    this.autonomyDays = 2,
    PanelSpec? panel,
    this.batteryUnitAh = 200,
    this.controllerPreference = ControllerType.auto,
    this.inverterEfficiency = 0.90,
    this.derate = const DerateModel(),
    this.availableRoofM2,
    this.lenPvToController = 12,
    this.lenControllerToBattery = 3,
    this.lenBatteryToInverter = 2,
    this.lenInverterToBoard = 15,
    this.cableAmbientC = 40,
    this.futureLoadWh = 0,
    UnitCosts? costs,
    this.essentialOnly = false,
  })  : panel = panel ?? defaultPanel,
        costs = costs ?? UnitCosts.defaults();

  /// Appliances actually included in this run.
  List<Appliance> get activeAppliances =>
      essentialOnly ? appliances.where((a) => a.essential).toList() : appliances;

  SizingInput copyWith({
    List<Appliance>? appliances,
    String? city,
    PshMode? pshMode,
    int? systemVoltage,
    BatteryChemistry? chemistry,
    double? autonomyDays,
    PanelSpec? panel,
    double? batteryUnitAh,
    ControllerType? controllerPreference,
    double? inverterEfficiency,
    DerateModel? derate,
    double? availableRoofM2,
    double? lenPvToController,
    double? lenControllerToBattery,
    double? lenBatteryToInverter,
    double? lenInverterToBoard,
    double? cableAmbientC,
    double? futureLoadWh,
    UnitCosts? costs,
    bool? essentialOnly,
  }) {
    return SizingInput(
      appliances: appliances ?? this.appliances,
      city: city ?? this.city,
      pshMode: pshMode ?? this.pshMode,
      systemVoltage: systemVoltage ?? this.systemVoltage,
      chemistry: chemistry ?? this.chemistry,
      autonomyDays: autonomyDays ?? this.autonomyDays,
      panel: panel ?? this.panel,
      batteryUnitAh: batteryUnitAh ?? this.batteryUnitAh,
      controllerPreference: controllerPreference ?? this.controllerPreference,
      inverterEfficiency: inverterEfficiency ?? this.inverterEfficiency,
      derate: derate ?? this.derate,
      availableRoofM2: availableRoofM2 ?? this.availableRoofM2,
      lenPvToController: lenPvToController ?? this.lenPvToController,
      lenControllerToBattery:
          lenControllerToBattery ?? this.lenControllerToBattery,
      lenBatteryToInverter: lenBatteryToInverter ?? this.lenBatteryToInverter,
      lenInverterToBoard: lenInverterToBoard ?? this.lenInverterToBoard,
      cableAmbientC: cableAmbientC ?? this.cableAmbientC,
      futureLoadWh: futureLoadWh ?? this.futureLoadWh,
      costs: costs ?? this.costs,
      essentialOnly: essentialOnly ?? this.essentialOnly,
    );
  }
}
