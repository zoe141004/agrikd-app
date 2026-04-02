import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:app/core/config/supabase_config.dart';
import 'package:app/core/utils/image_compressor.dart';
import 'package:app/core/utils/model_integrity.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/features/diagnosis/domain/models/prediction.dart';
import 'sync_queue.dart';

class SupabaseSyncService {
  final PredictionDao _predictionDao;
  final SyncQueue _syncQueue;
  final ModelDao _modelDao;

  /// Matches only lowercase letters, digits, and underscores.
  static final _safeNamePattern = RegExp(r'^[a-z0-9_]+$');

  SupabaseSyncService({
    required PredictionDao predictionDao,
    required SyncQueue syncQueue,
    required ModelDao modelDao,
  }) : _predictionDao = predictionDao,
       _syncQueue = syncQueue,
       _modelDao = modelDao;

  SupabaseClient get _client => SupabaseConfig.client;

  bool get isAuthenticated =>
      SupabaseConfig.isInitialized && _client.auth.currentUser != null;

  String? get _userId => _client.auth.currentUser?.id;

  /// Sanitize a name for use in file paths — reject path traversal attempts.
  static String _sanitizeName(String name) {
    if (name.isEmpty || !_safeNamePattern.hasMatch(name)) {
      throw ArgumentError('Invalid name for file path: "$name"');
    }
    return name;
  }

  /// Push all pending predictions to Supabase.
  Future<SyncResult> pushPendingPredictions() async {
    if (!isAuthenticated) {
      return const SyncResult(
        synced: 0,
        failed: 0,
        message: 'Not authenticated',
      );
    }

    final pending = await _syncQueue.getPending(limit: 50);
    int synced = 0;
    int failed = 0;

    for (final item in pending) {
      final queueId = item['id'] as int;
      final entityId = item['entity_id'] as int;

      try {
        // Get prediction from local DB
        final predMap = await _predictionDao.getById(entityId);
        if (predMap == null) {
          await _syncQueue.markFailed(queueId);
          failed++;
          continue;
        }

        final prediction = Prediction.fromMap(predMap);

        // Upload image to Supabase Storage
        String? imageUrl;
        if (prediction.imagePath.isNotEmpty) {
          imageUrl = await _uploadImage(prediction.imagePath, entityId);
        }

        // Upsert prediction into Supabase table (dedup on user_id + local_id)
        final response = await _client
            .from('predictions')
            .upsert({
              'user_id': _userId,
              'image_url': imageUrl,
              'leaf_type': prediction.leafType,
              'model_version': prediction.modelVersion,
              'predicted_class_index': prediction.predictedClassIndex,
              'predicted_class_name': prediction.predictedClassName,
              'confidence': prediction.confidence,
              'all_confidences': prediction.allConfidences,
              'inference_time_ms': prediction.inferenceTimeMs,
              'notes': prediction.notes,
              'created_at': prediction.createdAt.toUtc().toIso8601String(),
              'local_id': entityId,
            }, onConflict: 'user_id,local_id')
            .select('id')
            .single();

        final serverId = response['id'].toString();

        // Mark synced in local DB
        await _predictionDao.markSynced(entityId, serverId);
        await _syncQueue.markCompleted(queueId);
        synced++;
      } catch (e) {
        await _syncQueue.incrementRetry(queueId);
        final retryCount = (item['retry_count'] as int) + 1;
        final maxRetries = item['max_retries'] as int;
        if (retryCount >= maxRetries) {
          await _syncQueue.markFailed(queueId);
        }
        failed++;
      }
    }

    // Clean up old completed/failed entries
    await _syncQueue.cleanup();

    return SyncResult(
      synced: synced,
      failed: failed,
      message: 'Synced $synced, failed $failed of ${pending.length}',
    );
  }

  /// Upload and compress image to Supabase Storage.
  Future<String?> _uploadImage(String imagePath, int localId) async {
    try {
      final userId = _userId;
      if (userId == null) return null;

      final compressed = await compute(compressImageSync, imagePath);
      final path =
          '$userId/${DateTime.now().millisecondsSinceEpoch}_$localId.jpg';

      await _client.storage
          .from('prediction-images')
          .uploadBinary(
            path,
            compressed,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );

      return _client.storage.from('prediction-images').getPublicUrl(path);
    } catch (e) {
      // Image upload failure should not block prediction sync
      return null;
    }
  }

  /// Check for model updates from remote registry.
  Future<List<ModelUpdate>> checkModelUpdates(
    Map<String, String> localVersions,
  ) async {
    try {
      final response = await _client
          .from('model_registry')
          .select()
          .order('updated_at', ascending: false);

      final updates = <ModelUpdate>[];
      for (final row in response) {
        final leafType = row['leaf_type'] as String;
        final remoteVersion = row['version'] as String;
        final localVersion = localVersions[leafType];

        if (localVersion == null || localVersion != remoteVersion) {
          final labels = (jsonDecode(row['class_labels'] as String) as List)
              .cast<String>();
          updates.add(
            ModelUpdate(
              leafType: leafType,
              version: remoteVersion,
              fileUrl: row['file_url'] as String?,
              sha256Checksum: row['sha256_checksum'] as String,
              classLabels: labels,
              numClasses: row['num_classes'] as int? ?? labels.length,
            ),
          );
        }
      }
      return updates;
    } catch (e) {
      return [];
    }
  }

  /// Download, verify, and apply a model update atomically.
  /// Uses temp file + rename for atomic writes, then promotes via ModelDao.
  /// Returns true if the model was successfully updated.
  Future<bool> downloadModelUpdate(ModelUpdate update) async {
    if (update.fileUrl == null || update.fileUrl!.isEmpty) return false;

    try {
      // Sanitize leaf type and version to prevent path traversal
      final safeLeafType = _sanitizeName(update.leafType);
      final safeVersion = _sanitizeName(update.version.replaceAll('.', '_'));

      // 1. Download the file from Supabase Storage
      final Uint8List bytes = await _client.storage
          .from('models')
          .download(update.fileUrl!);

      // 2. Verify SHA-256 checksum
      final actualHash = ModelIntegrity.sha256Bytes(bytes);
      if (actualHash != update.sha256Checksum) {
        return false; // Integrity check failed
      }

      // 3. Save to temp file first, then rename (atomic)
      final dir = await getApplicationDocumentsDirectory();
      final modelDir = Directory('${dir.path}/models/$safeLeafType');
      await modelDir.create(recursive: true);
      final finalPath =
          '${modelDir.path}/${safeLeafType}_$safeVersion.tflite';
      final tempPath = '$finalPath.tmp';

      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(bytes);
      await tempFile.rename(finalPath);

      // 4. Promote via ModelDao (handles 2-version rotation)
      await _modelDao.promoteNewVersion(
        leafType: update.leafType,
        version: update.version,
        filePath: finalPath,
        checksum: update.sha256Checksum,
        numClasses: update.numClasses,
        classLabels: jsonEncode(update.classLabels),
      );

      return true;
    } catch (e) {
      return false;
    }
  }
}

class SyncResult {
  final int synced;
  final int failed;
  final String message;

  const SyncResult({
    required this.synced,
    required this.failed,
    required this.message,
  });
}

class ModelUpdate {
  final String leafType;
  final String version;
  final String? fileUrl;
  final String sha256Checksum;
  final List<String> classLabels;
  final int numClasses;

  const ModelUpdate({
    required this.leafType,
    required this.version,
    this.fileUrl,
    required this.sha256Checksum,
    required this.classLabels,
    required this.numClasses,
  });
}
