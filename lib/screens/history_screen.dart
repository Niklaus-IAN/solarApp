import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/database_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _selectedPeriod = 'Today';
  List<Map<String, dynamic>> _readings = [];
  List<Map<String, dynamic>> _faults = [];
  Map<String, dynamic> _stats = {
    'avgScore': 0,
    'avgPower': 0.0,
    'readingCount': 0,
    'totalFaults': 0,
  };
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      // Re-load when database changes (new readings added)
      final dbService = Provider.of<DatabaseService>(context, listen: false);
      dbService.addListener(_loadData);
    });
  }

  @override
  void dispose() {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    dbService.removeListener(_loadData);
    super.dispose();
  }

  Future<void> _loadData() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    final readings = await dbService.getReadings(period: _selectedPeriod);
    final faults = await dbService.getFaults(period: _selectedPeriod);
    final stats = await dbService.getSummaryStats(period: _selectedPeriod);

    if (mounted) {
      setState(() {
        _readings = readings;
        _faults = faults;
        _stats = stats;
        _isLoading = false;
      });
    }
  }

  void _onPeriodChanged(String period) {
    setState(() {
      _selectedPeriod = period;
      _isLoading = true;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),

          // Period selector
          Row(
            children: ['Today', '7 Days', '30 Days'].map((period) {
              bool isSelected = _selectedPeriod == period;
              return Expanded(
                child: GestureDetector(
                  onTap: () => _onPeriodChanged(period),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected ? AppTheme.accentBlue.withOpacity(0.15) : AppTheme.cardBackground,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? AppTheme.accentBlue.withOpacity(0.4) : AppTheme.cardBorder,
                      ),
                    ),
                    child: Text(
                      period,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isSelected ? AppTheme.accentBlue : AppTheme.textSecondary,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          if (_isLoading)
            const Center(child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(),
            ))
          else ...[

            // Summary cards
            Row(
              children: [
                Expanded(child: _buildSummaryCard(
                  'Avg Score',
                  _stats['readingCount'] > 0 ? '${_stats['avgScore']}%' : '--',
                  AppTheme.accentGreen,
                )),
                const SizedBox(width: 10),
                Expanded(child: _buildSummaryCard(
                  'Total Faults',
                  '${_stats['totalFaults']}',
                  AppTheme.accentOrange,
                )),
                const SizedBox(width: 10),
                Expanded(child: _buildSummaryCard(
                  'Avg Power',
                  _stats['readingCount'] > 0
                    ? '${(_stats['avgPower'] as double).toStringAsFixed(1)}W'
                    : '--',
                  AppTheme.accentBlue,
                )),
              ],
            ),

            const SizedBox(height: 20),

            // Health score chart
            Text('Health Score Timeline', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),

            if (_readings.isEmpty)
              _buildEmptyState('No readings yet. Connect to a device or start simulation to begin recording data.')
            else ...[
              // FL Chart bar chart
              Container(
                height: 200,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.cardBackground,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: _buildBarChart(),
              ),

              const SizedBox(height: 12),

              // Reading entries
              ..._readings.take(15).map((entry) => _buildTimelineEntry(entry)),
            ],

            const SizedBox(height: 20),

            // Fault event log
            Text('Fault Event Log', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),

            if (_faults.isEmpty)
              _buildEmptyState('No fault events recorded yet.')
            else
              ..._faults.map((fault) => _buildFaultLogEntry(fault)),

            const SizedBox(height: 16),

            // Info note
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.cardBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: AppTheme.textMuted, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'All data is stored locally on this device using SQLite.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildBarChart() {
    final chartData = _readings.take(10).toList().reversed.toList();
    return CustomPaint(
      painter: _HealthBarChartPainter(chartData),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          const Icon(Icons.inbox_outlined, color: AppTheme.textMuted, size: 36),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: GoogleFonts.orbitron(color: color, fontWeight: FontWeight.w700, fontSize: 20)),
        ],
      ),
    );
  }

  Widget _buildTimelineEntry(Map<String, dynamic> entry) {
    int score = (entry['health_score'] as num).toInt();
    Color color = AppTheme.healthScoreColor(score);
    double barWidth = score / 100.0;
    int faultCount = (entry['fault_count'] as num?)?.toInt() ?? 0;

    // Parse timestamp for display
    String timeLabel = '--:--';
    try {
      DateTime dt = DateTime.parse(entry['timestamp'] as String);
      timeLabel = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 45,
            child: Text(timeLabel, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: barWidth,
                backgroundColor: AppTheme.primaryDark,
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 14,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              '$score%',
              textAlign: TextAlign.right,
              style: GoogleFonts.orbitron(color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          if (faultCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accentOrange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$faultCount',
                style: const TextStyle(color: AppTheme.accentOrange, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFaultLogEntry(Map<String, dynamic> fault) {
    String severity = fault['severity'] as String? ?? 'MEDIUM';
    Color color = AppTheme.severityColor(severity);

    // Parse timestamps
    String timeLabel = '--:--';
    String clearedLabel = 'active';
    try {
      DateTime dt = DateTime.parse(fault['timestamp'] as String);
      timeLabel = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    if (fault['cleared_at'] != null) {
      try {
        DateTime ct = DateTime.parse(fault['cleared_at'] as String);
        clearedLabel = 'cleared ${ct.hour.toString().padLeft(2, '0')}:${ct.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              fault['code'] as String? ?? '???',
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fault['condition_text'] as String? ?? '',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(
                  '$timeLabel → $clearedLabel',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthBarChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> data;

  _HealthBarChartPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final gridPaint = Paint()
      ..color = AppTheme.cardBorder
      ..strokeWidth = 0.5;

    // Draw horizontal grid lines at 25, 50, 75, 100
    for (int i = 1; i <= 4; i++) {
      double y = size.height * (1 - i * 25 / 100) - 20;
      canvas.drawLine(Offset(30, y), Offset(size.width, y), gridPaint);

      // Y-axis labels
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${i * 25}',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(0, y - 5));
    }

    final int count = data.length;
    final double chartWidth = size.width - 30;
    final double barAreaWidth = chartWidth / count;
    final double barWidth = barAreaWidth * 0.55;
    final double chartHeight = size.height - 30;

    for (int i = 0; i < count; i++) {
      final entry = data[i];
      int score = (entry['health_score'] as num).toInt().clamp(0, 100);
      Color color = AppTheme.healthScoreColor(score);

      double barHeight = (score / 100) * chartHeight;
      double left = 30 + i * barAreaWidth + (barAreaWidth - barWidth) / 2;
      double top = chartHeight - barHeight;

      // Bar
      final barPaint = Paint()..color = color;
      final rrect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(rrect, barPaint);

      // X-axis time label
      String timeLabel = '';
      try {
        DateTime dt = DateTime.parse(entry['timestamp'] as String);
        timeLabel =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}

      final tp = TextPainter(
        text: TextSpan(
          text: timeLabel,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 8),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left + barWidth / 2 - tp.width / 2, chartHeight + 4));
    }
  }

  @override
  bool shouldRepaint(_HealthBarChartPainter old) => old.data != data;
}
