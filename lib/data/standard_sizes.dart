/// Standard purchasable sizes for the Nigerian market, plus cable ampacity.
///
/// Every sizing output snaps up to one of these. The round-up-to-standard
/// discipline is what makes the result a buildable bill of materials rather
/// than a set of raw numbers.
library;

/// Inverter continuous ratings, W.
const List<int> standardInverterW = [
  800, 1000, 1500, 2000, 2500, 3000, 3500, 5000, 6000, 8000, 10000, 12000, 15000
];

/// Charge controller current ratings, A.
const List<int> standardControllerA = [
  10, 20, 30, 40, 50, 60, 80, 100, 120, 150, 200
];

/// Controller maximum PV input voltage classes, Vdc.
const List<int> controllerVocClasses = [100, 150, 250, 500];

/// Breaker and fuse ratings, A.
const List<int> standardBreakerA = [
  6, 10, 16, 20, 25, 32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400
];

/// DC-rated breaker/SPD voltage classes, Vdc.
const List<int> dcVoltageClasses = [500, 600, 800, 1000, 1500];

/// Battery unit capacities commonly stocked, Ah at 12 V nominal.
const List<int> standardBatteryAh = [100, 150, 200, 220, 250];

/// Copper conductor cross-sections, mm^2.
const List<double> standardCableMm2 = [
  1.5, 2.5, 4, 6, 10, 16, 25, 35, 50, 70, 95, 120, 150
];

/// Continuous current-carrying capacity of copper conductors, A.
/// Single-core PVC insulated, in conduit, 30 degC ambient.
/// Apply [ambientDerate] for hotter installations.
///
/// Top-level `final` rather than `const`: Dart forbids `double` keys in a
/// const map (double overrides ==/hashCode). Read only at runtime, so this
/// changes nothing about the values or behaviour.
final Map<double, double> cableAmpacity = {
  1.5: 15.0,
  2.5: 21.0,
  4: 28.0,
  6: 36.0,
  10: 50.0,
  16: 68.0,
  25: 89.0,
  35: 110.0,
  50: 134.0,
  70: 171.0,
  95: 207.0,
  120: 239.0,
  150: 262.0,
};

/// Ampacity correction for ambient temperature. IEC 60364-5-52 style.
/// Nigeria: 40 degC is a realistic design ambient for a roof void or
/// battery room, giving 0.87.
double ambientAmpacityFactor(double ambientC) {
  if (ambientC <= 30) return 1.00;
  if (ambientC <= 35) return 0.94;
  if (ambientC <= 40) return 0.87;
  if (ambientC <= 45) return 0.79;
  if (ambientC <= 50) return 0.71;
  return 0.61;
}

/// Copper resistivity, ohm.mm^2/m.
const double copperResistivity = 0.0175;

/// Round a value up to the next entry in a list of standard sizes.
int nextStandard(List<int> sizes, double value) {
  for (final s in sizes) {
    if (s >= value) return s;
  }
  return sizes.last;
}

double nextStandardCable(double mm2) {
  for (final s in standardCableMm2) {
    if (s >= mm2) return s;
  }
  return standardCableMm2.last;
}

/// Smallest standard conductor able to carry [amps] at [ambientC].
double cableForAmpacity(double amps, {double ambientC = 40}) {
  final factor = ambientAmpacityFactor(ambientC);
  for (final s in standardCableMm2) {
    if ((cableAmpacity[s] ?? 0) * factor >= amps) return s;
  }
  return standardCableMm2.last;
}

// ---------------------------------------------------------------- unit costs
/// Indicative unit costs in Nigerian naira. EDIT THESE — they move fast.
/// Exposed as a mutable map so the UI can offer a price-settings screen.
class UnitCosts {
  double perPanelWatt;
  double perBatteryAh;
  double perInverterWatt;
  double perControllerAmp;
  double perCableMm2PerMetre;
  double protectionPackage;
  double mountingPerPanel;
  double installationLabour;

  UnitCosts({
    this.perPanelWatt = 380,
    this.perBatteryAh = 1900,
    this.perInverterWatt = 260,
    this.perControllerAmp = 5200,
    this.perCableMm2PerMetre = 480,
    this.protectionPackage = 145000,
    this.mountingPerPanel = 22000,
    this.installationLabour = 180000,
  });

  static UnitCosts defaults() => UnitCosts();
}
