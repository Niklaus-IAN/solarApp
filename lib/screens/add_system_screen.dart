import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/enums.dart';
import '../models/panel_spec.dart';
import '../models/system_config.dart';
import '../models/saved_system.dart';
import '../services/database_service.dart';

/// Form for registering a solar system that is *already installed*, so the
/// monitoring engine can derive thresholds for it.
///
/// This captures the simplified essentials — voltage, chemistry, battery bank,
/// panel wattage/count, inverter and controller ratings. Electrical detail the
/// fault engine needs (Voc/Vmpp/Isc, NOCT) is taken from the nearest datasheet
/// preset by wattage, and the string arrangement is estimated from the bus
/// voltage. Both are approximations, which is the accepted trade-off for a
/// quick "add what I've got" flow.
class AddSystemScreen extends StatefulWidget {
  const AddSystemScreen({super.key});

  @override
  State<AddSystemScreen> createState() => _AddSystemScreenState();
}

class _AddSystemScreenState extends State<AddSystemScreen> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _panelWatts = TextEditingController(text: '300');
  final _panelCount = TextEditingController(text: '4');
  final _batteryAh = TextEditingController(text: '200');
  final _inverterW = TextEditingController(text: '1500');
  final _controllerA = TextEditingController(text: '60');
  final _installYear =
      TextEditingController(text: DateTime.now().year.toString());

  int _voltage = 24;
  BatteryChemistry _chemistry = BatteryChemistry.lithium;
  ControllerType _controllerType = ControllerType.mppt;

  @override
  void dispose() {
    for (final c in [
      _name,
      _panelWatts,
      _panelCount,
      _batteryAh,
      _inverterW,
      _controllerA,
      _installYear,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Nearest datasheet preset by rated wattage — supplies the Voc/Vmpp/Isc/NOCT
  /// the fault engine needs when the user only told us a wattage.
  PanelSpec _nearestPanel(double watts) {
    PanelSpec best = defaultPanel;
    double bestDelta = double.infinity;
    for (final p in panelPresets.values) {
      final d = (p.watts - watts).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = p;
      }
    }
    return best;
  }

  SystemConfig _buildConfig() {
    final watts = double.parse(_panelWatts.text);
    final count = int.parse(_panelCount.text);
    final panel = _nearestPanel(watts);

    // Estimate the string arrangement from the bus voltage: enough panels in
    // series to sit just above charging voltage, the rest in parallel.
    final series =
        math.max(1, (_voltage * 1.2 / panel.vmpp).ceil());
    final parallel = math.max(1, (count / series).round());

    final year = int.tryParse(_installYear.text);
    final commissioned = (year != null && year >= 1990 && year <= DateTime.now().year)
        ? DateTime(year)
        : DateTime.now();

    return SystemConfig(
      panel: panel,
      panelCount: count,
      panelsInSeries: series,
      parallelStrings: parallel,
      systemVoltage: _voltage,
      chemistry: _chemistry,
      batteryBankAh: double.parse(_batteryAh.text),
      inverterW: int.parse(_inverterW.text),
      controllerA: int.parse(_controllerA.text),
      controllerType: _controllerType,
      commissionedOn: commissioned,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final db = Provider.of<DatabaseService>(context, listen: false);
    final config = _buildConfig();
    await db.saveSystem(
      name: _name.text.trim(),
      source: SystemSource.existing,
      config: config,
    );
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primaryDark,
      appBar: AppBar(
        title: const Text('Add Existing System'),
        backgroundColor: AppTheme.primaryMid,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Register a system already installed so the Scanner can diagnose '
              'it against thresholds matched to its own hardware.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _textField(_name, 'System name', hint: "e.g. Ade's Shop",
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null),
            const SizedBox(height: 16),

            _label('System voltage'),
            _segmented<int>(
              values: const [12, 24, 48],
              current: _voltage,
              labelOf: (v) => '${v}V',
              onChanged: (v) => setState(() => _voltage = v),
            ),
            const SizedBox(height: 16),

            _label('Battery chemistry'),
            _segmented<BatteryChemistry>(
              values: BatteryChemistry.values,
              current: _chemistry,
              labelOf: (c) => c.label,
              onChanged: (c) => setState(() => _chemistry = c),
            ),
            const SizedBox(height: 16),

            _numField(_batteryAh, 'Battery bank capacity (Ah)'),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(child: _numField(_panelWatts, 'Panel wattage (W)')),
                const SizedBox(width: 12),
                Expanded(child: _numField(_panelCount, 'Panel count', integer: true)),
              ],
            ),
            const SizedBox(height: 12),

            _numField(_inverterW, 'Inverter rating (W)', integer: true),
            const SizedBox(height: 12),

            _numField(_controllerA, 'Controller rating (A)', integer: true),
            const SizedBox(height: 16),

            _label('Controller type'),
            _segmented<ControllerType>(
              values: const [ControllerType.mppt, ControllerType.pwm],
              current: _controllerType,
              labelOf: (t) => t.label,
              onChanged: (t) => setState(() => _controllerType = t),
            ),
            const SizedBox(height: 12),

            _numField(_installYear, 'Year installed (for age baseline)',
                integer: true, optional: true),
            const SizedBox(height: 8),
            const Text(
              'Panel electrical specs are taken from the nearest datasheet '
              'preset by wattage; string arrangement is estimated from the bus '
              'voltage.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save & monitor this system'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13)),
      );

  Widget _textField(TextEditingController c, String label,
      {String? hint, String? Function(String?)? validator}) {
    return TextFormField(
      controller: c,
      validator: validator,
      style: const TextStyle(color: AppTheme.textPrimary),
      decoration: _decoration(label, hint),
    );
  }

  Widget _numField(TextEditingController c, String label,
      {bool integer = false, bool optional = false}) {
    return TextFormField(
      controller: c,
      keyboardType:
          TextInputType.numberWithOptions(decimal: !integer),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
            integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]')),
      ],
      style: const TextStyle(color: AppTheme.textPrimary),
      decoration: _decoration(label, null),
      validator: (v) {
        if (optional && (v == null || v.isEmpty)) return null;
        final n = num.tryParse(v ?? '');
        if (n == null || n <= 0) return 'Enter a value';
        return null;
      },
    );
  }

  InputDecoration _decoration(String label, String? hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: AppTheme.textSecondary),
        hintStyle: const TextStyle(color: AppTheme.textMuted),
        filled: true,
        fillColor: AppTheme.cardBackground,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.accentBlue),
        ),
      );

  Widget _segmented<T>({
    required List<T> values,
    required T current,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return Row(
      children: values.map((v) {
        final active = v == current;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onChanged(v),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? AppTheme.accentBlue.withOpacity(0.2)
                      : AppTheme.cardBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color:
                          active ? AppTheme.accentBlue : AppTheme.cardBorder),
                ),
                child: Text(labelOf(v),
                    style: TextStyle(
                        color: active
                            ? AppTheme.accentBlue
                            : AppTheme.textSecondary,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w400)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
