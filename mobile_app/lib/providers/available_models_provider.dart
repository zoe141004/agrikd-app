import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/providers/model_version_provider.dart';
import 'package:app/providers/sync_provider.dart';

/// Merges bundled models (ModelConstants) with server-discovered models
/// (OTA downloads in DB + pending updates) into a single map.
///
/// Bundled models always take priority (they have full localization data).
/// Server-only models are built from DB class_labels or ModelUpdate data.
final availableModelsProvider = Provider<Map<String, LeafModelInfo>>((ref) {
  final mvState = ref.watch(modelVersionProvider);
  final syncState = ref.watch(syncProvider);
  final result = Map<String, LeafModelInfo>.from(ModelConstants.models);

  // Add server-only models discovered from local DB (already downloaded)
  for (final entry in mvState.versions.entries) {
    if (!result.containsKey(entry.key) && entry.value.isNotEmpty) {
      final first = entry.value.first;
      result[entry.key] = LeafModelInfo.fromServer(
        leafType: entry.key,
        numClasses: first.numClasses,
        classLabels: first.classLabels,
      );
    }
  }

  // Add server-only models from pending updates (not yet downloaded)
  for (final update in syncState.pendingModelUpdates) {
    if (!result.containsKey(update.leafType)) {
      result[update.leafType] = LeafModelInfo.fromServer(
        leafType: update.leafType,
        numClasses: update.numClasses,
        classLabels: update.classLabels,
        displayName: update.displayName,
      );
    }
  }

  return result;
});

/// Sorted list of all available leaf type keys (bundled first, then alphabetical).
final allLeafTypesProvider = Provider<List<String>>((ref) {
  final models = ref.watch(availableModelsProvider);
  final bundled = ModelConstants.availableLeafTypes;
  final serverOnly = models.keys.where((k) => !bundled.contains(k)).toList()
    ..sort();
  return [...bundled, ...serverOnly];
});
