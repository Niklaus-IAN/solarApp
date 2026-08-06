// Headless unit tests for the rebuilt sizing and diagnosis engines.
//
// These exercise pure Dart logic only (no BLE / sqflite plugins), so they run
// under `flutter test` without a device.

import 'package:flutter_test/flutter_test.dart';

import 'package:solar_app/models/appliance.dart';
import 'package:solar_app/models/enums.dart';
import 'package:solar_app/models/sizing_input.dart';
import 'package:solar_app/models/saved_system.dart';
import 'package:solar_app/services/sizing_service.dart';
import 'package:solar_app/services/fault_diagnosis_service.dart';

void main() {
  group('SizingService', () {
    test('produces a buildable system from a simple load', () {
      final result = const SizingService().calculate(SizingInput(
        appliances: [
          Appliance(
              id: '1', name: 'LED bulb', watts: 10, quantity: 6, hoursPerDay: 6),
          Appliance(
              id: '2',
              name: 'Fridge',
              watts: 540,
              hoursPerDay: 24,
              dutyCycle: 0.14,
              surgeFactor: 3.0),
        ],
        city: 'Lagos',
        chemistry: BatteryChemistry.lithium,
        autonomyDays: 2,
      ));

      expect(result.panelCount, greaterThan(0));
      expect(result.inverterW, greaterThan(0));
      expect([12, 24, 48], contains(result.systemVoltage));
      expect(result.batteryCount, greaterThan(0));
      expect(result.totalSystemFactor, inInclusiveRange(0.4, 0.7));
      // Worst-month sizing must not need less array than the annual average.
      expect(result.requiredArrayWp,
          greaterThanOrEqualTo(result.requiredArrayWpAnnualAverage));
    });

    test('recommends a voltage tier from daily energy', () {
      final small = const SizingService().calculate(SizingInput(
        appliances: [
          Appliance(id: '1', name: 'LED', watts: 10, quantity: 2, hoursPerDay: 4),
        ],
        city: 'Lagos',
      ));
      expect(small.systemVoltageWasRecommended, isTrue);
    });
  });

  group('FaultDiagnosisService', () {
    test('a healthy daytime packet stays in range and is seen as daytime', () {
      final diag =
          FaultDiagnosisService(defaultSystemConfig(), debounceCount: 1);
      final report = diag.diagnose(SensorData(
        panelVoltage: 70,
        batteryVoltage: 26,
        current: 20,
        panelTemp: 55, // strong sun: >15C above ambient
        ambientTemp: 32,
        power: 1600,
        timestamp: DateTime.now(),
      ));
      expect(report.healthScore, inInclusiveRange(0, 100));
      expect(report.isDaytime, isTrue);
    });

    test('a disconnected panel in daylight raises PV-001 after debounce', () {
      final diag =
          FaultDiagnosisService(defaultSystemConfig(), debounceCount: 3);
      DiagnosisReport? report;
      for (var i = 0; i < 3; i++) {
        report = diag.diagnose(SensorData(
          panelVoltage: 0, // dead panel
          batteryVoltage: 25,
          current: 0,
          panelTemp: 50, // still hot in the sun -> daylight gate open
          ambientTemp: 32,
          power: 0,
          timestamp: DateTime.now(),
        ));
      }
      expect(report!.faults.any((f) => f.code == 'PV-001'), isTrue);
    });
  });
}
