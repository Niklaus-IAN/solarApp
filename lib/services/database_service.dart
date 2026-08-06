import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
// SensorData and FaultCode now live with the rebuilt fault engine.
import 'fault_diagnosis_service.dart' show SensorData, FaultCode;
import '../models/system_config.dart';
import '../models/saved_system.dart';

/// Singleton database service for persisting health readings and fault events.
class DatabaseService extends ChangeNotifier {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  /// Get or create the database
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'solar_obd.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: _createTables,
      onUpgrade: _onUpgrade,
    );
  }

  /// Migrations for databases created by an earlier app version.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSavedSystemsTable(db);
    }
  }

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE health_readings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        health_score INTEGER NOT NULL,
        panel_voltage REAL NOT NULL,
        battery_voltage REAL NOT NULL,
        current_amps REAL NOT NULL,
        power REAL NOT NULL,
        panel_temp REAL NOT NULL,
        ambient_temp REAL NOT NULL,
        fault_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE fault_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        cleared_at TEXT,
        code TEXT NOT NULL,
        severity TEXT NOT NULL,
        condition_text TEXT NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_readings_timestamp ON health_readings(timestamp)'
    );
    await db.execute(
      'CREATE INDEX idx_faults_timestamp ON fault_events(timestamp)'
    );

    await _createSavedSystemsTable(db);
  }

  /// Named system configurations the user has saved. Each holds a full
  /// [SystemConfig] as JSON, tagged by how it was created ('sized' vs
  /// 'existing'). Exactly one row may be flagged active — the system the
  /// monitoring screen is currently diagnosing against.
  Future<void> _createSavedSystemsTable(Database db) async {
    await db.execute('''
      CREATE TABLE saved_systems (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        config_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ===== HEALTH READINGS =====

  /// Insert a new health reading with sensor data and diagnosis results
  Future<void> insertReading({
    required SensorData data,
    required int healthScore,
    required int faultCount,
  }) async {
    final db = await database;
    await db.insert('health_readings', {
      'timestamp': DateTime.now().toIso8601String(),
      'health_score': healthScore,
      'panel_voltage': data.panelVoltage,
      'battery_voltage': data.batteryVoltage,
      'current_amps': data.current,
      'power': data.power,
      'panel_temp': data.panelTemp,
      'ambient_temp': data.ambientTemp,
      'fault_count': faultCount,
    });
    notifyListeners();
  }

  /// Get health readings for a given period
  Future<List<Map<String, dynamic>>> getReadings({required String period}) async {
    final db = await database;
    String whereClause = _periodWhereClause(period);

    return await db.query(
      'health_readings',
      where: whereClause.isNotEmpty ? 'timestamp >= ?' : null,
      whereArgs: whereClause.isNotEmpty ? [whereClause] : null,
      orderBy: 'timestamp DESC',
      limit: 50,
    );
  }

  // ===== FAULT EVENTS =====

  /// Insert a new fault event
  Future<void> insertFault(FaultCode fault) async {
    final db = await database;
    await db.insert('fault_events', {
      'timestamp': DateTime.now().toIso8601String(),
      'cleared_at': null,
      'code': fault.code,
      // Severity is now an enum; store the upper-case name so existing
      // history queries and AppTheme.severityColor keep working unchanged.
      'severity': fault.severity.name.toUpperCase(),
      'condition_text': fault.title,
    });
    notifyListeners();
  }

  /// Mark active faults as cleared (faults with matching code that haven't been cleared)
  Future<void> clearFaults(List<String> activeFaultCodes) async {
    final db = await database;
    String now = DateTime.now().toIso8601String();

    // Clear any faults that are NOT in the active list
    await db.rawUpdate('''
      UPDATE fault_events 
      SET cleared_at = ?
      WHERE cleared_at IS NULL 
        AND code NOT IN (${activeFaultCodes.map((_) => '?').join(',')})
    ''', [now, ...activeFaultCodes]);
    notifyListeners();
  }

  /// Get fault events for a given period
  Future<List<Map<String, dynamic>>> getFaults({required String period}) async {
    final db = await database;
    String whereClause = _periodWhereClause(period);

    return await db.query(
      'fault_events',
      where: whereClause.isNotEmpty ? 'timestamp >= ?' : null,
      whereArgs: whereClause.isNotEmpty ? [whereClause] : null,
      orderBy: 'timestamp DESC',
      limit: 50,
    );
  }

  // ===== SAVED SYSTEMS =====

  /// Persist a named system configuration. Returns the new row id.
  Future<int> saveSystem({
    required String name,
    required SystemSource source,
    required SystemConfig config,
    bool makeActive = true,
  }) async {
    final db = await database;
    final id = await db.insert('saved_systems', {
      'name': name,
      'source': source.name,
      'config_json': jsonEncode(config.toJson()),
      'created_at': DateTime.now().toIso8601String(),
      'is_active': 0,
    });
    if (makeActive) await setActiveSystem(id);
    notifyListeners();
    return id;
  }

  /// All saved systems, most recent first.
  Future<List<SavedSystem>> getSavedSystems() async {
    final db = await database;
    final rows = await db.query('saved_systems', orderBy: 'created_at DESC');
    return rows.map(SavedSystem.fromRow).toList();
  }

  /// The system currently selected for monitoring, or the most recent one if
  /// none is explicitly flagged. Null when the user has saved nothing yet.
  Future<SavedSystem?> getActiveSystem() async {
    final db = await database;
    final active = await db.query('saved_systems',
        where: 'is_active = 1', limit: 1);
    if (active.isNotEmpty) return SavedSystem.fromRow(active.first);
    final recent =
        await db.query('saved_systems', orderBy: 'created_at DESC', limit: 1);
    return recent.isEmpty ? null : SavedSystem.fromRow(recent.first);
  }

  /// Flag one system active and clear the flag on every other.
  Future<void> setActiveSystem(int id) async {
    final db = await database;
    await db.update('saved_systems', {'is_active': 0});
    await db.update('saved_systems', {'is_active': 1},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// Delete a saved system.
  Future<void> deleteSystem(int id) async {
    final db = await database;
    await db.delete('saved_systems', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // ===== SUMMARY STATISTICS =====

  /// Get summary stats for a period: avg score, total faults, avg power
  Future<Map<String, dynamic>> getSummaryStats({required String period}) async {
    final db = await database;
    String whereClause = _periodWhereClause(period);
    String whereSQL = whereClause.isNotEmpty ? 'WHERE timestamp >= ?' : '';
    List<dynamic> args = whereClause.isNotEmpty ? [whereClause] : [];

    // Average health score and power
    final readingStats = await db.rawQuery('''
      SELECT 
        AVG(health_score) as avg_score,
        AVG(power) as avg_power,
        COUNT(*) as reading_count
      FROM health_readings $whereSQL
    ''', args);

    // Total fault count
    final faultStats = await db.rawQuery('''
      SELECT COUNT(*) as total_faults
      FROM fault_events $whereSQL
    ''', args);

    double avgScore = 0;
    double avgPower = 0;
    int readingCount = 0;
    int totalFaults = 0;

    if (readingStats.isNotEmpty) {
      avgScore = (readingStats.first['avg_score'] as num?)?.toDouble() ?? 0;
      avgPower = (readingStats.first['avg_power'] as num?)?.toDouble() ?? 0;
      readingCount = (readingStats.first['reading_count'] as num?)?.toInt() ?? 0;
    }
    if (faultStats.isNotEmpty) {
      totalFaults = (faultStats.first['total_faults'] as num?)?.toInt() ?? 0;
    }

    return {
      'avgScore': avgScore.round(),
      'avgPower': avgPower,
      'readingCount': readingCount,
      'totalFaults': totalFaults,
    };
  }

  // ===== HELPERS =====

  /// Convert period string to an ISO timestamp for the start of that period
  String _periodWhereClause(String period) {
    DateTime now = DateTime.now();
    DateTime start;

    switch (period) {
      case 'Today':
        start = DateTime(now.year, now.month, now.day);
        break;
      case '7 Days':
        start = now.subtract(const Duration(days: 7));
        break;
      case '30 Days':
        start = now.subtract(const Duration(days: 30));
        break;
      default:
        return '';
    }

    return start.toIso8601String();
  }

  /// Close the database
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
