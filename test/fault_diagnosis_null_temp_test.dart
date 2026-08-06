import 'package:flutter_test/flutter_test.dart';
import 'package:solar_app/models/saved_system.dart';
import 'package:solar_app/services/fault_diagnosis_service.dart';

/// Regression tests for correction 5: a missing temperature probe must be
/// distinguishable from 0 degC.
///
/// The bug these lock down: the BLE layer coerced the firmware's `null` to
/// 0.0, which turned the daylight gate (`panelTemp > ambientTemp + 3`) into
/// `panelTemp > 3` — true for any panel in Lagos, day or night. Every
/// daylight-only check therefore ran continuously against a fabricated ambient
/// reading, and a suppressed diagnosis was rendered as a passing one.
void main() {
  final config = defaultSystemConfig();

  /// Debounce is 3 by default; the engine only raises a code once a condition
  /// has held for that many consecutive packets.
  DiagnosisReport runFor(FaultDiagnosisService diag, SensorData d,
      {int packets = 3}) {
    late DiagnosisReport report;
    for (var i = 0; i < packets; i++) {
      report = diag.diagnose(d);
    }
    return report;
  }

  SensorData reading({
    double panelVoltage = 0.0,
    double batteryVoltage = 26.0,
    double current = 0.0,
    double? panelTemp,
    double? ambientTemp,
    double power = 0.0,
  }) =>
      SensorData(
        panelVoltage: panelVoltage,
        batteryVoltage: batteryVoltage,
        current: current,
        panelTemp: panelTemp,
        ambientTemp: ambientTemp,
        power: power,
        uptimeSeconds: 1,
        timestamp: DateTime(2026, 8, 6, 13),
      );

  group('daylight gate with a missing probe', () {
    test('ambient null suppresses PV-001 instead of firing it', () {
      final diag = FaultDiagnosisService(config);
      // A dead panel at midday: 0 V, module hot in the sun. With both probes
      // this is an unambiguous PV-001.
      final report = runFor(
        diag,
        reading(panelVoltage: 0.0, panelTemp: 55.0, ambientTemp: null),
      );

      expect(report.daylightDetermined, isFalse);
      expect(report.isDaytime, isFalse,
          reason: 'undetermined must not collapse to "daytime"');
      expect(report.faults.map((f) => f.code), isNot(contains('PV-001')));
      expect(report.isPartialAssessment, isTrue);
    });

    test('the same reading with both probes does fire PV-001', () {
      final diag = FaultDiagnosisService(config);
      final report = runFor(
        diag,
        reading(panelVoltage: 0.0, panelTemp: 55.0, ambientTemp: 33.0),
      );

      expect(report.daylightDetermined, isTrue);
      expect(report.isDaytime, isTrue);
      expect(report.faults.map((f) => f.code), contains('PV-001'));
      expect(report.isPartialAssessment, isFalse);
    });

    test('a null ambient is not treated as 0 degC', () {
      // The old coercion made this read as daytime (55 > 0 + 3). If that
      // regressed, isDaytime would be true here.
      final diag = FaultDiagnosisService(config);
      final report = runFor(diag, reading(panelTemp: 55.0, ambientTemp: null));
      expect(report.isDaytime, isFalse);
    });

    test('panel, current and performance are reported as unavailable', () {
      final diag = FaultDiagnosisService(config);
      final report = runFor(diag, reading(panelTemp: 55.0, ambientTemp: null));
      expect(
        report.unavailableDomains,
        containsAll([
          FaultDomain.panel,
          FaultDomain.current,
          FaultDomain.performance,
        ]),
      );
    });

    test('summary states the assessment is partial, not clean', () {
      final diag = FaultDiagnosisService(config);
      final report = runFor(diag, reading(panelTemp: 55.0, ambientTemp: null));
      expect(report.summary, contains('ambient temperature probe'));
      expect(report.summary, contains('partial assessment'));
      expect(report.summary, isNot(contains('No faults detected.')));
    });
  });

  group('checks that survive a missing ambient probe', () {
    test('TEMP-001 still fires on panel temp alone', () {
      final diag = FaultDiagnosisService(config);
      final report = runFor(
        diag,
        reading(panelTemp: 90.0, ambientTemp: null),
      );
      expect(report.faults.map((f) => f.code), contains('TEMP-001'));
    });

    test('battery checks still fire with both probes missing', () {
      final diag = FaultDiagnosisService(config);
      // 24 V lithium: critical is 12.0 * 2 blocks = 24.0 V.
      final report = runFor(
        diag,
        reading(batteryVoltage: 22.0, panelTemp: null, ambientTemp: null),
      );
      expect(report.faults.map((f) => f.code), contains('BATT-002'));
      expect(report.summary, contains('Neither temperature probe'));
    });
  });

  group('temperature checks with no panel probe', () {
    test('TEMP codes are suppressed rather than defaulting to 0', () {
      final diag = FaultDiagnosisService(config);
      final report = runFor(
        diag,
        reading(panelTemp: null, ambientTemp: 33.0),
      );
      final codes = report.faults.map((f) => f.code);
      expect(codes, isNot(contains('TEMP-001')));
      expect(codes, isNot(contains('TEMP-002')));
      expect(report.panelTempAvailable, isFalse);
      expect(report.isPartialAssessment, isTrue);
    });
  });

  group('full sensing is unaffected', () {
    test('a healthy daylight reading reports no faults and no degradation', () {
      final diag = FaultDiagnosisService(config);
      // Default config: 8 x 300 W, 2 in series, 4 strings, 24 V lithium.
      //   arrayVoc 79.0 V   arrayVmpp 65.0 V   arrayIsc 39.2 A   rated 2400 W
      //   batteryLow 25.6 V   absorption 27.8 V
      // So this reading must sit above batteryLow but below absorption (or the
      // controller reads as regulating), and deliver >0.75 of the
      // temperature-corrected expectation (~2141 W at 52 degC).
      final report = runFor(
        diag,
        reading(
          panelVoltage: 68.0,
          batteryVoltage: 26.5,
          current: 18.0,
          panelTemp: 52.0,
          ambientTemp: 33.0,
          power: 1950.0,
        ),
      );
      expect(report.daylightDetermined, isTrue);
      expect(report.isPartialAssessment, isFalse);
      expect(report.faults, isEmpty);
      expect(report.healthScore, 100);
    });
  });
}
