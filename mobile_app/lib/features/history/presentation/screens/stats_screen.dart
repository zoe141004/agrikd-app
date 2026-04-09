import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/database_provider.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  Map<String, dynamic>? _stats;
  bool _isLoading = true;
  static final _dateFormatDay = DateFormat('yyyy-MM-dd');
  static final _dateFormatWeekday = DateFormat('E');

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await ref.read(predictionDaoProvider).getDetailedStatistics();
    if (mounted) {
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.get('stats_title'))),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _stats == null || (_stats!['total'] as int) == 0
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bar_chart,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.get('no_data'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(S.get('start_scanning')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadStats,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      _buildSummaryCard(context),
                      const SizedBox(height: 12),
                      _buildDailyChart(context),
                      const SizedBox(height: 12),
                      _buildTopDiseases(context),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildSummaryCard(BuildContext context) {
    final total = _stats!['total'] as int;
    final synced = _stats!['synced'] as int;
    final syncPercent = total > 0
        ? (synced / total * 100).toStringAsFixed(0)
        : '0';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.get('overview'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _StatTile(
                  icon: Icons.scanner,
                  label: S.get('total_scans'),
                  value: total.toString(),
                  color: Theme.of(context).colorScheme.primary,
                ),
                _StatTile(
                  icon: Icons.cloud_done,
                  label: S.get('synced_label'),
                  value: '$syncPercent%',
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyChart(BuildContext context) {
    final dailyScans =
        (_stats!['daily_scans'] as List<Map<String, dynamic>>?) ?? [];

    // Build 7-day data, filling in zeros for missing days
    final now = DateTime.now();
    final days = <DateTime>[];
    final counts = <double>[];
    for (int i = 6; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day - i);
      days.add(day);
      final dateStr = _dateFormatDay.format(day);
      final match = dailyScans.where((r) => r['date'] == dateStr);
      counts.add(match.isEmpty ? 0 : (match.first['count'] as int).toDouble());
    }

    final maxY = counts.isEmpty
        ? 5.0
        : (counts.reduce((a, b) => a > b ? a : b) + 1).ceilToDouble();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.get('last_7_days'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  barTouchData: BarTouchData(enabled: false),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx < 0 || idx >= days.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              _dateFormatWeekday.format(days[idx]),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) {
                          if (value == value.roundToDouble()) {
                            return Text(
                              value.toInt().toString(),
                              style: Theme.of(context).textTheme.labelSmall,
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(show: false),
                  barGroups: List.generate(7, (i) {
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: counts[i],
                          color: Theme.of(context).colorScheme.primary,
                          width: 16,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopDiseases(BuildContext context) {
    final topDiseases =
        (_stats!['top_diseases'] as List<Map<String, dynamic>>?) ?? [];

    if (topDiseases.isEmpty) return const SizedBox.shrink();

    final colors = [
      Theme.of(context).colorScheme.primary,
      Theme.of(context).colorScheme.secondary,
      Theme.of(context).colorScheme.tertiary,
      Theme.of(context).colorScheme.error,
      Theme.of(context).colorScheme.outline,
    ];

    final total = topDiseases.fold<int>(
      0,
      (sum, d) => sum + (d['count'] as int),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.get('common_findings'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 160,
              child: Row(
                children: [
                  Expanded(
                    child: PieChart(
                      PieChartData(
                        sections: List.generate(topDiseases.length, (i) {
                          final count = topDiseases[i]['count'] as int;
                          final percent = total > 0 ? count / total * 100 : 0;
                          return PieChartSectionData(
                            color: colors[i % colors.length],
                            value: count.toDouble(),
                            title: '${percent.toStringAsFixed(0)}%',
                            radius: 50,
                            titleStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          );
                        }),
                        sectionsSpace: 2,
                        centerSpaceRadius: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: List.generate(topDiseases.length, (i) {
                        final rawName =
                            topDiseases[i]['predicted_class_name'] as String;
                        final leafType = topDiseases[i]['leaf_type'] as String?;
                        String displayName = rawName;
                        if (leafType != null) {
                          try {
                            final m = ModelConstants.getModel(leafType);
                            displayName = m.localizedClassName(
                              rawName,
                              S.locale,
                            );
                          } catch (e) {
                            debugPrint(
                              '[StatsScreen] Label localization failed: $e',
                            );
                            displayName = LeafModelInfo.cleanLabel(rawName);
                          }
                        }
                        final count = topDiseases[i]['count'] as int;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: colors[i % colors.length],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  displayName,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '$count',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
