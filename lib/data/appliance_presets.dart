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
///
/// ===========================================================================
/// ENTRIES NOT FROM CED R08-002 — cite these separately in Chapter 3.
/// ===========================================================================
///
/// Everything constructed with `AppliancePreset.stepped` is an addition, and
/// none of it comes from the supervisor's tables. Provenance by family:
///
///  * Ceiling / table / standing fan ladders, floodlight ladder, air
///    conditioner HP ladder, heating ladder — specified by the supervisor as
///    the sizes to support. Market sizes, no published source.
///  * Air conditioner watts — derived, NOT transcribed. The source convention
///    of 746 W per HP is shaft power, not electrical input. Nigerian market
///    HP maps to cooling capacity in BTU/h, and input power is that divided
///    by EER (9-10 for the units actually sold here):
///        1 HP  =   9 000 BTU/h / 9.0  = 1 000 W
///        10 HP = 120 000 BTU/h / 10.4 = 11 500 W
///    The old literal 746 x HP figures understated a 10 HP unit by 4 040 W.
///    Both the fixed-speed and variable-speed ladders are given because the
///    difference is ~30% on the largest load in a typical house.
///  * Television watts — modern LED/LCD panels. The two original CRT rows are
///    kept and relabelled rather than deleted, so the source figures stay
///    visible. A 19" CRT at 70 W overstates a 19" LED set by ~3.9x.
///  * Audio watts — real draw. Market speakers are rated in PMPO, which is
///    not a power measurement; a "2000 W PMPO" box draws around 40 W, and
///    music averages roughly a third of true RMS rating.
///
/// Two modelling notes that matter more than the wattages:
///
///  * Heating splits into on-demand (duty 1.0 — iron, kettle, rice cooker)
///    and thermostatic (duty 0.35 — storage and room heaters, which cycle).
///    At duty 1.0 a 3 kW water heater for 2 h reads 6 kWh/day against a real
///    2.1, which is two extra 630 W modules of array.
///  * The 10-18 W standing fans are BLDC/rechargeable units and that rating
///    is the DC motor's. Plugged into an inverter socket they are still AC
///    loads — do NOT mark them LoadType.dc, or the service skips the inverter
///    efficiency divide in §8.4.1. Wattages here are at-the-wall figures.
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

  // Security floodlighting. Nothing domestic is a 500 W lamp — at 150 W and
  // above this is outdoor/security lighting, and it runs dusk to dawn. One
  // 500 W flood at 12 h is 6 kWh/day, five times every other lamp in this
  // category combined, so it will dominate any system that includes it.
  // Draw is identical for LED and halogen at the same rating; only discharge
  // types (HPS, metal-halide) add roughly 13% for ballast losses.
  AppliancePreset.stepped('Floodlight', 'Lighting', [
    ApplianceStep('150 W', 150),
    ApplianceStep('200 W', 200),
    ApplianceStep('250 W', 250),
    ApplianceStep('300 W', 300),
    ApplianceStep('400 W', 400),
    ApplianceStep('500 W', 500),
  ], defaultStepIndex: 1, defaultHours: 12),

  // ------------------------------------------------------------- Cooling/air
  AppliancePreset.stepped('Ceiling fan', 'Cooling', [
    ApplianceStep('50 W', 50),
    ApplianceStep('70 W', 70),
    ApplianceStep('100 W', 100),
  ], defaultStepIndex: 1, surgeFactor: 2.0, defaultHours: 10),

  AppliancePreset.stepped('Table fan', 'Cooling', [
    ApplianceStep('10 W', 10),
    ApplianceStep('15 W', 15),
    ApplianceStep('18 W', 18),
    ApplianceStep('20 W', 20),
    ApplianceStep('25 W', 25),
    ApplianceStep('30 W', 30),
  ], defaultStepIndex: 4, surgeFactor: 2.0, defaultHours: 8),

  // 20 W added to close the gap in the supplied ladder, which had it for
  // table fans but not standing. See the header note on the 10-18 W steps.
  AppliancePreset.stepped('Standing fan', 'Cooling', [
    ApplianceStep('10 W', 10),
    ApplianceStep('15 W', 15),
    ApplianceStep('18 W', 18),
    ApplianceStep('20 W', 20),
    ApplianceStep('25 W', 25),
    ApplianceStep('30 W', 30),
    ApplianceStep('40 W', 40),
    ApplianceStep('45 W', 45),
    ApplianceStep('50 W', 50),
    ApplianceStep('60 W', 60),
    ApplianceStep('75 W', 75),
    ApplianceStep('90 W', 90),
  ], defaultStepIndex: 8, surgeFactor: 2.0, defaultHours: 8),

  // Air conditioning. See the header for why these are not 746 x HP.
  AppliancePreset.stepped('Air conditioner', 'Cooling', [
    ApplianceStep('1 HP', 1000),
    ApplianceStep('1.5 HP', 1350),
    ApplianceStep('2 HP', 1900),
    ApplianceStep('2.5 HP', 2550),
    ApplianceStep('3 HP', 3200),
    ApplianceStep('5 HP', 6000),
    ApplianceStep('10 HP', 11500),
  ], defaultStepIndex: 1, dutyCycle: 0.60, surgeFactor: 4.0, defaultHours: 8),

  // Variable-speed ("inverter") units modulate compressor speed instead of
  // cycling, so they draw roughly 25% less for the same cooling. Named
  // "variable-speed" deliberately — calling it an inverter A/C in a solar
  // app that also sizes a power inverter is a collision waiting to happen.
  AppliancePreset.stepped('Air conditioner, variable-speed', 'Cooling', [
    ApplianceStep('1 HP', 750),
    ApplianceStep('1.5 HP', 1000),
    ApplianceStep('2 HP', 1400),
    ApplianceStep('2.5 HP', 1900),
    ApplianceStep('3 HP', 2400),
    ApplianceStep('5 HP', 4600),
    ApplianceStep('10 HP', 9000),
  ], defaultStepIndex: 1, dutyCycle: 0.70, surgeFactor: 2.5, defaultHours: 8),

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
  //
  // The two rows below are the source table's, and they are CRT figures —
  // relabelled, not deleted, so Chapter 3 can show where they went. The panel
  // ladder that follows is what people actually own now.
  AppliancePreset('TV 19" CRT', 'Entertainment', 70, 70, defaultHours: 5),
  AppliancePreset('TV 25" CRT', 'Entertainment', 150, 150, defaultHours: 5),

  // 96" is not a manufactured panel size; the large formats actually sold are
  // 85", 98" and 100". Add ~35% for OLED or mini-LED at high brightness.
  AppliancePreset.stepped('TV, LED', 'Entertainment', [
    ApplianceStep('19"', 18),
    ApplianceStep('24"', 25),
    ApplianceStep('32"', 40),
    ApplianceStep('40"', 55),
    ApplianceStep('43"', 65),
    ApplianceStep('50"', 85),
    ApplianceStep('55"', 100),
    ApplianceStep('65"', 120),
    ApplianceStep('75"', 160),
    ApplianceStep('85"', 220),
    ApplianceStep('98"', 320),
  ], defaultStepIndex: 4, defaultHours: 5),

  // Real draw, not PMPO. See the header note.
  AppliancePreset.stepped('Audio system', 'Entertainment', [
    ApplianceStep('Portable radio', 5),
    ApplianceStep('Bluetooth speaker', 10),
    ApplianceStep('Soundbar', 40),
    ApplianceStep('Mini hi-fi', 50),
    ApplianceStep('Home theatre 5.1', 120),
    ApplianceStep('PA / party speaker', 250),
    ApplianceStep('PA amp + speakers', 700),
  ], defaultStepIndex: 3, dutyCycle: 0.35, surgeFactor: 1.5, defaultHours: 3),

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

  // ------------------------------------------------------------------ Heating
  //
  // Resistive heating is electrically the simplest load in the library —
  // surge 1.0, power factor 1.0 — and energetically the most dangerous,
  // because the duty cycle is doing all the work. Two families, because one
  // duty cycle cannot cover both cases:
  //
  //   on-demand    runs flat out for as long as it is switched on
  //   thermostatic runs to setpoint then cycles, ~35% of switched-on time
  //
  // The full ladder is on the on-demand family. The thermostatic family
  // carries only the ratings that are actually thermostatic appliances.
  AppliancePreset.stepped('Heating equipment', 'Heating', [
    ApplianceStep('40 W', 40),
    ApplianceStep('50 W', 50),
    ApplianceStep('70 W', 70),
    ApplianceStep('80 W', 80),
    ApplianceStep('100 W', 100),
    ApplianceStep('150 W', 150),
    ApplianceStep('200 W', 200),
    ApplianceStep('300 W', 300),
    ApplianceStep('400 W', 400),
    ApplianceStep('500 W', 500),
    ApplianceStep('700 W', 700),
    ApplianceStep('900 W', 900),
    ApplianceStep('1000 W', 1000),
    ApplianceStep('1200 W', 1200),
    ApplianceStep('1500 W', 1500),
    ApplianceStep('2000 W', 2000),
    ApplianceStep('2500 W', 2500),
    ApplianceStep('3000 W', 3000),
    ApplianceStep('4000 W', 4000),
    ApplianceStep('5000 W', 5000),
    ApplianceStep('5500 W', 5500),
    ApplianceStep('10000 W', 10000),
  ], defaultStepIndex: 12, defaultHours: 1),

  AppliancePreset.stepped('Water / room heater', 'Heating', [
    ApplianceStep('1000 W', 1000),
    ApplianceStep('1200 W', 1200),
    ApplianceStep('1500 W', 1500),
    ApplianceStep('2000 W', 2000),
    ApplianceStep('2500 W', 2500),
    ApplianceStep('3000 W', 3000),
    ApplianceStep('4000 W', 4000),
    ApplianceStep('5000 W', 5000),
    ApplianceStep('5500 W', 5500),
    ApplianceStep('10000 W', 10000),
  ], defaultStepIndex: 5, dutyCycle: 0.35, defaultHours: 3),

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
