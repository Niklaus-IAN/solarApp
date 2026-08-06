import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/appliance.dart';
import '../models/enums.dart';
import '../models/panel_spec.dart';
import '../models/sizing_input.dart';
import '../models/sizing_result.dart';
import '../models/system_config.dart';
import '../models/saved_system.dart';
import '../data/appliance_presets.dart';
import '../data/psh_table.dart';
import '../services/sizing_service.dart';
import '../services/database_service.dart';

class SizingScreen extends StatefulWidget {
  const SizingScreen({super.key});

  @override
  State<SizingScreen> createState() => _SizingScreenState();
}

class _SizingScreenState extends State<SizingScreen> {
  final SizingService _sizingService = const SizingService();

  String _selectedLocation = 'Lagos';
  // null => let the engine recommend from daily energy (and warn if overridden).
  int? _systemVoltage;
  BatteryChemistry _chemistry = BatteryChemistry.lithium;
  int _autonomyDays = 2;
  String _panelKey = '300W Mono (60-cell)';
  int _batteryUnit = 200;
  PshMode _pshMode = PshMode.worstMonth;
  String _applianceCategory = 'Lighting';

  final List<Appliance> _appliances = [];
  int _idCounter = 0;
  SizingResult? _result;
  bool _showResults = false;

  PanelSpec get _panel => panelPresets[_panelKey]!;

  void _addPreset(AppliancePreset preset) {
    setState(() {
      _appliances.add(preset.toAppliance('a${_idCounter++}'));
    });
  }

  void _removeAppliance(int index) {
    setState(() => _appliances.removeAt(index));
  }

  void _updateAppliance(int index, Appliance updated) {
    setState(() => _appliances[index] = updated);
  }

  void _calculateSizing() {
    if (_appliances.isEmpty) return;

    final result = _sizingService.calculate(SizingInput(
      appliances: List<Appliance>.from(_appliances),
      city: _selectedLocation,
      pshMode: _pshMode,
      systemVoltage: _systemVoltage,
      chemistry: _chemistry,
      autonomyDays: _autonomyDays.toDouble(),
      panel: _panel,
      batteryUnitAh: _batteryUnit.toDouble(),
    ));

    setState(() {
      _result = result;
      _showResults = true;
    });
  }

  double _calculateDailyEnergy() {
    double total = 0;
    for (final a in _appliances) {
      total += a.dailyWh;
    }
    return total / 1000.0;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          if (!_showResults) ...[
            _buildSectionHeader('Select Your Appliances'),
            const SizedBox(height: 8),
            _buildApplianceSelector(),
            const SizedBox(height: 16),
            if (_appliances.isNotEmpty) ...[
              _buildSectionHeader('Your Load Profile'),
              const SizedBox(height: 8),
              ..._appliances.asMap().entries.map(
                    (entry) => _buildSelectedAppliance(entry.key, entry.value),
                  ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Daily consumption:',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '${_calculateDailyEnergy().toStringAsFixed(2)} kWh',
                      style: GoogleFonts.orbitron(
                          color: AppTheme.accentBlue,
                          fontWeight: FontWeight.w700,
                          fontSize: 16),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            _buildSectionHeader('System Configuration'),
            const SizedBox(height: 8),
            _buildConfigCard(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _appliances.isNotEmpty ? _calculateSizing : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Calculate System Size',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ] else ...[
            _buildResults(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => setState(() => _showResults = false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentBlue,
                  side: const BorderSide(color: AppTheme.accentBlue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Recalculate',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String text) {
    return Text(text, style: Theme.of(context).textTheme.headlineSmall);
  }

  // ===== APPLIANCE SELECTION =====

  Widget _buildApplianceSelector() {
    final categories = applianceCategories;
    if (!categories.contains(_applianceCategory) && categories.isNotEmpty) {
      _applianceCategory = categories.first;
    }
    final presets = presetsInCategory(_applianceCategory);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: categories.map((c) {
              final active = c == _applianceCategory;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(c),
                  selected: active,
                  onSelected: (_) => setState(() => _applianceCategory = c),
                  backgroundColor: AppTheme.cardBackground,
                  selectedColor: AppTheme.accentBlue.withOpacity(0.25),
                  labelStyle: TextStyle(
                      color: active ? AppTheme.accentBlue : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400),
                  side: BorderSide(
                      color: active ? AppTheme.accentBlue : AppTheme.cardBorder),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: presets.map((preset) {
            return ActionChip(
              label: Text('${preset.name} (${preset.typicalWatts.toStringAsFixed(0)}W)'),
              onPressed: () => _addPreset(preset),
              backgroundColor: AppTheme.cardBackground,
              labelStyle: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              side: const BorderSide(color: AppTheme.cardBorder),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSelectedAppliance(int index, Appliance a) {
    final isDc = a.loadType == LoadType.dc;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Text(a.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                        overflow: TextOverflow.ellipsis),
                    _tag(isDc ? 'DC' : 'AC',
                        isDc ? AppTheme.accentGreen : AppTheme.accentBlue),
                    if (a.dutyCycle < 1.0)
                      _tag('${(a.dutyCycle * 100).toStringAsFixed(0)}% duty',
                          AppTheme.accentYellow),
                    if (a.isMotorLoad)
                      _tag('${a.surgeFactor.toStringAsFixed(0)}× surge',
                          AppTheme.accentOrange),
                  ],
                ),
                Text(
                  '${a.watts.toStringAsFixed(0)}W × ${a.quantity} × '
                  '${a.hoursPerDay.toStringAsFixed(1)}h → '
                  '${(a.dailyWh / 1000).toStringAsFixed(2)} kWh',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            onPressed: () {
              if (a.quantity > 1) {
                _updateAppliance(index, a.copyWith(quantity: a.quantity - 1));
              }
            },
          ),
          Text('${a.quantity}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 20),
            onPressed: () =>
                _updateAppliance(index, a.copyWith(quantity: a.quantity + 1)),
          ),
          SizedBox(
            width: 60,
            child: Column(
              children: [
                Text('${a.hoursPerDay.toStringAsFixed(0)}h',
                    style: const TextStyle(fontSize: 11)),
                Slider(
                  value: a.hoursPerDay.clamp(0.5, 24),
                  min: 0.5,
                  max: 24,
                  onChanged: (v) =>
                      _updateAppliance(index, a.copyWith(hoursPerDay: v)),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppTheme.accentRed),
            onPressed: () => _removeAppliance(index),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }

  // ===== CONFIG =====

  Widget _buildConfigCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          _buildDropdown('Location', _selectedLocation, availableCities,
              (v) => setState(() => _selectedLocation = v!)),
          _buildDropdown(
              'System Voltage',
              _systemVoltage == null ? 'Auto' : '${_systemVoltage}V',
              ['Auto', '12V', '24V', '48V'],
              (v) => setState(() => _systemVoltage =
                  v == 'Auto' ? null : int.parse(v!.replaceAll('V', '')))),
          _buildDropdown(
              'Battery Type',
              _chemistry == BatteryChemistry.lithium ? 'Lithium' : 'Lead-acid',
              ['Lithium', 'Lead-acid'],
              (v) => setState(() => _chemistry = v == 'Lithium'
                  ? BatteryChemistry.lithium
                  : BatteryChemistry.leadAcid)),
          _buildDropdown(
              'Autonomy Days',
              '$_autonomyDays day(s)',
              ['1 day(s)', '2 day(s)', '3 day(s)', '4 day(s)'],
              (v) => setState(
                  () => _autonomyDays = int.parse(v!.split(' ')[0]))),
          _buildDropdown('Panel', _panelKey, panelPresets.keys.toList(),
              (v) => setState(() => _panelKey = v!)),
          _buildDropdown(
              'Battery Unit',
              '${_batteryUnit}Ah',
              ['100Ah', '150Ah', '200Ah', '220Ah', '250Ah'],
              (v) => setState(
                  () => _batteryUnit = int.parse(v!.replaceAll('Ah', '')))),
          _buildDropdown(
              'Sizing Basis',
              _pshMode == PshMode.worstMonth ? 'Worst month' : 'Annual average',
              ['Worst month', 'Annual average'],
              (v) => setState(() => _pshMode = v == 'Worst month'
                  ? PshMode.worstMonth
                  : PshMode.annualAverage)),
        ],
      ),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> items,
      ValueChanged<String?> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 14)),
          DropdownButton<String>(
            value: value,
            items: items
                .map((e) => DropdownMenuItem(
                    value: e,
                    child: Text(e, style: const TextStyle(fontSize: 14))))
                .toList(),
            onChanged: onChanged,
            dropdownColor: AppTheme.primaryLight,
            underline: const SizedBox(),
            style: const TextStyle(
                color: AppTheme.accentBlue, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ===== RESULTS =====

  Widget _buildResults() {
    if (_result == null) return const SizedBox();
    final r = _result!;
    final pvRun = r.cableRuns.isNotEmpty ? r.cableRuns.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('System Specification'),
        const SizedBox(height: 12),
        _buildResultCard(
            Icons.solar_power,
            'Solar Panels',
            '${r.panelCount} × ${r.panel.watts.toStringAsFixed(0)}W panels',
            '${r.parallelStrings} string(s) of ${r.panelsInSeries} in series · '
                '${r.installedWp.toStringAsFixed(0)} Wp',
            AppTheme.accentYellow,
            hint: 'This is a wiring plan. Build ${r.parallelStrings} line(s) of '
                'panels, each line ${r.panelsInSeries} panel(s) joined '
                'end-to-end — that is SERIES, and it raises voltage. Then '
                'connect the line(s) side-by-side — that is PARALLEL, and it '
                'adds current. Full terms are in the Installation Guide '
                'glossary.'),
        _buildResultCard(
            Icons.battery_charging_full,
            'Battery Bank',
            '${r.batteryCount} × $_batteryUnit Ah batteries',
            '${r.batteryParallelStrings} group(s) of ${r.batteriesInSeries} in '
                'series (${r.systemVoltage}V ${r.chemistry.label})',
            AppTheme.accentBlue,
            hint: 'Wire ${r.batteriesInSeries} batteries end-to-end (SERIES) to '
                'reach ${r.systemVoltage}V, and put ${r.batteryParallelStrings} '
                'such group(s) side-by-side (PARALLEL) to add capacity. Every '
                'battery in the bank must be the same brand, size and age.'),
        _buildResultCard(
            Icons.power,
            'Inverter',
            '${r.inverterW} W',
            'Continuous ${r.runningLoadW.toStringAsFixed(0)}W load; check '
                'datasheet surge ≥ ${r.inverterRequiredSurgeW.toStringAsFixed(0)}W',
            AppTheme.accentOrange),
        _buildResultCard(
            Icons.tune,
            'Charge Controller',
            '${r.controllerA} A ${r.controllerType.label}'
                '${r.controllerCount > 1 ? " × ${r.controllerCount}" : ""}',
            'PV input rating ≥ ${r.controllerMinVocRating} Vdc '
                '(string Voc ${r.stringVocCold.toStringAsFixed(0)}V cold)',
            AppTheme.accentGreen,
            hint: '${r.controllerType.label} is the controller type. The '
                '"PV input ≥ ${r.controllerMinVocRating} Vdc" is the highest '
                'panel voltage it must survive: your string reaches '
                '${r.stringVocCold.toStringAsFixed(0)}V on a cold morning (that '
                'is Voc cold). Never connect panels whose cold voltage exceeds '
                'the controller\'s rating — it destroys the unit.'),
        _buildResultCard(
            Icons.cable,
            'Cable (PV run)',
            pvRun != null ? '${pvRun.selectedMm2.toStringAsFixed(1)} mm²' : '—',
            pvRun != null
                ? '${pvRun.amps.toStringAsFixed(0)} A, drop '
                    '${(pvRun.actualDrop * 100).toStringAsFixed(2)}% over '
                    '${pvRun.lengthM.toStringAsFixed(0)}m'
                : '',
            AppTheme.textSecondary),

        const SizedBox(height: 20),
        _buildSaveButton(r),

        const SizedBox(height: 20),
        _buildEnergySection(r),
        const SizedBox(height: 16),
        _buildWorstMonthSection(r),
        const SizedBox(height: 16),
        if (r.warnings.isNotEmpty) ...[
          _buildWarningsSection(r),
          const SizedBox(height: 16),
        ],
        _buildScheduleSection(r),
      ],
    );
  }

  Widget _buildResultCard(IconData icon, String title, String value,
      String detail, Color color, {String? hint}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
                Text(value,
                    style: GoogleFonts.orbitron(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                if (detail.isNotEmpty)
                  Text(detail,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
              ],
            ),
          ),
          if (hint != null)
            GestureDetector(
              onTap: () => _showHint(title, hint),
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.help_outline,
                    color: AppTheme.textMuted, size: 18),
              ),
            ),
        ],
      ),
    );
  }

  /// Plain-English popup for a result card. Mirrors the Installation Guide
  /// glossary so the jargon on this screen is explained in place.
  void _showHint(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.primaryMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.menu_book, color: AppTheme.accentBlue, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: Text(body,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ===== EXTRA SECTIONS =====

  Widget _panelBox({required String title, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _kv(String k, String v, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Text(k,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Text(v,
              style: TextStyle(
                  color: valueColor ?? AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildEnergySection(SizingResult r) {
    return _panelBox(
      title: 'Energy & Losses',
      children: [
        _kv('AC load', '${r.acLoadWh.toStringAsFixed(0)} Wh/day'),
        _kv('DC load', '${r.dcLoadWh.toStringAsFixed(0)} Wh/day'),
        _kv('Out of battery (bus)', '${r.busEnergyWh.toStringAsFixed(0)} Wh/day'),
        const Divider(color: AppTheme.cardBorder, height: 20),
        _kv('Design basis',
            '${r.designMonth} · ${r.designPsh.toStringAsFixed(2)} PSH'),
        _kv('Annual-average PSH', r.annualAveragePsh.toStringAsFixed(2)),
        _kv('Panel Generation Factor',
            r.panelGenerationFactor.toStringAsFixed(2)),
        _kv('Whole-chain factor',
            '${r.totalSystemFactor.toStringAsFixed(3)}  (CED 0.60)',
            valueColor: AppTheme.accentGreen),
      ],
    );
  }

  Widget _buildWorstMonthSection(SizingResult r) {
    final premium = r.worstMonthPremiumPercent;
    return _panelBox(
      title: 'Worst-month vs Annual-average Array',
      children: [
        _kv('Sized array (${r.designMonth})',
            '${r.requiredArrayWp.toStringAsFixed(0)} Wp'),
        _kv('If sized on annual average',
            '${r.requiredArrayWpAnnualAverage.toStringAsFixed(0)} Wp'),
        _kv(
            'Reliability premium',
            '${premium >= 0 ? '+' : ''}${premium.toStringAsFixed(0)}% array',
            valueColor: AppTheme.accentOrange),
        const SizedBox(height: 6),
        Text(
          r.designMonth == 'annual average'
              ? 'Sized on the annual average — optimistic; may brown out in the '
                  'rainy season.'
              : 'Worst-month sizing costs more array but keeps the system '
                  'reliable year-round.',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildWarningsSection(SizingResult r) {
    return _panelBox(
      title: 'Design Advisories (${r.warnings.length})',
      children: r.warnings.map((w) {
        final color = _warningColor(w.level);
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_warningIcon(w.level), size: 15, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(w.title,
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w700,
                            fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(w.detail,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11, height: 1.3)),
              if (w.action != null) ...[
                const SizedBox(height: 4),
                Text('→ ${w.action}',
                    style: TextStyle(
                        color: color.withOpacity(0.85),
                        fontSize: 11,
                        fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildScheduleSection(SizingResult r) {
    return _panelBox(
      title: 'Cable & Protection Schedule',
      children: [
        const Text('Cable runs',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ...r.cableRuns.map((c) => _kv(
            c.label,
            '${c.selectedMm2.toStringAsFixed(1)} mm² · '
                '${(c.actualDrop * 100).toStringAsFixed(2)}%')),
        const Divider(color: AppTheme.cardBorder, height: 20),
        const Text('Protection',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (r.protection.pvStringFuseA != null)
          _kv('PV string fuse', '${r.protection.pvStringFuseA} A'),
        _kv('Array breaker',
            '${r.protection.arrayBreakerA} A @ ${r.protection.arrayBreakerVdc} Vdc'),
        _kv('Controller→battery breaker',
            '${r.protection.controllerBreakerA} A'),
        _kv('Battery→inverter breaker', '${r.protection.batteryBreakerA} A'),
        _kv('AC breaker + RCD',
            '${r.protection.acBreakerA} A + ${r.protection.rcdMilliamps} mA'),
        _kv('DC SPD',
            '${r.protection.dcSpdVdc} Vdc · ${r.protection.dcSpdKa} kA'),
        _kv('AC SPD',
            '${r.protection.acSpdVac} V · ${r.protection.acSpdKa} kA'),
        _kv('Earthing',
            '${r.protection.earthCableMm2.toStringAsFixed(0)} mm² · '
                '${r.protection.earthRodCount} rods'),
      ],
    );
  }

  // ===== SAVE AS SYSTEM =====

  Widget _buildSaveButton(SizingResult r) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _promptSaveSystem(r),
        icon: const Icon(Icons.save_outlined, size: 20),
        label: const Text('Save as system'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accentGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  Future<void> _promptSaveSystem(SizingResult r) async {
    final controller = TextEditingController(
        text: '$_selectedLocation ${r.systemVoltage}V');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.primaryMid,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Save as system', style: TextStyle(fontSize: 18)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(
            hintText: 'e.g. Home, Ade\'s Shop',
            hintStyle: TextStyle(color: AppTheme.textMuted),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentGreen),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    final config = SystemConfig.fromSizingResult(r);
    await db.saveSystem(
        name: name, source: SystemSource.sized, config: config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$name" — now monitored on the Scanner tab.'),
        backgroundColor: AppTheme.accentGreen,
      ),
    );
  }

  // ===== HELPERS =====

  Color _warningColor(WarningLevel level) {
    switch (level) {
      case WarningLevel.critical:
        return AppTheme.accentRed;
      case WarningLevel.caution:
        return AppTheme.accentOrange;
      case WarningLevel.info:
        return AppTheme.accentBlue;
    }
  }

  IconData _warningIcon(WarningLevel level) {
    switch (level) {
      case WarningLevel.critical:
        return Icons.error_outline;
      case WarningLevel.caution:
        return Icons.warning_amber_rounded;
      case WarningLevel.info:
        return Icons.info_outline;
    }
  }
}
