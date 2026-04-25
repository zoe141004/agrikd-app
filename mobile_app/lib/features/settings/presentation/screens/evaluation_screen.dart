import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/core/utils/format_helpers.dart';
import 'package:app/providers/available_models_provider.dart';
import 'package:app/providers/evaluation_provider.dart';
import 'package:app/providers/sync_provider.dart';

class EvaluationScreen extends ConsumerWidget {
  const EvaluationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final evalState = ref.watch(evaluationProvider);
    final syncState = ref.watch(syncProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final availableModels = ref.watch(availableModelsProvider);
    final leafTypes = ref.watch(allLeafTypesProvider);

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
              final dl = syncState.downloadingModel;
              final isDownloading =
                  dl?.leafType == update.leafType &&
                  dl?.version == update.version;
              final displayName =
                  availableModels[update.leafType]?.localizedName(S.locale) ??
                  update.displayName ??
                  update.leafType;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: Icon(
                    Icons.system_update_alt,
                    color: colorScheme.primary,
                  ),
                  title: Text(displayName),
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
                                .downloadUpdate(
                                  update.leafType,
                                  update.version,
                                );
                          },
                          child: Text(S.get('download')),
                        ),
                ),
              );
            }),
            const SizedBox(height: 8),
          ],

          // Evaluation metrics section
          _SectionLabel(S.get('evaluation_sub')),
          const SizedBox(height: 8),

          if (evalState.isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (evalState.evaluations.isEmpty)
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
            ...leafTypes.map((leafType) {
              final eval = evalState.evaluations[leafType];
              final modelInfo = availableModels[leafType];
              if (modelInfo == null && eval == null) {
                return const SizedBox.shrink();
              }
              final displayName =
                  modelInfo?.localizedName(S.locale) ?? leafType;
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
                              displayName,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (eval != null)
                            _VersionDropdown(
                              leafType: leafType,
                              currentVersion: eval.version,
                              versions:
                                  evalState.availableVersions[leafType] ??
                                  [eval.version],
                              ref: ref,
                              colorScheme: colorScheme,
                            ),
                        ],
                      ),
                      if (eval == null) ...[
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
                          formatPercent(eval.accuracy),
                          colorScheme,
                          highlight: true,
                        ),
                        _MetricRow(
                          S.get('spec_precision'),
                          formatPercent(eval.precisionMacro),
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_recall'),
                          formatPercent(eval.recallMacro),
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_f1'),
                          formatPercent(eval.f1Macro),
                          colorScheme,
                        ),
                        const Divider(height: 20),
                        _MetricRow(
                          S.get('spec_latency'),
                          eval.latencyMeanMs != null
                              ? '${eval.latencyMeanMs!.toStringAsFixed(1)} ms'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_size'),
                          eval.sizeMb != null
                              ? '${eval.sizeMb!.toStringAsFixed(2)} MB'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_params'),
                          eval.paramsM != null
                              ? '${eval.paramsM!.toStringAsFixed(2)} M'
                              : '—',
                          colorScheme,
                        ),
                        _MetricRow(
                          S.get('spec_flops'),
                          eval.flopsM != null
                              ? '${eval.flopsM!.toStringAsFixed(1)} M'
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
              evalState.evaluations.isNotEmpty) ...[
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

class _VersionDropdown extends StatelessWidget {
  final String leafType;
  final String currentVersion;
  final List<String> versions;
  final WidgetRef ref;
  final ColorScheme colorScheme;

  const _VersionDropdown({
    required this.leafType,
    required this.currentVersion,
    required this.versions,
    required this.ref,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    if (versions.length <= 1) {
      return Text(
        'v$currentVersion',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      );
    }
    return DropdownButton<String>(
      value: versions.contains(currentVersion)
          ? currentVersion
          : versions.first,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      items: versions
          .map((v) => DropdownMenuItem(value: v, child: Text('v$v')))
          .toList(),
      onChanged: (v) {
        if (v != null && v != currentVersion) {
          ref.read(evaluationProvider.notifier).loadVersion(leafType, v);
        }
      },
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
