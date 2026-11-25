import 'dart:math' as math;

import '../data/psh_table.dart';
import '../data/standard_sizes.dart';
import '../models/enums.dart';
import '../models/panel_spec.dart';
import '../models/sizing_input.dart';
import '../models/sizing_result.dart';

/// Off-grid PV system sizing engine.
///
/// Eleven sequential steps. Each consumes the previous step's output; nothing
/// iterates back. Every component output rounds UP to a purchasable standard
/// size so the result is a bill of materials rather than raw numbers.
///
/// SOURCES
///  * LEONICS 5-step method (supervisor's images 1-2) — duty-cycled load
///    entry, panel generation factor, Isc-based PWM controller sizing,
///    3x minimum for motor loads.
///  * CED R08-002 (A. Bhatia, 8 PDH) — itemised derating table §2.4,
///    worst-month design basis §2.5, battery equation §6.5, per-appliance
///    AC/DC adjustment and system-voltage rule §8.4.1, 3-string parallel
///    limit §6.4.5, 4% total voltage drop budget §7.6.
///  * Port Harcourt field guide — dual controller formulas, controller Voc
///    margin, motor surge multiples, complete protection chain.
///  * This project's MATLAB single-diode simulation — the -0.45 %/degC power
///    coefficient used in the computed temperature derate.
///
/// DIVERGENCE FROM SOURCES, and why (state these in Chapter 3):
///  1. LEONICS applies a flat 1.3 uplift for all conversion losses. This
///     implementation decomposes it into the measurable parts so the loss
///     model responds to battery chemistry and AC/DC load mix instead of
///     assuming one number for every system.
///  2. LEONICS uses a tabulated Panel Generation Factor (3.43, Thailand).
///     No equivalent is published for Nigerian cities, so the PGF here is
///     computed as worst-month PSH x array derate, with the temperature term
///     taken from this project's own simulation work.
///  3. Voltage drop follows CED's whole-path 4% budget rather than the field
///     guide's per-run 3%, because a per-run allowance permits an
///     out-of-spec cumulative drop.
class SizingService {
  const SizingService();

  // Inverter surge capability as a multiple of continuous rating. Pure sine
  // units are typically 2x for a few seconds.
  static const double _inverterSurgeCapability = 2.0;

  // Continuous-duty derating applied to conductors and OCPD.
  static const double _continuousFactor = 1.25;

  // PV fuse factor: 1.25 for irradiance enhancement x 1.25 for safety.
  static const double _pvFuseFactor = 1.56;

  // Total DC voltage drop budget, allocated across the three DC runs.
  static const double _dropPvRun = 0.02;
  static const double _dropControllerRun = 0.01;
  static const double _dropBatteryRun = 0.01;
  static const double _dropAcRun = 0.03;

  // Parallel battery strings above this circulate current between branches.
  static const int _maxParallelBatteryStrings = 3;

  // Parallel PV strings at or above this need per-string fusing.
  static const int _stringFuseThreshold = 3;

  SizingResult calculate(SizingInput input) {
    final rationale = <String, String>{};
    final warnings = <SizingWarning>[];
    final appliances = input.activeAppliances;

    // ================================================== STEP 1: LOAD ANALYSIS
    // AC and DC energy are accumulated separately. DC loads bypass the
    // inverter, so applying inverter efficiency to them would overstate the
    // requirement. CED R08-002 §8.4.1 worksheet column A5.
    double acLoadWh = 0;
    double dcLoadWh = 0;
    double runningLoadW = 0;
    double largestSurgeExtra = 0;
    String? largestMotorName;

    for (final a in appliances) {
      if (a.loadType == LoadType.ac) {
        acLoadWh += a.dailyWh;
      } else {
        dcLoadWh += a.dailyWh;
      }
      if (a.simultaneous) runningLoadW += a.runningW;
      if (a.surgeExtraW > largestSurgeExtra) {
        largestSurgeExtra = a.surgeExtraW;
        largestMotorName = a.name;
      }
    }

    // Planned future load is treated as AC.
    acLoadWh += input.futureLoadWh;

    final totalLoadWh = acLoadWh + dcLoadWh;

    // Only the largest single motor surge is added. Two motors starting in
    // the same second is not a design case worth paying for.
    // Field guide: Total Surge = Running load + Biggest motor surge.
    final requiredSurgeW = runningLoadW + largestSurgeExtra;

    // Energy that must leave the battery bank.
    final busEnergyWh = (acLoadWh / input.inverterEfficiency) + dcLoadWh;

    rationale['load'] =
        'AC loads ${acLoadWh.toStringAsFixed(0)} Wh/day divided by inverter '
        'efficiency ${input.inverterEfficiency}, plus DC loads '
        '${dcLoadWh.toStringAsFixed(0)} Wh/day taken directly, gives '
        '${busEnergyWh.toStringAsFixed(0)} Wh/day out of the battery.';

    // ============================================ STEP 2: SYSTEM VOLTAGE
    // CED R08-002 §8.4.1 parameter A2: 12 V up to 1 kWh/day, 24 V from
    // 1 to 4 kWh/day, 48 V above 4 kWh/day.
    final recommendedVoltage = _recommendSystemVoltage(totalLoadWh);
    final systemVoltage = input.systemVoltage ?? recommendedVoltage;
    final voltageWasRecommended = input.systemVoltage == null;

    rationale['systemVoltage'] = voltageWasRecommended
        ? '${systemVoltage} V selected automatically for a daily load of '
            '${(totalLoadWh / 1000).toStringAsFixed(2)} kWh (CED R08-002 §8.4.1).'
        : '${systemVoltage} V as specified. Recommended for this load: '
            '${recommendedVoltage} V.';

    // ==================================== STEP 3: SUN HOURS AND ARRAY DERATE
    final designPsh = resolvePsh(input.city, input.pshMode);
    final designMonth = input.pshMode == PshMode.worstMonth
        ? worstMonthName(input.city)
        : 'annual average';
    final avgPsh = annualAveragePsh(input.city);

    final arrayDerate = input.derate.arrayFactor(input.panel);
    final pgf = designPsh * arrayDerate;
    final bosFactor = input.derate.balanceOfSystemFactor(input.chemistry);
    final totalFactor = input.derate.totalSystemFactor(
      input.panel,
      input.chemistry,
      inverterEfficiency: input.inverterEfficiency,
    );

    rationale['psh'] =
        'Designed on ${input.city} $designMonth at '
        '${designPsh.toStringAsFixed(2)} peak sun hours '
        '(annual average ${avgPsh.toStringAsFixed(2)}). CED R08-002 §2.5 '
        'requires the month of lowest average daily solar radiation.';

    rationale['derate'] =
        'Panel generation factor ${pgf.toStringAsFixed(2)} = '
        '${designPsh.toStringAsFixed(2)} PSH x '
        '${arrayDerate.toStringAsFixed(3)} array derate. Cell temperature '
        '${input.derate.cellTemperature(input.panel).toStringAsFixed(1)} degC '
        'by the NOCT method at '
        '${input.derate.designAmbientC.toStringAsFixed(0)} degC ambient. '
        'Whole-chain factor ${totalFactor.toStringAsFixed(3)} against the '
        'CED published value of 0.60.';

    // ========================================================= STEP 4: ARRAY
    final requiredGenerationWh = busEnergyWh / bosFactor;
    final requiredArrayWp = requiredGenerationWh / pgf;
    final requiredArrayWpAvg = requiredGenerationWh / (avgPsh * arrayDerate);

    int panelCount = (requiredArrayWp / input.panel.watts).ceil();
    if (panelCount < 1) panelCount = 1;

    // Controller type is decided before string configuration, because a PWM
    // controller constrains the array to one panel's Vmpp above the charging
    // voltage while MPPT allows long strings.
    final provisionalWp = panelCount * input.panel.watts;
    final controllerType = _resolveControllerType(
      input.controllerPreference,
      provisionalWp,
      systemVoltage,
    );

    final stringConfig = _configureStrings(
      panel: input.panel,
      panelCount: panelCount,
      systemVoltage: systemVoltage,
      controllerType: controllerType,
    );

    panelCount = stringConfig.totalPanels;
    final panelsInSeries = stringConfig.series;
    final parallelStrings = stringConfig.parallel;
    final installedWp = panelCount * input.panel.watts;
    final arrayIsc = parallelStrings * input.panel.isc;
    final stringVmpp = panelsInSeries * input.panel.vmpp;
    final stringVocCold = panelsInSeries * input.panel.vocCold;
    final arrayAreaM2 = panelCount * input.panel.areaM2;

    rationale['array'] =
        '${requiredGenerationWh.toStringAsFixed(0)} Wh/day must be generated; '
        'divided by a PGF of ${pgf.toStringAsFixed(2)} gives '
        '${requiredArrayWp.toStringAsFixed(0)} Wp. Rounded up to $panelCount x '
        '${input.panel.watts.toStringAsFixed(0)} W = '
        '${installedWp.toStringAsFixed(0)} Wp, arranged as $parallelStrings '
        'string(s) of $panelsInSeries in series so no string is '
        'half-populated.';

    // ======================================================= STEP 5: BATTERY
    // CED R08-002 §6.5:  Q = (E x A) / (V x DoD x eta_inv x eta_cable)
    // Inverter efficiency is already inside busEnergyWh, applied per load
    // type. What remains is the distribution cable term.
    final dod = input.chemistry.depthOfDischarge;
    final requiredBatteryAh =
        (busEnergyWh / input.derate.distributionCable) *
            input.autonomyDays /
            (systemVoltage * dod);

    final batteriesInSeries = (systemVoltage / 12).round().clamp(1, 8);
    final batteryStrings =
        (requiredBatteryAh / input.batteryUnitAh).ceil().clamp(1, 99);
    final batteryCount = batteriesInSeries * batteryStrings;
    final installedBatteryAh = batteryStrings * input.batteryUnitAh;
    final usableStorageWh = installedBatteryAh * systemVoltage * dod;

    rationale['battery'] =
        '${busEnergyWh.toStringAsFixed(0)} Wh/day x '
        '${input.autonomyDays.toStringAsFixed(0)} days of autonomy, divided by '
        '(${systemVoltage} V x ${dod.toStringAsFixed(2)} DoD x '
        '${input.derate.distributionCable} cable) gives '
        '${requiredBatteryAh.toStringAsFixed(0)} Ah. '
        '$batteryCount x ${input.batteryUnitAh.toStringAsFixed(0)} Ah '
        '${input.chemistry.label} units: $batteriesInSeries in series, '
        '$batteryStrings string(s) in parallel.';

    // ====================================================== STEP 6: INVERTER
    // Two independent requirements; the larger wins.
    final fromContinuous = runningLoadW * _continuousFactor;
    final fromSurge = requiredSurgeW / _inverterSurgeCapability;
    final inverterMinimum = math.max(fromContinuous, fromSurge);
    final inverterW = nextStandard(standardInverterW, inverterMinimum);

    rationale['inverter'] =
        '${runningLoadW.toStringAsFixed(0)} W running x 1.25 = '
        '${fromContinuous.toStringAsFixed(0)} W. '
        '${largestMotorName == null ? 'No motor loads declared.' : 'Largest '
            'motor ($largestMotorName) needs '
            '${requiredSurgeW.toStringAsFixed(0)} W peak, which a unit rated '
            '${fromSurge.toStringAsFixed(0)} W continuous can supply at 2x '
            'surge.'} '
        'Selected the next standard size: ${inverterW} W.';

    // ==================================================== STEP 7: CONTROLLER
    // MPPT converts surplus array voltage into charging current, so its
    // rating derives from array watts. PWM passes array current straight
    // through, so its rating derives from Isc.
    final double controllerRawA;
    if (controllerType == ControllerType.mppt) {
      controllerRawA = (installedWp / systemVoltage) * _continuousFactor;
    } else {
      controllerRawA = arrayIsc * 1.3; // LEONICS Isc x 1.3
    }

    // A single controller may not be able to carry the array. Rounding up to
    // the largest standard size would silently under-rate the system, so
    // split the array across parallel units instead.
    final controllerCount =
        (controllerRawA / standardControllerA.last).ceil().clamp(1, 8);
    final controllerA =
        nextStandard(standardControllerA, controllerRawA / controllerCount);
    final minVocRating =
        nextStandard(controllerVocClasses, stringVocCold * 1.2);

    rationale['controller'] = controllerType == ControllerType.mppt
        ? 'MPPT: ${installedWp.toStringAsFixed(0)} Wp / ${systemVoltage} V x '
            '1.25 = ${controllerRawA.toStringAsFixed(1)} A, rounded up to '
            '${controllerA} A'
            '${controllerCount > 1 ? " x $controllerCount units in parallel" : ""}'
            '. Maximum PV input must be at least '
            '${minVocRating} Vdc (string Voc '
            '${stringVocCold.toStringAsFixed(0)} V cold, plus 20% margin).'
        : 'PWM: array Isc ${arrayIsc.toStringAsFixed(1)} A x 1.3 = '
            '${controllerRawA.toStringAsFixed(1)} A, rounded up to '
            '${controllerA} A'
            '${controllerCount > 1 ? " x $controllerCount units in parallel" : ""}'
            '. Sized on short-circuit current per CED '
            'R08-002 §5.3(b). Maximum PV input at least ${minVocRating} Vdc.';

    // ========================================================= STEP 8: CABLE
    final batteryToInverterA =
        inverterW / systemVoltage / 0.9 * _continuousFactor;
    final acOutputA = inverterW / 220 * _continuousFactor;

    final cableRuns = <CableRun>[
      _sizeRun(
        label: 'PV array to charge controller',
        amps: arrayIsc * _continuousFactor,
        volts: stringVmpp,
        lengthM: input.lenPvToController,
        dropBudget: _dropPvRun,
        ambientC: input.cableAmbientC,
        isDc: true,
      ),
      _sizeRun(
        label: 'Charge controller to battery',
        amps: (controllerA * controllerCount).toDouble(),
        volts: systemVoltage.toDouble(),
        lengthM: input.lenControllerToBattery,
        dropBudget: _dropControllerRun,
        ambientC: input.cableAmbientC,
        isDc: true,
      ),
      _sizeRun(
        label: 'Battery to inverter',
        amps: batteryToInverterA,
        volts: systemVoltage.toDouble(),
        lengthM: input.lenBatteryToInverter,
        dropBudget: _dropBatteryRun,
        ambientC: input.cableAmbientC,
        isDc: true,
      ),
      _sizeRun(
        label: 'Inverter to distribution board',
        amps: acOutputA,
        volts: 220,
        lengthM: input.lenInverterToBoard,
        dropBudget: _dropAcRun,
        ambientC: input.cableAmbientC,
        isDc: false,
      ),
    ];

    final dcDropTotal = cableRuns
        .where((r) => r.isDc)
        .fold<double>(0, (sum, r) => sum + r.actualDrop);

    rationale['cable'] =
        'Each run sized by the larger of voltage drop and current-carrying '
        'capacity, then rounded up to a standard conductor. Total DC drop '
        '${(dcDropTotal * 100).toStringAsFixed(2)}% against the 4% whole-path '
        'budget in CED R08-002 §7.6. Ampacity derated for '
        '${input.cableAmbientC.toStringAsFixed(0)} degC ambient.';

    // ==================================================== STEP 9: PROTECTION
    final protection = ProtectionSpec(
      pvStringFuseA: parallelStrings >= _stringFuseThreshold
          ? nextStandard(standardBreakerA, input.panel.isc * _pvFuseFactor)
          : null,
      arrayBreakerA: nextStandard(standardBreakerA, arrayIsc * _pvFuseFactor),
      arrayBreakerVdc: nextStandard(dcVoltageClasses, stringVocCold * 1.2),
      controllerBreakerA: nextStandard(
          standardBreakerA, controllerA * controllerCount * _continuousFactor),
      batteryBreakerA: nextStandard(standardBreakerA, batteryToInverterA),
      batteryIsolatorA:
          nextStandard(standardBreakerA, batteryToInverterA * _continuousFactor),
      acBreakerA: nextStandard(standardBreakerA, acOutputA),
      rcdMilliamps: 30,
      dcSpdVdc: nextStandard(dcVoltageClasses, stringVocCold * 1.2),
      dcSpdKa: 60, // Nigeria, high lightning incidence
      acSpdVac: 275,
      acSpdKa: 40,
      earthCableMm2: 16,
      earthRodCount: 2,
    );

    rationale['protection'] =
        'Overcurrent devices sized to protect the conductor, not the load. '
        'PV circuits at Isc x 1.56 (1.25 irradiance x 1.25 safety); battery '
        'and AC circuits at continuous current x 1.25. All DC devices must be '
        'DC-rated — an AC breaker will arc and weld on DC. SPD ratings '
        'reflect high lightning incidence in southern Nigeria.';

    // =================================================== STEP 10: VALIDATION
    warnings.addAll(_validate(
      input: input,
      systemVoltage: systemVoltage,
      recommendedVoltage: recommendedVoltage,
      panelCount: panelCount,
      arrayAreaM2: arrayAreaM2,
      installedWp: installedWp,
      batteryStrings: batteryStrings,
      controllerType: controllerType,
      controllerCount: controllerCount,
      minVocRating: minVocRating,
      stringVocCold: stringVocCold,
      batteryToInverterA: batteryToInverterA,
      dcDropTotal: dcDropTotal,
      designPsh: designPsh,
      avgPsh: avgPsh,
      largestMotorName: largestMotorName,
      inverterMinimum: inverterMinimum,
      inverterW: inverterW,
      requiredSurgeW: requiredSurgeW,
      runningLoadW: runningLoadW,
      cableRuns: cableRuns,
    ));

    // ========================================================= STEP 11: COST
    final cost = _estimateCost(
      input: input,
      installedWp: installedWp,
      panelCount: panelCount,
      installedBatteryAh: installedBatteryAh,
      batteryCount: batteryCount,
      inverterW: inverterW,
      controllerA: controllerA,
      cableRuns: cableRuns,
    );

    return SizingResult(
      acLoadWh: acLoadWh,
      dcLoadWh: dcLoadWh,
      totalLoadWh: totalLoadWh,
      busEnergyWh: busEnergyWh,
      runningLoadW: runningLoadW,
      requiredSurgeW: requiredSurgeW,
      largestMotorName: largestMotorName,
      designPsh: designPsh,
      designMonth: designMonth,
      annualAveragePsh: avgPsh,
      arrayDerateFactor: arrayDerate,
      panelGenerationFactor: pgf,
      balanceOfSystemFactor: bosFactor,
      totalSystemFactor: totalFactor,
      derateBreakdown: input.derate.breakdown(
        input.panel,
        input.chemistry,
        inverterEfficiency: input.inverterEfficiency,
      ),
      requiredGenerationWh: requiredGenerationWh,
      requiredArrayWp: requiredArrayWp,
      requiredArrayWpAnnualAverage: requiredArrayWpAvg,
      panelCount: panelCount,
      panelsInSeries: panelsInSeries,
      parallelStrings: parallelStrings,
      installedWp: installedWp,
      arrayIsc: arrayIsc,
      stringVmpp: stringVmpp,
      stringVocCold: stringVocCold,
      arrayAreaM2: arrayAreaM2,
      panel: input.panel,
      systemVoltage: systemVoltage,
      systemVoltageWasRecommended: voltageWasRecommended,
      requiredBatteryAh: requiredBatteryAh,
      batteryCount: batteryCount,
      batteriesInSeries: batteriesInSeries,
      batteryParallelStrings: batteryStrings,
      installedBatteryAh: installedBatteryAh,
      usableStorageWh: usableStorageWh,
      chemistry: input.chemistry,
      autonomyDays: input.autonomyDays,
      inverterMinimumW: inverterMinimum,
      inverterW: inverterW,
      inverterRequiredSurgeW: requiredSurgeW,
      controllerType: controllerType,
      controllerRawA: controllerRawA,
      controllerA: controllerA,
      controllerCount: controllerCount,
      controllerMinVocRating: minVocRating,
      cableRuns: cableRuns,
      protection: protection,
      warnings: warnings,
      cost: cost,
      rationale: rationale,
    );
  }

  // ------------------------------------------------------------------ helpers

  /// CED R08-002 §8.4.1 parameter A2.
  int _recommendSystemVoltage(double dailyWh) {
    final kwh = dailyWh / 1000;
    if (kwh <= 1.0) return 12;
    if (kwh <= 4.0) return 24;
    return 48;
  }

  ControllerType _resolveControllerType(
      ControllerType preference, double arrayWp, int systemVoltage) {
    if (preference != ControllerType.auto) return preference;
    // Field guide: MPPT for anything above 1 kW, and for all 48 V systems.
    if (arrayWp > 1000 || systemVoltage >= 48) return ControllerType.mppt;
    return ControllerType.pwm;
  }

  /// Series/parallel arrangement.
  ///
  /// A PWM controller passes array voltage straight to the battery, so the
  /// string must sit just above the charging voltage and no higher — anything
  /// more is wasted. An MPPT controller converts surplus voltage into current,
  /// so longer strings are better (less current, thinner cable, lower loss),
  /// bounded only by the controller's maximum PV input.
  _StringConfig _configureStrings({
    required PanelSpec panel,
    required int panelCount,
    required int systemVoltage,
    required ControllerType controllerType,
  }) {
    // Absorption/boost charging voltage is roughly 1.2x nominal.
    final chargingVoltage = systemVoltage * 1.2;
    final minSeries = (chargingVoltage / panel.vmpp).ceil().clamp(1, 24);

    if (controllerType == ControllerType.pwm) {
      final parallel = (panelCount / minSeries).ceil().clamp(1, 99);
      return _StringConfig(minSeries, parallel, minSeries * parallel);
    }

    // MPPT. The upper bound on series count is the controller's maximum PV
    // input voltage, and the 20% cold-weather margin must be inside that
    // bound — not applied afterwards, or the recommendation silently jumps a
    // voltage class and the user buys a needlessly expensive controller.
    const targetClass = 250; // affordable and widely stocked
    final perPanelWithMargin = panel.vocCold * 1.2;
    var vocCeiling = targetClass;
    if (minSeries * perPanelWithMargin > targetClass * 0.95) {
      for (final c in controllerVocClasses) {
        if (minSeries * perPanelWithMargin <= c * 0.95) {
          vocCeiling = c;
          break;
        }
      }
    }
    final maxSeries =
        (vocCeiling * 0.95 / perPanelWithMargin).floor().clamp(minSeries, 24);

    // Among the permitted series counts, pick the one that wastes the fewest
    // panels; break ties toward MORE panels in series, because that lowers
    // string current and therefore conductor size and I2R loss.
    var bestSeries = minSeries;
    var bestTotal = 1 << 30;
    for (var s = minSeries; s <= maxSeries; s++) {
      final total = (panelCount / s).ceil() * s;
      if (total < bestTotal || (total == bestTotal && s > bestSeries)) {
        bestTotal = total;
        bestSeries = s;
      }
    }

    final parallel = (panelCount / bestSeries).ceil().clamp(1, 99);
    return _StringConfig(bestSeries, parallel, bestSeries * parallel);
  }

  /// Size one conductor run by the larger of voltage drop and ampacity.
  ///
  ///   A(mm2) = (2 x rho x I x L) / (V x dropFraction)
  ///
  /// The factor of 2 covers the out-and-back conductor length. Taking the
  /// larger of the two results matters: on a short run the voltage-drop
  /// calculation alone returns a conductor thin enough to overheat.
  CableRun _sizeRun({
    required String label,
    required double amps,
    required double volts,
    required double lengthM,
    required double dropBudget,
    required double ambientC,
    required bool isDc,
  }) {
    final byDrop =
        (2 * copperResistivity * amps * lengthM) / (volts * dropBudget);
    final byAmpacity = cableForAmpacity(amps, ambientC: ambientC);
    final selected = nextStandardCable(math.max(byDrop, byAmpacity));

    final actualDrop =
        (2 * copperResistivity * amps * lengthM) / (selected * volts);

    return CableRun(
      label: label,
      amps: amps,
      volts: volts,
      lengthM: lengthM,
      byVoltageDropMm2: byDrop,
      byAmpacityMm2: byAmpacity,
      selectedMm2: selected,
      dropBudget: dropBudget,
      actualDrop: actualDrop,
      isDc: isDc,
    );
  }

  List<SizingWarning> _validate({
    required SizingInput input,
    required int systemVoltage,
    required int recommendedVoltage,
    required int panelCount,
    required double arrayAreaM2,
    required double installedWp,
    required int batteryStrings,
    required ControllerType controllerType,
    required int controllerCount,
    required int minVocRating,
    required double stringVocCold,
    required double batteryToInverterA,
    required double dcDropTotal,
    required double designPsh,
    required double avgPsh,
    required String? largestMotorName,
    required double inverterMinimum,
    required int inverterW,
    required double requiredSurgeW,
    required double runningLoadW,
    required List<CableRun> cableRuns,
  }) {
    final w = <SizingWarning>[];

    // Demand past the end of the catalogue.
    //
    // nextStandard returns the largest stocked size when nothing satisfies the
    // requirement, which reads as a valid answer and is not one. Until the
    // library gained 10 HP air conditioning and 10 kW heating elements no load
    // could reach this, so it never fired. It can now.
    if (exceedsStandard(standardInverterW, inverterMinimum)) {
      w.add(SizingWarning(
        WarningLevel.critical,
        'Beyond single-phase inverter range',
        'This load needs at least '
            '${inverterMinimum.toStringAsFixed(0)} W of continuous inverter '
            'capacity (${runningLoadW.toStringAsFixed(0)} W running, '
            '${requiredSurgeW.toStringAsFixed(0)} W peak). The largest '
            'standard single-phase unit is ${standardInverterW.last} W, and '
            'that is what the bill of materials below shows — it will not '
            'carry this design.',
        action: 'Loads of this size need a three-phase supply and are outside '
            'what this tool sizes. Remove the largest load, or treat the '
            'result as indicative only.',
      ));
    }

    for (final r in cableRuns) {
      if (exceedsAmpacity(r.amps, ambientC: input.cableAmbientC)) {
        w.add(SizingWarning(
          WarningLevel.critical,
          'No single conductor can carry: ${r.label}',
          'This run carries ${r.amps.toStringAsFixed(0)} A. The largest '
              'stocked conductor (${standardCableMm2.last.toStringAsFixed(0)} '
              'mm2) tops out below that at '
              '${input.cableAmbientC.toStringAsFixed(0)} degC ambient, so the '
              'size shown is the catalogue maximum rather than a sufficient '
              'one.',
          action: 'Raise the system voltage to cut the current, or run '
              'parallel conductors and fuse each one.',
        ));
      }
    }

    if (exceedsStandard(
        standardBreakerA, batteryToInverterA * _continuousFactor)) {
      w.add(SizingWarning(
        WarningLevel.critical,
        'Beyond standard overcurrent protection',
        'The battery isolator needs '
            '${(batteryToInverterA * _continuousFactor).toStringAsFixed(0)} A. '
            'The largest breaker in the catalogue is '
            '${standardBreakerA.last} A.',
        action: 'Raise the system voltage. Current falls in proportion, and '
            'losses fall with its square.',
      ));
    }

    // Roof area. Lecture 15 recommends budgeting 100-120 W/m2 of usable roof
    // rather than raw module area, to leave room for penetrations, walkways
    // and firefighter access.
    if (input.availableRoofM2 != null) {
      final usableRequirement = installedWp / 110; // m2 at 110 W/m2
      if (usableRequirement > input.availableRoofM2!) {
        w.add(SizingWarning(
          WarningLevel.critical,
          'Array will not fit',
          '$panelCount panels need about '
              '${usableRequirement.toStringAsFixed(1)} m2 of usable roof '
              '(${arrayAreaM2.toStringAsFixed(1)} m2 of module area plus '
              'access space). You have '
              '${input.availableRoofM2!.toStringAsFixed(1)} m2.',
          action: 'Reduce the load, use higher-efficiency modules, or extend '
              'the mounting area.',
        ));
      }
    }

    if (input.systemVoltage != null && systemVoltage != recommendedVoltage) {
      w.add(SizingWarning(
        WarningLevel.caution,
        'System voltage not optimal for this load',
        'A ${recommendedVoltage} V bus is recommended for this daily energy '
            '(CED R08-002 §8.4.1). At ${systemVoltage} V the currents, '
            'conductors and breakers are all larger.',
        action: 'Consider changing to ${recommendedVoltage} V.',
      ));
    }

    // CED §6.4.5: parallel banks circulate unwanted current between branches.
    if (batteryStrings > _maxParallelBatteryStrings) {
      w.add(SizingWarning(
        WarningLevel.caution,
        '$batteryStrings parallel battery strings',
        'More than three parallel strings tend to circulate current between '
            'branches, which shortens bank life (CED R08-002 §6.4.5).',
        action: 'Use higher-capacity units or raise the system voltage.',
      ));
    }

    w.add(SizingWarning(
      WarningLevel.info,
      'Controller PV input rating',
      'String open-circuit voltage reaches '
          '${stringVocCold.toStringAsFixed(0)} V in cold conditions. The '
          'controller must accept at least ${minVocRating} Vdc on its PV '
          'input.',
      action: 'Exceeding the controller maximum PV voltage destroys it '
          'immediately. Check the datasheet before purchase.',
    ));

    if (controllerCount > 1) {
      w.add(SizingWarning(
        WarningLevel.info,
        '$controllerCount charge controllers in parallel',
        'The array current exceeds what a single stocked controller can '
            'handle, so it is split across $controllerCount units.',
        action: 'Divide the strings evenly between controllers and give each '
            'unit its own breaker. Do not mix strings of different '
            'orientation on one controller.',
      ));
    }

    if (controllerType == ControllerType.pwm && installedWp > 1000) {
      w.add(const SizingWarning(
        WarningLevel.caution,
        'PWM controller on a large array',
        'PWM converts at roughly 70-75% against 95-98% for MPPT. Above 1 kW '
            'the lost generation usually exceeds the price difference.',
        action: 'Switch to MPPT.',
      ));
    }

    if (batteryToInverterA > 200) {
      w.add(SizingWarning(
        WarningLevel.caution,
        'High battery discharge current',
        'The battery-to-inverter run carries about '
            '${batteryToInverterA.toStringAsFixed(0)} A. Conductors, breakers '
            'and isolators at this rating are expensive and the losses are '
            'significant.',
        action: 'Raise the system voltage. Losses scale with the square of '
            'current: a 48 V bus has one sixteenth the loss of 12 V on the '
            'same conductor.',
      ));
    }

    if (dcDropTotal > 0.04) {
      w.add(SizingWarning(
        WarningLevel.caution,
        'DC voltage drop above budget',
        'Total DC drop is ${(dcDropTotal * 100).toStringAsFixed(2)}%, above '
            'the 4% limit in CED R08-002 §7.6.',
        action: 'Shorten the cable runs or increase conductor size.',
      ));
    }

    if (input.chemistry == BatteryChemistry.leadAcid &&
        input.autonomyDays > 3) {
      w.add(const SizingWarning(
        WarningLevel.info,
        'Large lead-acid bank',
        'At 50% depth of discharge the bank grows steeply with each extra day '
            'of autonomy. Lithium at 80% DoD needs roughly 60% of the '
            'capacity for the same usable energy.',
      ));
    }

    if (input.autonomyDays < 2) {
      w.add(const SizingWarning(
        WarningLevel.caution,
        'Autonomy below the usual minimum',
        'CED R08-002 §1.5.2 gives 2 to 6 days as typical for non-critical '
            'off-grid loads.',
      ));
    }

    if (largestMotorName != null) {
      w.add(SizingWarning(
        WarningLevel.info,
        'Motor load present',
        'Confirm the chosen inverter datasheet quotes a surge rating above '
            'the requirement. Continuous VA alone is not sufficient for '
            '$largestMotorName.',
      ));
    }

    if (input.pshMode == PshMode.annualAverage) {
      w.add(SizingWarning(
        WarningLevel.caution,
        'Sized on annual average sun hours',
        'The design month figure for ${input.city} is '
            '${worstMonthPsh(input.city).toStringAsFixed(2)} PSH against an '
            'average of ${avgPsh.toStringAsFixed(2)}. A system sized on the '
            'average will underperform through the rainy season.',
        action: 'Switch to worst-month sizing for year-round reliability.',
      ));
    }

    w.add(const SizingWarning(
      WarningLevel.info,
      'Protection devices are not optional',
      'The bill of materials includes DC-rated breakers, string fuses, surge '
          'protection and earthing. Omitting them is the most common cause of '
          'fire and lightning loss in Nigerian installations.',
    ));

    return w;
  }

  CostEstimate _estimateCost({
    required SizingInput input,
    required double installedWp,
    required int panelCount,
    required double installedBatteryAh,
    required int batteryCount,
    required int inverterW,
    required int controllerA,
    required List<CableRun> cableRuns,
  }) {
    double cabling = 0;
    for (final r in cableRuns) {
      // Two conductors per run, plus 15% for terminations and slack.
      cabling += r.selectedMm2 *
          r.lengthM *
          2 *
          1.15 *
          input.costs.perCableMm2PerMetre;
    }

    return CostEstimate(
      panels: installedWp * input.costs.perPanelWatt,
      batteries: batteryCount * input.batteryUnitAh * input.costs.perBatteryAh,
      inverter: inverterW * input.costs.perInverterWatt,
      controller: controllerA * input.costs.perControllerAmp,
      cabling: cabling,
      protection: input.costs.protectionPackage,
      mounting: panelCount * input.costs.mountingPerPanel,
      labour: input.costs.installationLabour,
    );
  }
}

class _StringConfig {
  final int series;
  final int parallel;
  final int totalPanels;
  const _StringConfig(this.series, this.parallel, this.totalPanels);
}
