import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/database_provider.dart';
import 'package:app/providers/diagnosis_provider.dart';

class StatsCard extends ConsumerStatefulWidget {
  const StatsCard({super.key});

  @override
  ConsumerState<StatsCard> createState() => _StatsCardState();
}

class _StatsCardState extends ConsumerState<StatsCard> {
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await ref.read(predictionDaoProvider).getDetailedStatistics();
    if (mounted) {
      setState(() => _stats = stats);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Refresh stats whenever a new diagnosis completes
    ref.listen<DiagnosisState>(diagnosisProvider, (prev, next) {
      if (next.status == DiagnosisStatus.success) {
        _loadStats();
      }
    });

    if (_stats == null || (_stats!['total'] as int) == 0) {
      return const SizedBox.shrink();
    }

    final total = _stats!['total'] as int;
    final synced = _stats!['synced'] as int;
    final topDiseases =
        (_stats!['top_diseases'] as List<Map<String, dynamic>>?) ?? [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.analytics,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  S.get('your_stats'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _MiniStat(
                  label: S.get('scans_stat'),
                  value: total.toString(),
                  icon: Icons.scanner,
                ),
                _MiniStat(
                  label: S.get('synced_label'),
                  value: total > 0
                      ? '${(synced / total * 100).toStringAsFixed(0)}%'
                      : '0%',
                  icon: Icons.cloud_done,
                ),
                if (topDiseases.isNotEmpty)
                  _MiniStat(
                    label: S.get('top_stat'),
                    value: _shortenName(
                      _localizedTopDisease(topDiseases.first),
                    ),
                    icon: Icons.trending_up,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _localizedTopDisease(Map<String, dynamic> diseaseRow) {
    final rawName = diseaseRow['predicted_class_name'] as String;
    final leafType = diseaseRow['leaf_type'] as String?;
    if (leafType != null) {
      try {
        final m = ModelConstants.tryGetModel(leafType);
        if (m != null) {
          return m.localizedClassName(rawName, S.locale);
        }
        return LeafModelInfo.cleanLabel(rawName);
      } catch (e) {
        debugPrint('[StatsCard] Label localization failed: $e');
        return LeafModelInfo.cleanLabel(rawName);
      }
    }
    return LeafModelInfo.cleanLabel(rawName);
  }

  String _shortenName(String name) {
    if (name.length <= 10) return name;
    return '${name.substring(0, 9)}...';
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
