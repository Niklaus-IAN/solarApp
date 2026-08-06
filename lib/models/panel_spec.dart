/// Electrical and physical specification of one PV module.
///
/// Replaces the old wattage-to-voltage lookup (`300W -> 18V`), which was a
/// guess. Every value here comes off a datasheet.
///
/// Note on cold-temperature Voc: string open-circuit voltage rises as cells
/// get cold, and it is the figure that must stay below the controller's
/// maximum PV input. The 1.12 multiplier is the correction used in the
/// Port Harcourt field guide.
class PanelSpec {
  final String name;

  /// Pmax at STC, W.
  final double watts;

  /// Voltage at maximum power point, V.
  final double vmpp;

  /// Current at maximum power point, A.
  final double impp;

  /// Open-circuit voltage at STC, V.
  final double voc;

  /// Short-circuit current at STC, A.
  final double isc;

  /// Power temperature coefficient, %/degC. Negative.
  /// Default -0.45 confirmed by the project's own MATLAB single-diode
  /// simulation and by Skoplaki & Palyvos (2009).
  final double powerTempCoeffPct;

  /// Nominal operating cell temperature, degC. Used by the NOCT method to
  /// estimate cell temperature from ambient.
  final double noct;

  /// Module area, m^2. For the roof-fit check.
  final double areaM2;

  /// Manufacturer power tolerance, fraction. CED R08-002 §1.4 recommends
  /// sizing on the low end of the tolerance band.
  final double tolerance;

  const PanelSpec({
    required this.name,
    required this.watts,
    required this.vmpp,
    required this.impp,
    required this.voc,
    required this.isc,
    required this.areaM2,
    this.powerTempCoeffPct = -0.45,
    this.noct = 45.0,
    this.tolerance = 0.03,
  });

  /// Worst-case open-circuit voltage in cold conditions, V.
  double get vocCold => voc * 1.12;

  /// Conservative rating using the low end of the tolerance band.
  double get wattsConservative => watts * (1 - tolerance);

  /// Module conversion efficiency at STC, fraction.
  double get efficiency => watts / (areaM2 * 1000);

  /// Estimated cell temperature by the NOCT method.
  ///
  ///   T_cell = T_ambient + (NOCT - 20) * (G / 800)
  ///
  /// At Lagos conditions (32 degC ambient, 1000 W/m^2) a NOCT-45 module
  /// reaches roughly 63 degC, not the 25 degC of the STC rating.
  double cellTemperature({required double ambientC, double irradiance = 1000}) {
    return ambientC + (noct - 20) * (irradiance / 800);
  }

  /// Fractional power retained at a given cell temperature.
  double temperatureDerate(double cellTempC) {
    return 1 + (powerTempCoeffPct / 100) * (cellTempC - 25);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'watts': watts,
        'vmpp': vmpp,
        'impp': impp,
        'voc': voc,
        'isc': isc,
        'areaM2': areaM2,
        'powerTempCoeffPct': powerTempCoeffPct,
        'noct': noct,
        'tolerance': tolerance,
      };

  factory PanelSpec.fromJson(Map<String, dynamic> j) => PanelSpec(
        name: j['name'] as String,
        watts: (j['watts'] as num).toDouble(),
        vmpp: (j['vmpp'] as num).toDouble(),
        impp: (j['impp'] as num).toDouble(),
        voc: (j['voc'] as num).toDouble(),
        isc: (j['isc'] as num).toDouble(),
        areaM2: (j['areaM2'] as num).toDouble(),
        powerTempCoeffPct: (j['powerTempCoeffPct'] as num?)?.toDouble() ?? -0.45,
        noct: (j['noct'] as num?)?.toDouble() ?? 45.0,
        tolerance: (j['tolerance'] as num?)?.toDouble() ?? 0.03,
      );
}

/// Representative modules available in the Nigerian market.
///
/// IMPORTANT: verify these against the datasheet of whichever module you cite
/// in Chapter 3 before submission. A 60-cell 300 W mono is ~39 V Voc, NOT the
/// 21.5 V currently in Table 3.5 — that figure describes a 36-cell 12 V-class
/// panel and is the source of the mismatch between the sizer and the fault
/// engine.
const Map<String, PanelSpec> panelPresets = {
  '150W Mono (36-cell, 12V class)': PanelSpec(
    name: '150W Mono (36-cell)',
    watts: 150, vmpp: 18.0, impp: 8.33, voc: 21.5, isc: 8.85, areaM2: 1.01,
  ),
  '300W Mono (60-cell)': PanelSpec(
    name: '300W Mono (60-cell)',
    watts: 300, vmpp: 32.5, impp: 9.23, voc: 39.5, isc: 9.80, areaM2: 1.64,
  ),
  '350W Mono (72-cell)': PanelSpec(
    name: '350W Mono (72-cell)',
    watts: 350, vmpp: 38.5, impp: 9.09, voc: 46.8, isc: 9.65, areaM2: 1.94,
  ),
  '400W Mono (72-cell)': PanelSpec(
    name: '400W Mono (72-cell)',
    watts: 400, vmpp: 37.0, impp: 10.81, voc: 45.2, isc: 11.40, areaM2: 1.95,
  ),
  '550W Mono (144 half-cell)': PanelSpec(
    name: '550W Mono (144 half-cell)',
    watts: 550, vmpp: 41.5, impp: 13.26, voc: 49.8, isc: 14.00, areaM2: 2.58,
  ),
  '330W Poly (72-cell)': PanelSpec(
    name: '330W Poly (72-cell)',
    watts: 330, vmpp: 37.2, impp: 8.87, voc: 45.9, isc: 9.35, areaM2: 1.94,
    powerTempCoeffPct: -0.41,
  ),
};

PanelSpec get defaultPanel => panelPresets['300W Mono (60-cell)']!;
