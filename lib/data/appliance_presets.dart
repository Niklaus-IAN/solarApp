import '../models/appliance.dart';
import '../models/enums.dart';

/// Appliance library transcribed from the supervisor's "Typical Power
/// Consumption Demands of Various Appliances" tables (CED R08-002 Annexure-1).
///
/// Two departures from a literal transcription, both deliberate:
///
///  1. Refrigeration entries in the source already carry effective hours
///     ("Refrigerator/Freezer 20cf 1.8 kWh per day (15 hours)"). Those are
///     encoded as duty cycles here (15/24 = 0.63) so the user can enter the
///     honest "24 hours" and still get the right energy.
///  2. Surge factors are added from the Port Harcourt field guide
///     (fridge 3x, A/C 3-5x, pump 5-7x). The source tables carry running
///     watts only.
const List<AppliancePreset> appliancePresets = [
  // ---------------------------------------------------------------- Lighting
  AppliancePreset('LED bulb', 'Lighting', 7, 12, defaultHours: 6),
  AppliancePreset('CFL, 20 W equivalent', 'Lighting', 22, 22, defaultHours: 6),
  AppliancePreset('CFL, 25 W equivalent', 'Lighting', 28, 28, defaultHours: 6),
  AppliancePreset('Incandescent 100 W', 'Lighting', 100, 100, defaultHours: 4),
  AppliancePreset('DC incandescent 50 W', 'Lighting', 50, 50,
      loadType: LoadType.dc, defaultHours: 5),
  AppliancePreset('DC halogen 40 W', 'Lighting', 40, 40,
      loadType: LoadType.dc, defaultHours: 5),

  // ------------------------------------------------------------- Cooling/air
  AppliancePreset('Ceiling fan', 'Cooling', 10, 50, surgeFactor: 2.0, defaultHours: 10),
  AppliancePreset('Table fan', 'Cooling', 10, 25, surgeFactor: 2.0, defaultHours: 8),
  AppliancePreset('Air conditioner 1 HP', 'Cooling', 750, 750,
      dutyCycle: 0.60, surgeFactor: 4.0, defaultHours: 8),
  AppliancePreset('Air conditioner 1.5 HP', 'Cooling', 1120, 1120,
      dutyCycle: 0.60, surgeFactor: 4.0, defaultHours: 8),

  // ------------------------------------------------------------ Refrigeration
  //
  // THE SOURCE TABLE IS INTERNALLY INCONSISTENT HERE — read this before
  // changing any of these numbers.
  //
  // The row "Refrigerator/Freezer 20cf 1.8 kWh per day (15 hours) | 540"
  // cannot be satisfied by all three of its own figures:
  //     540 W x 15 h = 8.10 kWh/day, not the 1.8 kWh/day it states.
  // Same for the 16cf row: 475 W x 13 h = 6.17 kWh against a stated 1.6.
  //
  // The stated kWh/day is the trustworthy figure — it is the appliance's
  // measured consumption spec, and 1.6-1.8 kWh/day is the correct order of
  // magnitude for a domestic fridge-freezer. The bracketed hours appear to
  // describe something other than compressor run time.
  //
  // Duty cycles below are therefore derived as:  kWh_per_day / (W x 24).
  // Taking the bracketed hours at face value would have overstated fridge
  // energy by roughly 4.5x and inflated every system containing one.
  //
  // The Sun Frost DC rows ARE self-consistent (112 W x 7 h = 0.78 kWh/day,
  // correct for that ultra-efficient DC model), so those keep 7/24 = 0.29.
  AppliancePreset('Refrigerator/Freezer 16cf', 'Refrigeration', 475, 475,
      dutyCycle: 0.140, surgeFactor: 3.0, defaultHours: 24), // 1.6 kWh/day
  AppliancePreset('Refrigerator/Freezer 20cf', 'Refrigeration', 540, 540,
      dutyCycle: 0.139, surgeFactor: 3.0, defaultHours: 24), // 1.8 kWh/day
  AppliancePreset('Freezer 14cf', 'Refrigeration', 440, 440,
      dutyCycle: 0.142, surgeFactor: 3.0, defaultHours: 24), // ~1.5 kWh/day est
  AppliancePreset('Sun Frost 16cf DC', 'Refrigeration', 112, 112,
      dutyCycle: 0.29, surgeFactor: 3.0, loadType: LoadType.dc, defaultHours: 24),
  AppliancePreset('Sun Frost 12cf DC', 'Refrigeration', 70, 70,
      dutyCycle: 0.29, surgeFactor: 3.0, loadType: LoadType.dc, defaultHours: 24),
  AppliancePreset('Small chest freezer', 'Refrigeration', 350, 350,
      dutyCycle: 0.145, surgeFactor: 3.0, defaultHours: 24), // ~1.2 kWh/day est

  // -------------------------------------------------------------- Entertainment
  AppliancePreset('TV 19" colour', 'Entertainment', 70, 70, defaultHours: 5),
  AppliancePreset('TV 25" colour', 'Entertainment', 150, 150, defaultHours: 5),
  AppliancePreset('Satellite dish / decoder', 'Entertainment', 30, 30, defaultHours: 5),
  AppliancePreset('Stereo', 'Entertainment', 10, 30, defaultHours: 3),
  AppliancePreset('CD / DVD player', 'Entertainment', 35, 35, defaultHours: 2),
  AppliancePreset('Clock radio', 'Entertainment', 1, 1, defaultHours: 24),

  // --------------------------------------------------------------- Computing
  AppliancePreset('Laptop', 'Computing', 20, 50, defaultHours: 6),
  AppliancePreset('Desktop PC', 'Computing', 80, 150, defaultHours: 6),
  AppliancePreset('Printer', 'Computing', 100, 100, dutyCycle: 0.15, defaultHours: 2),
  AppliancePreset('Phone charger', 'Computing', 10, 10, defaultHours: 3),

  // ------------------------------------------------------------------ Kitchen
  AppliancePreset('Coffee pot', 'Kitchen', 200, 200, defaultHours: 1),
  AppliancePreset('Coffee maker', 'Kitchen', 800, 800, defaultHours: 0.5),
  AppliancePreset('Toaster', 'Kitchen', 800, 1500, defaultHours: 0.25),
  AppliancePreset('Blender', 'Kitchen', 300, 300, surgeFactor: 2.5, defaultHours: 0.25),
  AppliancePreset('Microwave', 'Kitchen', 600, 1500, defaultHours: 0.5),
  AppliancePreset('Hot plate', 'Kitchen', 1200, 1200, defaultHours: 1),
  AppliancePreset('Electric kettle', 'Kitchen', 1500, 1500, defaultHours: 0.5),

  // ---------------------------------------------------------------- Household
  AppliancePreset('Washing machine, automatic', 'Household', 500, 500,
      surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Washing machine, manual', 'Household', 300, 300,
      surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Vacuum cleaner, upright', 'Household', 200, 700,
      surgeFactor: 2.5, defaultHours: 0.5),
  AppliancePreset('Vacuum cleaner, hand', 'Household', 100, 100,
      surgeFactor: 2.5, defaultHours: 0.25),
  AppliancePreset('Sewing machine', 'Household', 100, 100, defaultHours: 1),
  AppliancePreset('Clothes iron', 'Household', 1000, 1000, defaultHours: 1),
  AppliancePreset('Clothes dryer, electric', 'Household', 400, 400,
      surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Electric blanket', 'Household', 200, 200, defaultHours: 4),
  AppliancePreset('Blow dryer', 'Household', 1000, 1000, defaultHours: 0.25),
  AppliancePreset('Shaver', 'Household', 15, 15, defaultHours: 0.25),
  AppliancePreset('Water pump', 'Household', 250, 500,
      surgeFactor: 6.0, defaultHours: 2),

  // -------------------------------------------------------------------- Tools
  AppliancePreset('Drill, 1/4"', 'Tools', 250, 250, surgeFactor: 2.5, defaultHours: 1),
  AppliancePreset('Drill, 1/2"', 'Tools', 750, 750, surgeFactor: 2.5, defaultHours: 1),
  AppliancePreset('Drill, 1"', 'Tools', 1000, 1000, surgeFactor: 2.5, defaultHours: 1),
  AppliancePreset('Disc sander, 9"', 'Tools', 1200, 1200, surgeFactor: 2.5, defaultHours: 1),
  AppliancePreset('Belt sander, 3"', 'Tools', 1000, 1000, surgeFactor: 2.5, defaultHours: 1),
  AppliancePreset('Circular saw, 7-1/4"', 'Tools', 900, 900, surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Circular saw, 8-1/4"', 'Tools', 1400, 1400, surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Chain saw, 12"', 'Tools', 1100, 1100, surgeFactor: 3.0, defaultHours: 1),
  AppliancePreset('Band saw, 14"', 'Tools', 1100, 1100, surgeFactor: 3.0, defaultHours: 1),
];

/// Distinct categories, in a sensible display order.
List<String> get applianceCategories {
  final seen = <String>[];
  for (final p in appliancePresets) {
    if (!seen.contains(p.category)) seen.add(p.category);
  }
  return seen;
}

List<AppliancePreset> presetsInCategory(String category) =>
    appliancePresets.where((p) => p.category == category).toList();

AppliancePreset? findPreset(String name) {
  for (final p in appliancePresets) {
    if (p.name.toLowerCase() == name.toLowerCase()) return p;
  }
  return null;
}
