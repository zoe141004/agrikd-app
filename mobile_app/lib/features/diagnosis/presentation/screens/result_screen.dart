import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/core/utils/image_widget.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/features/diagnosis/domain/models/prediction.dart';
import 'package:app/providers/database_provider.dart';
import 'package:app/providers/diagnosis_provider.dart';
import 'package:app/providers/model_version_provider.dart';
import 'camera_screen.dart';

class ResultScreen extends ConsumerStatefulWidget {
  final String leafType;

  const ResultScreen({super.key, required this.leafType});

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  final _notesController = TextEditingController();
  bool _notesSaved = false;
  static final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _saveNotes(int predictionId) async {
    final notes = _notesController.text.trim();
    if (notes.isEmpty) return;

    await ref.read(predictionDaoProvider).updateNotes(predictionId, notes);
    setState(() => _notesSaved = true);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.get('notes_saved'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final diagnosisState = ref.watch(diagnosisProvider);
    final prediction = diagnosisState.prediction;

    if (prediction == null) {
      return Scaffold(
        appBar: AppBar(title: Text(S.get('result'))),
        body: Center(child: Text(S.get('no_result'))),
      );
    }

    final modelInfo = ModelConstants.getModel(widget.leafType);
    final displayName = modelInfo.localizedClassName(
      prediction.predictedClassName,
      S.locale,
    );

    return Scaffold(
      appBar: AppBar(title: Text(S.get('your_result'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Image preview
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: kIsWeb
                      ? Image.network(
                          prediction.imagePath,
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stack) => Container(
                            height: 200,
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: const Icon(
                              Icons.image_not_supported,
                              size: 64,
                            ),
                          ),
                        )
                      : buildFileImage(
                          prediction.imagePath,
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stack) => Container(
                            height: 200,
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: const Icon(
                              Icons.image_not_supported,
                              size: 64,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 12),

                // Result card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Chip(
                              avatar: const Icon(Icons.check_circle, size: 18),
                              label: Text(
                                '${(prediction.confidence * 100).toStringAsFixed(1)}%',
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (prediction.inferenceTimeMs != null)
                              Chip(
                                avatar: const Icon(Icons.speed, size: 18),
                                label: Text(
                                  '${prediction.inferenceTimeMs!.toStringAsFixed(1)} ms',
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _dateFormat.format(prediction.createdAt),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Chip(
                              avatar: const Icon(Icons.memory, size: 16),
                              label: Text(
                                'v${prediction.modelVersion}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () =>
                                  _showReportDialog(context, prediction),
                              icon: const Icon(Icons.flag_outlined, size: 18),
                              label: Text(S.get('report_result')),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Notes field
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.get('notes'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _notesController,
                          maxLines: 3,
                          decoration: InputDecoration(
                            hintText: S.get('notes_hint'),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: prediction.id != null && !_notesSaved
                                ? () => _saveNotes(prediction.id!)
                                : null,
                            icon: Icon(_notesSaved ? Icons.check : Icons.save),
                            label: Text(
                              _notesSaved
                                  ? S.get('saved')
                                  : S.get('save_notes'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // All class probabilities — horizontal bar chart
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.get('all_results'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 10),
                        if (prediction.allConfidences != null)
                          _buildConfidenceChart(context, modelInfo, prediction),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  CameraScreen(leafType: widget.leafType),
                            ),
                          );
                        },
                        icon: const Icon(Icons.camera_alt),
                        label: Text(S.get('scan_again')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.popUntil(context, (route) => route.isFirst);
                        },
                        icon: const Icon(Icons.home),
                        label: Text(S.get('home')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showReportDialog(BuildContext context, Prediction prediction) {
    final reasonController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              S.get('report_wrong_result'),
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: S.get('report_reason_hint'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                final reason = reasonController.text.trim();
                if (reason.isEmpty) return;
                Navigator.pop(ctx);
                final ok = await submitModelReport(
                  modelVersion: prediction.modelVersion,
                  leafType: prediction.leafType,
                  predictionId: prediction.id,
                  reason: reason,
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? S.get('report_sent')
                          : S.get('report_failed'),
                    ),
                  ),
                );
              },
              child: Text(S.get('submit_report')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfidenceChart(
    BuildContext context,
    LeafModelInfo modelInfo,
    Prediction prediction,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final confs = prediction.allConfidences ?? [];
    if (confs.isEmpty) return const SizedBox.shrink();
    final topIndex = prediction.predictedClassIndex;

    // Build sorted indices by confidence descending
    final indices = List.generate(confs.length, (i) => i);
    indices.sort((a, b) => confs[b].compareTo(confs[a]));

    final barHeight = 28.0;
    final chartHeight = indices.length * barHeight + 16;

    return SizedBox(
      height: chartHeight,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: 1.0,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final idx = indices[group.x.toInt()];
                final label = modelInfo.localizedClassName(
                  modelInfo.classLabels[idx],
                  S.locale,
                );
                return BarTooltipItem(
                  '$label\n${(rod.toY * 100).toStringAsFixed(1)}%',
                  TextStyle(color: colorScheme.onSurface, fontSize: 12),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final idx = indices[value.toInt()];
                  final label = modelInfo.localizedClassName(
                    modelInfo.classLabels[idx],
                    S.locale,
                  );
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: SizedBox(
                      width: 60,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: idx == topIndex
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 9,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                },
                reservedSize: 40,
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  return Text(
                    '${(value * 100).toInt()}%',
                    style: Theme.of(context).textTheme.labelSmall,
                  );
                },
                interval: 0.25,
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: true,
            horizontalInterval: 0.25,
            getDrawingHorizontalLine: (value) => FlLine(
              color: colorScheme.outlineVariant.withAlpha(80),
              strokeWidth: 1,
            ),
            drawVerticalLine: false,
          ),
          barGroups: List.generate(indices.length, (barIndex) {
            final idx = indices[barIndex];
            final conf = confs[idx];
            final isTop = idx == topIndex;
            return BarChartGroupData(
              x: barIndex,
              barRods: [
                BarChartRodData(
                  toY: conf,
                  color: isTop ? colorScheme.primary : colorScheme.outline,
                  width: 16,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
