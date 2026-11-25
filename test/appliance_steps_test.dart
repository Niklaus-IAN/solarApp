import 'package:flutter_test/flutter_test.dart';
import 'package:solar_app/data/appliance_presets.dart';
import 'package:solar_app/data/standard_sizes.dart';
import 'package:solar_app/models/appliance.dart';
import 'package:solar_app/models/enums.dart';
import 'package:solar_app/models/panel_spec.dart';
import 'package:solar_app/models/sizing_input.dart';
import 'package:solar_app/services/sizing_service.dart';

/// Covers the stepped-preset additions and the over-range guard they made
/// reachable. The engine itself is unchanged apart from the new warnings.
void main() {
  group('preset library integrity', () {
    test('every stepped family has usable steps and a valid default', () {
      final stepped = appliancePresets.where((p) => p.isStepped).toList();
      expect(stepped, isNotEmpty);

      for (final p in stepped) {
        expect(p.steps.length, greaterThan(1),
            reason: '${p.name} is stepped but has one step');
        expect(p.defaultStepIndex, inInclusiveRange(0, p.steps.length - 1),
            reason: '${p.name} default index is out of range');
        for (final s in p.steps) {
          expect(s.watts, greaterThan(0), reason: '${p.name} ${s.label}');
          expect(s.label.trim(), isNotEmpty);
        }
      }
    });

    test('plain presets are untouched by the stepped constructor', () {
      final led = findPreset('LED bulb')!;
      expect(led.isStepped, isFalse);
      expect(led.minWatts, 7);
      expect(led.maxWatts, 12);
      expect(led.typicalWatts, 9.5);
      expect(led.isRange, isTrue);
    });

    test('the CRT rows survive relabelled, so the source figures stay visible',
        () {
      expect(findPreset('TV 19" CRT')!.typicalWatts, 70);
      expect(findPreset('TV 25" CRT')!.typicalWatts, 150);
    });

    test('air conditioner watts are BTU/EER derived, not 746 x HP', () {
      final ac = findPreset('Air conditioner')!;
      expect(ac.steps.first.label, '1 HP');
      expect(ac.steps.first.watts, 1000); // not 746
      expect(ac.steps.last.label, '10 HP');
      expect(ac.steps.last.watts, 11500); // not 7460
    });

    test('heating splits on-demand from thermostatic', () {
      expect(findPreset('Heating equipment')!.dutyCycle, 1.0);
      expect(findPreset('Water / room heater')!.dutyCycle, 0.35);
      expect(findPreset('Heating equipment')!.steps.length, 22);
    });

    test('low-wattage standing fans stay AC — they must not bypass the '
        'inverter efficiency divide', () {
      expect(findPreset('Standing fan')!.loadType, LoadType.ac);
    });

    test('categories gained Heating and kept their order', () {
      expect(applianceCategories, contains('Heating'));
      expect(applianceCategories.indexOf('Kitchen'),
          lessThan(applianceCategories.indexOf('Heating')));
    });
  });

  group('toAppliance from a step', () {
    test('names the load with its size and honours quantity', () {
      final fan = findPreset('Standing fan')!;
      final step = fan.steps[8]; // 50 W
      final a = fan.toAppliance('x1',
          watts: step.watts, quantity: 2, stepLabel: step.label);

      expect(a.name, 'Standing fan 50 W');
      expect(a.watts, 50);
      expect(a.quantity, 2);
      expect(a.runningW, 100);
      expect(a.dailyWh, 50 * 2 * 8); // 8 h default, duty 1.0
      expect(a.surgeW, 100 * 2.0);
    });

    test('a thermostatic heater carries its duty cycle into the energy', () {
      final h = findPreset('Water / room heater')!;
      final step = h.steps[5]; // 3000 W
      final a =
          h.toAppliance('x2', watts: step.watts, stepLabel: step.label);

      expect(a.watts, 3000);
      expect(a.dutyCycle, 0.35);
      expect(a.dailyWh, closeTo(3000 * 3 * 0.35, 0.001)); // 3150, not 9000
    });
  });

  group('over-range guard', () {
    test('predicates agree with what nextStandard actually returned', () {
      expect(exceedsStandard(standardInverterW, 46000), isTrue);
      expect(nextStandard(standardInverterW, 46000), standardInverterW.last);

      expect(exceedsStandard(standardInverterW, 4600), isFalse);
      expect(nextStandard(standardInverterW, 4600), 5000);

      expect(exceedsAmpacity(500), isTrue);
      expect(exceedsAmpacity(50), isFalse);
      expect(exceedsStandardCable(200), isTrue);
    });

    test('a 10 HP air conditioner raises a critical warning instead of '
        'silently clamping to 15 kW', () {
      final ac = findPreset('Air conditioner')!;
      final step = ac.steps.last; // 10 HP
      final input = SizingInput(
        appliances: [
          ac.toAppliance('a1', watts: step.watts, stepLabel: step.label),
        ],
        city: 'Lagos',
        panel: panelPresets['630W Mono (210 n-type TOPCon)']!,
      );

      final r = const SizingService().calculate(input);

      // The engine still returns the clamped size — it is the only value it
      // has — but it now says so.
      expect(r.inverterW, standardInverterW.last);
      expect(r.inverterMinimumW, greaterThan(standardInverterW.last.toDouble()));

      final overRange = r.warnings.where((w) =>
          w.level == WarningLevel.critical &&
          w.title.contains('single-phase inverter'));
      expect(overRange, hasLength(1),
          reason: 'the clamp must be reported, not hidden');
    });

    test('an ordinary house raises no over-range warning', () {
      final input = SizingInput(
        appliances: [
          findPreset('LED bulb')!.toAppliance('a1'),
          findPreset('Refrigerator/Freezer 20cf')!.toAppliance('a2'),
          findPreset('TV, LED')!.toAppliance('a3', watts: 65, stepLabel: '43"'),
        ],
        city: 'Lagos',
      );

      final r = const SizingService().calculate(input);

      expect(r.inverterMinimumW,
          lessThanOrEqualTo(standardInverterW.last.toDouble()));
      expect(
        r.warnings.where((w) => w.title.contains('Beyond')),
        isEmpty,
      );
    });
  });

  group('n-type panel specs', () {
    test('carry the TOPCon temperature coefficient, not the p-type default',
        () {
      final p = panelPresets['800W Mono (210 n-type TOPCon)']!;
      expect(p.powerTempCoeffPct, -0.30);

      // NOCT method at Lagos: 32 degC ambient, 1000 W/m2.
      final tCell = p.cellTemperature(ambientC: 32);
      expect(tCell, closeTo(63.25, 0.01));

      // The coefficient is worth ~6.9% of the module's output at that
      // temperature against the -0.45 default.
      expect(p.temperatureDerate(tCell), closeTo(0.8853, 0.0005));

      final asPType = PanelSpec(
        name: 'control', watts: 800, vmpp: 43.7, impp: 18.3,
        voc: 51.5, isc: 19.4, areaM2: 3.20,
      );
      expect(asPType.temperatureDerate(tCell), closeTo(0.8279, 0.0005));
    });

    test('cold Voc constrains strings the way the 300 W module does not', () {
      final big = panelPresets['800W Mono (210 n-type TOPCon)']!;
      final small = panelPresets['300W Mono (60-cell)']!;

      expect(big.vocCold, closeTo(57.68, 0.01));
      expect(small.vocCold, closeTo(44.24, 0.01));

      // Two 800 W modules in series already pass the 100 V controller class.
      expect(big.vocCold * 2, greaterThan(100));
      expect(small.vocCold * 2, lessThan(100));
    });

    test('string current doubles protection and cable size', () {
      final big = panelPresets['800W Mono (210 n-type TOPCon)']!;
      final small = panelPresets['300W Mono (60-cell)']!;

      expect(nextStandard(standardBreakerA, big.isc * 1.56), 32);
      expect(nextStandard(standardBreakerA, small.isc * 1.56), 16);

      expect(cableForAmpacity(big.isc, ambientC: 40), 4);
      expect(cableForAmpacity(small.isc, ambientC: 40), 1.5);
    });
  });
}
