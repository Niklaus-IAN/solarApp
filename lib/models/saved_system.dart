import 'dart:convert' show jsonDecode;

import 'enums.dart';
import 'panel_spec.dart';
import 'system_config.dart';

/// A sensible fallback configuration for the monitoring engine before the user
/// has saved any system of their own — a common 24 V lithium household setup.
/// Once a real system is saved and selected, that one is used instead.
SystemConfig defaultSystemConfig() => SystemConfig(
      panel: defaultPanel,
      panelCount: 8,
      panelsInSeries: 2,
      parallelStrings: 4,
      systemVoltage: 24,
      chemistry: BatteryChemistry.lithium,
      batteryBankAh: 400,
      inverterW: 1500,
      controllerA: 80,
      controllerType: ControllerType.mppt,
    );

/// How a saved system's configuration was created.
///
/// * [sized]    — produced by the sizing calculator (a system being planned).
/// * [existing] — entered by the user for a system already installed, so the
///   monitoring engine can derive correct thresholds for it.
enum SystemSource {
  sized,
  existing;

  String get label => this == sized ? 'Sized' : 'Existing';
}

/// A named [SystemConfig] the user has stored, so it can be referenced again
/// and selected as the system currently being monitored.
///
/// This is the object that lets the app hold several installations at once
/// (home, shop, clinic…) and is the bridge between the sizing calculator and
/// the fault diagnosis engine.
class SavedSystem {
  final int id;
  final String name;
  final SystemSource source;
  final SystemConfig config;
  final DateTime createdAt;
  final bool isActive;

  const SavedSystem({
    required this.id,
    required this.name,
    required this.source,
    required this.config,
    required this.createdAt,
    this.isActive = false,
  });

  factory SavedSystem.fromRow(Map<String, dynamic> row) => SavedSystem(
        id: (row['id'] as num).toInt(),
        name: row['name'] as String,
        source: SystemSource.values.byName(row['source'] as String),
        config: SystemConfig.fromJson(
          _decode(row['config_json'] as String),
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
        isActive: (row['is_active'] as num?)?.toInt() == 1,
      );

  static Map<String, dynamic> _decode(String s) =>
      Map<String, dynamic>.from(jsonDecode(s) as Map);
}
