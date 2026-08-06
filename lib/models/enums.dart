/// Shared enumerations for the sizing and diagnosis services.
library;

/// Battery chemistry. Drives depth of discharge, round-trip efficiency and
/// every voltage threshold in the fault engine.
enum BatteryChemistry {
  leadAcid,
  lithium;

  /// Usable depth of discharge.
  /// Lead-acid 0.50, LiFePO4 0.80 — LEONICS / CED R08-002 §6.4.4.
  double get depthOfDischarge => this == lithium ? 0.80 : 0.50;

  /// Round-trip storage efficiency. CED R08-002 §2.4 gives 0.90 for lead-acid.
  double get roundTripEfficiency => this == lithium ? 0.95 : 0.90;

  /// Nominal volts per 12 V block.
  double get nominalBlockVolts => 12.0;

  String get label => this == lithium ? 'LiFePO4' : 'Lead-acid';
}

/// Charge controller topology.
enum ControllerType {
  /// Let the service decide from array size and system voltage.
  auto,
  mppt,
  pwm;

  String get label => this == mppt ? 'MPPT' : 'PWM';
}

/// Which peak-sun-hour figure to size against.
enum PshMode {
  /// Month of lowest average daily solar radiation.
  /// CED R08-002 §2.5 and §8.3(d) — the correct basis for a standalone system.
  worstMonth,

  /// Twelve-month mean. Optimistic; shown for comparison only.
  annualAverage;

  String get label =>
      this == worstMonth ? 'Worst month (recommended)' : 'Annual average';
}

/// Whether a load is fed through the inverter or straight off the DC bus.
/// CED R08-002 §8.4.1 worksheet column A5.
enum LoadType {
  ac,
  dc;

  String get label => this == ac ? 'AC' : 'DC';
}

/// Severity used by the validation layer.
enum WarningLevel { info, caution, critical }
