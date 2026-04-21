import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/core/utils/format_helpers.dart';
import 'package:app/providers/benchmark_provider.dart';
import 'package:app/providers/sync_provider.dart';

class EvaluationScreen extends ConsumerWidget {
  const EvaluationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final benchState = ref.watch(benchmarkProvider);
    final syncState = ref.watch(syncProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(S.get('evaluation'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Model updates section
          if (syncState.pendingModelUpdates.isNotEmpty) ...[
            _SectionLabel(S.get('model_updates')),
            const SizedBox(height: 8),
            ...syncState.pendingModelUpdates.map((update) {
              final modelInfo = ModelConstants.getModel(update.leafType);
              final isDownloading =
                  syncState.downloadingLeafType == update.leafType;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: Icon(
                    Icons.system_update_alt,
                    color: colorScheme.primary,
                  ),
                  title: Text(modelInfo.localizedName(S.locale)),
                  subtitle: Text('v${update.version}'),
                  trailing: isDownloading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: () {
                            ref
                                .read(syncProvider.notifier)
                                .downloadUpdate(update.leafType);
                          },
                          child: Text(S.get('download')),
                        ),
                ),
              );
            }),
            const SizedBox(height: 8),
          ],

          // Benchmark metrics section
          _SectionLabel(S.get('evaluation_sub')),
          const SizedBox(height: 8),

          if (benchState.isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (benchState.benchmarks.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off, size: 48, color: colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(
                      S.get('no_data'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ...ModelConstants.availableLeafTypes.map((leafType) {
              final bench = benchState.benchmarks[leafType];
              final modelInfo = ModelConstants.getModel(leafType);
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              modelInfo.localizedName(S.locale),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (bench != null)
                            Text(
                              'v${bench.version}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                        ],
                      ),
                      if (bench == null) ...[
                        const SizedBox(height: 8),
                        Text(
                          S.get('model_specs_unavailable'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ] else ...[
                        const SizedBox(height: 12),
                        _MetricRow(
                          S.get('spec_accuracy'),
                          formatPercent(bench.accuracy),
                          colorScheme,
                          highlight: true,
                        ),
                        _MetricRow(
                          S.get('spec_precision'),
                          formatPercent(bench.precisionMacro),
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_recall'),
                          formatPercent(bench.recallMacro),
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_f1'),
                          formatPercent(bench.f1Macro),
                          colorScheme,
                        ),
                        const Divider(height: 20),
                        _MetricRow(
                          S.get('spec_latency'),
                          bench.latencyMeanMs != null
                              ? '${bench.latencyMeanMs!.toStringAsFixed(1)} ms'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_size'),
                          bench.sizeMb != null
                              ? '${bench.sizeMb!.toStringAsFixed(2)} MB'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_params'),
                          bench.paramsM != null
                              ? '${bench.paramsM!.toStringAsFixed(2)} M'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_flops'),
                          bench.flopsM != null
                              ? '${bench.flopsM!.toStringAsFixed(1)} M'
                              : '—',
                          colorScheme,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),

          if (syncState.pendingModelUpdates.isEmpty &&
              benchState.benchmarks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                S.get('model_update_none'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme colorScheme;
  final bool highlight;

  const _MetricRow(
    this.label,
    this.value,
    this.colorScheme, {
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              color: highlight ? colorScheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }
}
