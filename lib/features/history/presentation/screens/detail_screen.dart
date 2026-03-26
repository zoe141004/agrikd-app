import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/core/utils/image_widget.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/features/diagnosis/domain/models/prediction.dart';
import 'package:app/features/diagnosis/presentation/widgets/confidence_bar.dart';
import 'package:app/providers/database_provider.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final Prediction prediction;

  const DetailScreen({super.key, required this.prediction});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late final TextEditingController _notesController;
  late String _currentNotes;
  bool _isEditingNotes = false;
  static final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  @override
  void initState() {
    super.initState();
    _currentNotes = widget.prediction.notes ?? '';
    _notesController = TextEditingController(text: _currentNotes);
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _saveNotes() async {
    final newNotes = _notesController.text.trim();
    if (widget.prediction.id == null) return;

    await ref
        .read(predictionDaoProvider)
        .updateNotes(widget.prediction.id!, newNotes);

    setState(() {
      _currentNotes = newNotes;
      _isEditingNotes = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.get('notes_saved'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final prediction = widget.prediction;
    final modelInfo = ModelConstants.getModel(prediction.leafType);
    final displayName = modelInfo.localizedClassName(
      prediction.predictedClassName,
      S.locale,
    );

    return Scaffold(
      appBar: AppBar(title: Text(S.get('scan_detail'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Image
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: kIsWeb
                      ? Image.network(
                          prediction.imagePath,
                          height: 220,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stack) => Container(
                            height: 220,
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
                          height: 220,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stack) => Container(
                            height: 220,
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
                const SizedBox(height: 16),

                // Diagnosis info
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.get('diagnosis_info'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(S.get('disease_name'), displayName),
                        _InfoRow(
                          S.get('local_name'),
                          S.locale == 'vi'
                              ? (modelInfo.classEnglishNames[prediction
                                        .predictedClassName] ??
                                    prediction.predictedClassName)
                              : (modelInfo.classDisplayNames[prediction
                                        .predictedClassName] ??
                                    prediction.predictedClassName),
                        ),
                        _InfoRow(
                          S.get('how_sure'),
                          '${(prediction.confidence * 100).toStringAsFixed(1)}%',
                        ),
                        _InfoRow(
                          S.get('leaf_type'),
                          modelInfo.localizedName(S.locale),
                        ),
                        _InfoRow(S.get('model_ver'), prediction.modelVersion),
                        if (prediction.inferenceTimeMs != null)
                          _InfoRow(
                            S.get('processing_time'),
                            '${prediction.inferenceTimeMs!.toStringAsFixed(1)} ms',
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Notes section
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              S.get('notes'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if (!_isEditingNotes)
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20),
                                onPressed: () {
                                  setState(() => _isEditingNotes = true);
                                },
                              ),
                          ],
                        ),
                        if (_isEditingNotes) ...[
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
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () {
                                  _notesController.text = _currentNotes;
                                  setState(() => _isEditingNotes = false);
                                },
                                child: Text(S.get('cancel')),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _saveNotes,
                                child: Text(S.get('save')),
                              ),
                            ],
                          ),
                        ] else ...[
                          const SizedBox(height: 4),
                          Text(
                            _currentNotes.isEmpty
                                ? S.get('no_notes')
                                : _currentNotes,
                            style: _currentNotes.isEmpty
                                ? Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  )
                                : Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Metadata
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.get('metadata'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          S.get('date'),
                          _dateFormat.format(prediction.createdAt),
                        ),
                        _InfoRow(
                          S.get('backed_up'),
                          prediction.isSynced ? S.get('yes') : S.get('no'),
                        ),
                        if (prediction.syncedAt != null)
                          _InfoRow(
                            S.get('backed_up_at'),
                            _dateFormat.format(prediction.syncedAt!),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Probability distribution
                if (prediction.allConfidences != null)
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
                          const SizedBox(height: 12),
                          ...List.generate(modelInfo.classLabels.length, (i) {
                            return ConfidenceBar(
                              label: modelInfo.localizedClassName(
                                modelInfo.classLabels[i],
                                S.locale,
                              ),
                              confidence: prediction.allConfidences![i],
                              isTop: i == prediction.predictedClassIndex,
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
