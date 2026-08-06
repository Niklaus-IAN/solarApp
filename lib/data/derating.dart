import '../models/enums.dart';
import '../models/panel_spec.dart';

/// System loss model.
///
/// Structure and factor values follow the itemised de-rating table in
/// CED R08-002 §2.4, which multiplies out to a total system factor of 0.60.
/// Two deliberate departures:
///
///  1. The temperature term is COMPUTED rather than taken as the table's flat
///     0.90. It uses the NOCT method for cell temperature and this project's
///     own MATLAB-derived power coefficient of -0.45 %/degC. This is the one
///     place where the loss model is derived from the project's simulation
///     work rather than borrowed.
///  2. The dirt factor defaults to 0.95 rather than the table's 0.97. CED
///     itself cites 0.93 as a typical annual dust factor in §2.3.1, and West
///     African harmattan is at the harsh end of that range. 0.95 is the
///     midpoint; it is exposed as a parameter so the value can be justified
///     or varied per site.
///
/// The losses are split into two groups, and this split matters:
///
///   ARRAY SIDE  — everything between sunlight and DC power leaving the array.
///                 Divides the peak sun hours to give the Panel Generation
///                 Factor (the LEONICS concept, computed rather than tabulated).
///
///   CONVERSION  — everything between the array output and the load. Inflates
///                 the energy requirement.
///
/// Keeping them separate is what prevents the double-counting that occurs if
/// you apply both LEONICS' flat 1.3 factor and a tabulated PGF.
class DerateModel {
  // ------------------------------------------------------------- array side
  /// Soiling / dust. CED §2.4 gives 0.97; §2.3.1 gives 0.93 for dusty sites.
  final double dirt;

  /// Manufacturer power tolerance. CED §2.4.
  final double manufacturerTolerance;

  /// Shading. CED §2.4.
  final double shading;

  /// Orientation, tilt and azimuth deviation from optimum. CED §2.4.
  final double orientation;

  /// Loss at sub-STC irradiance levels. CED §2.4.
  final double irradianceLevel;

  // -------------------------------------------------------- conversion side
  /// Voltage drop, array to controller/battery. CED §2.4.
  final double pvCable;

  /// Charge controller conversion loss. CED §2.4.
  /// NOTE: absent from the app's original efficiency chain.
  final double chargeController;

  /// Distribution cable, battery to loads. CED §2.4.
  /// NOTE: the original chain counted one cable loss, not two.
  final double distributionCable;

  /// Design ambient temperature, degC, for the NOCT cell-temperature estimate.
  final double designAmbientC;

  const DerateModel({
    this.dirt = 0.95,
    this.manufacturerTolerance = 0.97,
    this.shading = 0.95,
    this.orientation = 0.99,
    this.irradianceLevel = 0.97,
    this.pvCable = 0.98,
    this.chargeController = 0.98,
    this.distributionCable = 0.98,
    this.designAmbientC = 32.0,
  });

  /// Harmattan-heavy northern sites, unshaded rooftop.
  const DerateModel.northernNigeria()
      : dirt = 0.93,
        manufacturerTolerance = 0.97,
        shading = 0.98,
        orientation = 0.99,
        irradianceLevel = 0.97,
        pvCable = 0.98,
        chargeController = 0.98,
        distributionCable = 0.98,
        designAmbientC = 36.0;

  /// The CED table exactly as published, temperature term included as 0.90.
  /// Provided so the report can show the published baseline alongside the
  /// computed version.
  static const double cedPublishedTotal = 0.60;

  /// Cell temperature at design conditions.
  double cellTemperature(PanelSpec panel) =>
      panel.cellTemperature(ambientC: designAmbientC);

  /// Computed temperature derate at design conditions.
  double temperatureFactor(PanelSpec panel) =>
      panel.temperatureDerate(cellTemperature(panel));

  /// Product of all array-side factors. Multiplies PSH to give the PGF.
  double arrayFactor(PanelSpec panel) =>
      temperatureFactor(panel) *
      dirt *
      manufacturerTolerance *
      shading *
      orientation *
      irradianceLevel;

  /// Product of the non-storage conversion factors.
  double _wiringAndController() => pvCable * chargeController * distributionCable;

  /// Balance-of-system factor between the array and the DC bus at the load
  /// side, EXCLUDING the inverter (which is applied per-appliance so that DC
  /// loads are not unfairly penalised — CED §8.4.1).
  double balanceOfSystemFactor(BatteryChemistry chemistry) =>
      _wiringAndController() * chemistry.roundTripEfficiency;

  /// Whole-chain factor including the inverter, for reporting and for
  /// comparison against the CED published total of 0.60.
  double totalSystemFactor(PanelSpec panel, BatteryChemistry chemistry,
      {double inverterEfficiency = 0.90}) {
    return arrayFactor(panel) *
        balanceOfSystemFactor(chemistry) *
        inverterEfficiency;
  }

  /// Itemised breakdown for the results screen and for Chapter 3 Table.
  List<DerateLine> breakdown(PanelSpec panel, BatteryChemistry chemistry,
      {double inverterEfficiency = 0.90}) {
    final t = temperatureFactor(panel);
    return [
      DerateLine('Cell temperature',
          t,
          'NOCT method at ${designAmbientC.toStringAsFixed(0)} degC ambient; '
          'cell ${cellTemperature(panel).toStringAsFixed(1)} degC at '
          '${panel.powerTempCoeffPct}%/degC (MATLAB single-diode)',
          isArraySide: true),
      DerateLine('Soiling / dust', dirt, 'CED R08-002 §2.3.1, §2.4',
          isArraySide: true),
      DerateLine('Manufacturer tolerance', manufacturerTolerance,
          'CED R08-002 §2.4', isArraySide: true),
      DerateLine('Shading', shading, 'CED R08-002 §2.4', isArraySide: true),
      DerateLine('Orientation / tilt', orientation, 'CED R08-002 §2.4',
          isArraySide: true),
      DerateLine('Irradiance level', irradianceLevel, 'CED R08-002 §2.4',
          isArraySide: true),
      DerateLine('PV cable', pvCable, 'CED R08-002 §2.4', isArraySide: false),
      DerateLine('Charge controller', chargeController, 'CED R08-002 §2.4',
          isArraySide: false),
      DerateLine('Battery round trip', chemistry.roundTripEfficiency,
          '${chemistry.label} — CED R08-002 §2.4', isArraySide: false),
      DerateLine('Distribution cable', distributionCable, 'CED R08-002 §2.4',
          isArraySide: false),
      DerateLine('Inverter', inverterEfficiency,
          'Applied to AC loads only — CED R08-002 §8.4.1', isArraySide: false),
    ];
  }

  DerateModel copyWith({
    double? dirt,
    double? shading,
    double? orientation,
    double? designAmbientC,
  }) {
    return DerateModel(
      dirt: dirt ?? this.dirt,
      manufacturerTolerance: manufacturerTolerance,
      shading: shading ?? this.shading,
      orientation: orientation ?? this.orientation,
      irradianceLevel: irradianceLevel,
      pvCable: pvCable,
      chargeController: chargeController,
      distributionCable: distributionCable,
      designAmbientC: designAmbientC ?? this.designAmbientC,
    );
  }
}

class DerateLine {
  final String label;
  final double factor;
  final String source;
  final bool isArraySide;

  const DerateLine(this.label, this.factor, this.source,
      {required this.isArraySide});

  double get lossPercent => (1 - factor) * 100;
}
