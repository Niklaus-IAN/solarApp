// =============================================================================
// Fault diagnosis engine verification  —  Chapter 4.5
//
// Run with  flutter test test/fault_diagnosis_verification_test.dart
//
// System under test: the saved system from Section 4.2
//   12 V lithium, 1 x 400 W module (Voc 45.2, Vmpp 37.0, Isc 11.4), 1S1P
//
// Derived thresholds this produces:
//   battery low / critical / overcharge / absorption : 12.8 / 12.0 / 14.6 / 13.9 V
//   PV-002 trip      : v_panel < 18.08 V   (0.40 x 45.2)
//   CURR-001 trip    : v_panel > 18.50 V and current < 2.28 A
//   heavy-load gate  : |current| > 6.84 A
//   daylight gate    : t_panel > t_amb + 3
//   strong irradiance: t_panel > t_amb + 15
// =============================================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:solar_app/models/enums.dart';
import 'package:solar_app/models/panel_spec.dart';
import 'package:solar_app/models/system_config.dart';
import 'package:solar_app/services/fault_diagnosis_service.dart';

void main() {
  // ---------------------------------------------------------------- fixtures

  const testPanel = PanelSpec(
    name: '400W Mono (72-cell)',
    watts: 400, vmpp: 37.0, impp: 10.81, voc: 45.2, isc: 11.40,
    areaM2: 1.95, powerTempCoeffPct: -0.45,
  );

  SystemConfig systemWith(BatteryChemistry chemistry) => SystemConfig(
        panel: testPanel,
        panelCount: 1,
        panelsInSeries: 1,
        parallelStrings: 1,
        systemVoltage: 12,
        chemistry: chemistry,
        batteryBankAh: 200,
        inverterW: 1000,
        controllerA: 30,
        controllerType: ControllerType.mppt,
      );

  SystemConfig testSystem() => systemWith(BatteryChemistry.lithium);
  SystemConfig leadAcidSystem() => systemWith(BatteryChemistry.leadAcid);

  SensorData packet({
    required double vPanel,
    required double vBatt,
    required double current,
    required double tPanel,
    required double tAmb,
  }) =>
      SensorData(
        panelVoltage: vPanel,
        batteryVoltage: vBatt,
        current: current,
        panelTemp: tPanel,
        ambientTemp: tAmb,
        power: vPanel * current,
        timestamp: DateTime.now(),
      );

  /// Feeds the same packet three times to satisfy the debounce rule and
  /// returns the final report.
  DiagnosisReport diagnose(FaultDiagnosisService svc, SensorData p) {
    late DiagnosisReport report;
    for (var i = 0; i < 3; i++) {
      report = svc.diagnose(p);
    }
    return report;
  }

  /// Extracts the raised fault codes as a sorted list of strings.
  List<String> codesOf(DiagnosisReport report) {
    final codes = report.faults.map((f) => f.code).toList()..sort();
    return codes;
  }

  // =========================================================== 4.5.2 matrix

  group('4.5.2  Fault code test matrix', () {
    late FaultDiagnosisService svc;
    setUp(() => svc = FaultDiagnosisService(testSystem()));

    test('Case 1  Normal daytime operation -> no faults, health 100', () {
      final r = diagnose(svc, packet(
          vPanel: 37.0, vBatt: 13.2, current: 8.5, tPanel: 55, tAmb: 32));
      expect(codesOf(r), isEmpty);
      expect(r.healthScore, 100);
    });

    test('Case 2  Panel disconnected -> PV-001, health 70', () {
      final r = diagnose(svc, packet(
          vPanel: 0.4, vBatt: 13.0, current: 0.0, tPanel: 42, tAmb: 32));
      expect(codesOf(r), contains('PV-001'));
      expect(r.healthScore, 70);
    });

    test('Case 3  Heavy shading -> PV-002, health 80', () {
      final r = diagnose(svc, packet(
          vPanel: 15.0, vBatt: 13.0, current: 3.0, tPanel: 42, tAmb: 32));
      expect(codesOf(r), contains('PV-002'));
      expect(r.healthScore, 80);
    });

    test('Case 4  Loose connection -> CURR-001, health 80', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.0, current: 1.5, tPanel: 42, tAmb: 32));
      expect(codesOf(r), contains('CURR-001'));
      expect(r.healthScore, 80);
    });

    test('Case 5  Critical underperformance -> PERF-001, health 70', () {
      final r = diagnose(svc, packet(
          vPanel: 25.0, vBatt: 13.2, current: 2.77, tPanel: 55, tAmb: 32));
      expect(codesOf(r), contains('PERF-001'));
      expect(r.healthScore, 70);
    });

    test('Case 6  Significant underperformance -> PERF-002, health 80', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.2, current: 3.84, tPanel: 55, tAmb: 32));
      expect(codesOf(r), contains('PERF-002'));
      expect(r.healthScore, 80);
    });

    test('Case 7  Moderate underperformance -> PERF-003, health 90', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.2, current: 5.77, tPanel: 55, tAmb: 32));
      expect(codesOf(r), contains('PERF-003'));
      expect(r.healthScore, 90);
    });

    test('Case 8  Battery low -> BATT-001, health 90', () {
      final r = diagnose(svc, packet(
          vPanel: 0.0, vBatt: 12.5, current: 2.0, tPanel: 28, tAmb: 30));
      expect(codesOf(r), contains('BATT-001'));
      expect(r.healthScore, 90);
    });

    test('Case 9  Battery critically discharged -> BATT-002, health 70', () {
      final r = diagnose(svc, packet(
          vPanel: 0.0, vBatt: 11.6, current: 2.0, tPanel: 28, tAmb: 30));
      expect(codesOf(r), contains('BATT-002'));
      expect(r.healthScore, 70);
    });

    test('Case 10 Battery overcharge -> BATT-003, health 80', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 15.0, current: 5.0, tPanel: 42, tAmb: 32));
      expect(codesOf(r), contains('BATT-003'));
      expect(r.healthScore, 80);
    });

    test('Case 11 Poor ventilation -> TEMP-002, health 90', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.2, current: 7.78, tPanel: 75, tAmb: 32));
      expect(codesOf(r), contains('TEMP-002'));
      expect(r.healthScore, 90);
    });

    test('Case 12 Hotspot risk -> TEMP-001, health 70', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.2, current: 7.16, tPanel: 88, tAmb: 32));
      expect(codesOf(r), contains('TEMP-001'));
      expect(r.healthScore, 70);
    });

    test('Case 13 Night-time -> daylight codes suppressed, health 100', () {
      final r = diagnose(svc, packet(
          vPanel: 0.0, vBatt: 13.0, current: 0.0, tPanel: 26, tAmb: 27));
      expect(codesOf(r), isEmpty);
      expect(r.healthScore, 100);
    });

    test('Case 14 Controller regulating -> current/perf suppressed, health 100', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 14.2, current: 0.8, tPanel: 50, tAmb: 32));
      expect(codesOf(r), isEmpty);
      expect(r.healthScore, 100);
    });

    test('Case 15 Heavy load -> battery checks suppressed, health 100', () {
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 12.4, current: 8.0, tPanel: 50, tAmb: 32));
      expect(codesOf(r), isEmpty);
      expect(r.healthScore, 100);
    });

    test('Case 16 Four simultaneous faults -> score clamped at 0', () {
      final r = diagnose(svc, packet(
          vPanel: 15.0, vBatt: 11.8, current: 1.0, tPanel: 88, tAmb: 32));
      expect(codesOf(r),
          containsAll(['PV-002', 'BATT-002', 'TEMP-001', 'PERF-001']));
      expect(r.healthScore, 0);
    });
  });

  // ======================================================== 4.5.2 debounce

  group('4.5.2  Debounce', () {
    test('fault raises only on the third consecutive reading', () {
      final svc = FaultDiagnosisService(testSystem());
      final faulty = packet(
          vPanel: 15.0, vBatt: 13.0, current: 3.0, tPanel: 42, tAmb: 32);

      expect(codesOf(svc.diagnose(faulty)), isEmpty, reason: 'reading 1');
      expect(codesOf(svc.diagnose(faulty)), isEmpty, reason: 'reading 2');
      expect(codesOf(svc.diagnose(faulty)), contains('PV-002'),
          reason: 'reading 3');
    });

    test('clearing the condition resets the streak', () {
      final svc = FaultDiagnosisService(testSystem());
      final faulty = packet(
          vPanel: 15.0, vBatt: 13.0, current: 3.0, tPanel: 42, tAmb: 32);
      final healthy = packet(
          vPanel: 37.0, vBatt: 13.2, current: 8.5, tPanel: 42, tAmb: 32);

      svc.diagnose(faulty);
      svc.diagnose(faulty);
      svc.diagnose(healthy);          // streak broken
      expect(codesOf(svc.diagnose(faulty)), isEmpty,
          reason: 'streak restarted');
      svc.diagnose(faulty);
      expect(codesOf(svc.diagnose(faulty)), contains('PV-002'));
    });
  });

  // ============================================ 4.5.3 threshold adaptation

  group('4.5.3  Thresholds derive from the saved system', () {
    SensorData nightPacket(double v) => SensorData(
          panelVoltage: 0.0, batteryVoltage: v, current: 2.0,
          panelTemp: 28, ambientTemp: 30, power: 0.0,
          timestamp: DateTime.now(),
        );

    test('12.5 V raises BATT-001 on lithium (low 12.8 V)', () {
      final svc = FaultDiagnosisService(testSystem());
      expect(codesOf(diagnose(svc, nightPacket(12.5))), contains('BATT-001'));
    });

    test('12.5 V raises nothing on lead-acid (low 12.2 V)', () {
      final svc = FaultDiagnosisService(leadAcidSystem());
      expect(codesOf(diagnose(svc, nightPacket(12.5))), isEmpty);
    });
  });

  // ========================================== 4.5.4 limitations identified

  group('4.5.4  Limitations', () {
    test('Case 17  healthy PWM operating point falsely raises PV-002', () {
      final svc = FaultDiagnosisService(testSystem());
      final r = diagnose(svc, packet(
          vPanel: 13.8, vBatt: 13.2, current: 10.5, tPanel: 55, tAmb: 32));
      // A healthy 400 W module on a PWM controller sits at battery voltage.
      expect(codesOf(r), contains('PV-002'));
      expect(codesOf(r), contains('PERF-002'));
      expect(r.healthScore, 60);
    });

    test('Case 18  healthy module at moderate irradiance raises PERF-003', () {
      final svc = FaultDiagnosisService(testSystem());
      // 600 W/m2, panel 19 C above ambient: 205 W is correct output here.
      final r = diagnose(svc, packet(
          vPanel: 36.0, vBatt: 13.2, current: 5.7, tPanel: 51, tAmb: 32));
      expect(codesOf(r), contains('PERF-003'));
    });
  });
}
