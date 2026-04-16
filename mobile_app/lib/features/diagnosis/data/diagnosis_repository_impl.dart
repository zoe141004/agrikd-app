import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:app/core/utils/file_helper.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/utils/image_preprocessor.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/data/sync/sync_queue.dart';
import '../domain/models/prediction.dart';
import '../domain/repositories/diagnosis_repository.dart';
import 'tflite_inference_service.dart';

class DiagnosisRepositoryImpl implements DiagnosisRepository {
  final TfliteInferenceService _inferenceService;
  final PredictionDao _predictionDao;
  final SyncQueue _syncQueue;
  final ModelDao _modelDao;

  /// Tracks the model version currently loaded for inference.
  String _loadedModelVersion = '1.0.0';

  /// Class labels for the currently loaded model (from OTA DB record or bundled constants).
  List<String>? _loadedClassLabels;
  int? _loadedNumClasses;

  /// Cached selected model record to avoid redundant DB queries on every
  /// diagnose() call for the same leaf type.
  String? _cachedLeafType;
  Map<String, dynamic>? _cachedSelectedModel;

  DiagnosisRepositoryImpl({
    required TfliteInferenceService inferenceService,
    required PredictionDao predictionDao,
    required SyncQueue syncQueue,
    required ModelDao modelDao,
  }) : _inferenceService = inferenceService,
       _predictionDao = predictionDao,
       _syncQueue = syncQueue,
       _modelDao = modelDao;

  @override
  Future<void> loadModel(String leafType) async {
    // Use cached DB record if same leafType (avoids ~5ms DB query per capture)
    Map<String, dynamic>? active;
    if (_cachedLeafType == leafType) {
      active = _cachedSelectedModel;
    } else {
      active = await _modelDao.getSelected(leafType);
      _cachedLeafType = leafType;
      _cachedSelectedModel = active;
    }

    if (active != null && (active['is_bundled'] as int) == 0) {
      final filePath = active['file_path'] as String;
      final activeVersion = active['version'] as String;
      final loaded = await _inferenceService.loadModelFromFile(
        filePath,
        leafType: leafType,
        version: activeVersion,
      );
      if (loaded) {
        _loadedModelVersion = activeVersion;
        _setClassLabelsFromRecord(active, leafType);
        _cleanupOldModelFiles(filePath, leafType);
        return;
      }

      // Selected OTA failed — try removing and selecting another
      await _modelDao.removeVersion(leafType, activeVersion);
      _cachedSelectedModel = null;
      _cachedLeafType = null;

      final fallback = await _modelDao.getSelected(leafType);
      if (fallback != null && (fallback['is_bundled'] as int) == 0) {
        final fbPath = fallback['file_path'] as String;
        final fbVersion = fallback['version'] as String;
        final fbLoaded = await _inferenceService.loadModelFromFile(
          fbPath,
          leafType: leafType,
          version: fbVersion,
        );
        if (fbLoaded) {
          _loadedModelVersion = fbVersion;
          _setClassLabelsFromRecord(fallback, leafType);
          _cleanupOldModelFiles(fbPath, leafType);
          return;
        }
      }
    }

    // 2. Fallback to bundled asset (ultimate fallback)
    final modelInfo = ModelConstants.getModel(leafType);
    final bundledVersion =
        (active != null && (active['is_bundled'] as int) == 1)
        ? active['version'] as String
        : '1.0.0';
    await _inferenceService.loadModel(
      modelInfo.assetPath,
      leafType: leafType,
      version: bundledVersion,
    );
    _loadedClassLabels = modelInfo.classLabels;
    _loadedNumClasses = modelInfo.numClasses;
    _loadedModelVersion = bundledVersion;
  }

  /// Fire-and-forget cleanup of orphaned model files after successful load.
  void _cleanupOldModelFiles(String loadedFilePath, String leafType) {
    final modelDir = p.dirname(loadedFilePath);
    unawaited(
      _modelDao.cleanupOrphanedFiles(leafType, modelDir).catchError((e) {
        debugPrint('[DiagnosisRepo] Model cleanup failed: $e');
      }),
    );
  }

  /// Extract class labels from a DB model record, falling back to ModelConstants.
  void _setClassLabelsFromRecord(Map<String, dynamic> record, String leafType) {
    final labelsRaw = record['class_labels'];
    if (labelsRaw != null && labelsRaw is String && labelsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(labelsRaw);
        if (decoded is List) {
          _loadedClassLabels = decoded.cast<String>();
          _loadedNumClasses =
              record['num_classes'] as int? ?? _loadedClassLabels!.length;
          return;
        }
      } catch (e) {
        debugPrint('[DiagnosisRepo] Failed to decode class labels: $e');
      }
    }
    // Fallback to bundled constants
    final modelInfo = ModelConstants.getModel(leafType);
    _loadedClassLabels = modelInfo.classLabels;
    _loadedNumClasses = modelInfo.numClasses;
  }

  @override
  Future<Prediction> diagnose(String imagePath, String leafType) async {
    // 1. Validate image path (prevent path traversal)
    final normalizedPath = File(imagePath).path;
    if (normalizedPath.contains('..')) {
      throw ArgumentError('Invalid image path');
    }

    // 2. Validate file exists and check format
    final file = File(normalizedPath);
    if (!await file.exists()) {
      throw ArgumentError('Image file not found');
    }

    // Check file extension
    final ext = normalizedPath.toLowerCase();
    if (!ext.endsWith('.jpg') &&
        !ext.endsWith('.jpeg') &&
        !ext.endsWith('.png')) {
      throw ArgumentError('Unsupported image format. Use JPEG or PNG.');
    }

    final fileSize = await file.length();
    if (!ImagePreprocessor.isValidImageSize(fileSize)) {
      throw ArgumentError(
        'Image too large: ${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    }

    // 3. Validate leaf type
    if (!ModelConstants.availableLeafTypes.contains(leafType)) {
      throw ArgumentError('Unknown leaf type: $leafType');
    }

    // 4. Load model if needed (with OTA fallback chain)
    await loadModel(leafType);

    // 5. Preprocess image in background isolate (decode + resize + normalize)
    // This prevents UI jank from CPU-heavy image processing on the main thread.
    final input = await compute(preprocessImageFromPath, normalizedPath);

    // 6. Run inference (must stay on main thread — native TFLite pointer)
    final modelInfo = ModelConstants.getModel(leafType);
    final numClasses = _loadedNumClasses ?? modelInfo.numClasses;
    final classLabels = _loadedClassLabels ?? modelInfo.classLabels;
    final result = _inferenceService.runInference(input, numClasses);

    // 7. Build prediction
    final prediction = Prediction(
      imagePath: normalizedPath,
      leafType: leafType,
      modelVersion: _loadedModelVersion,
      predictedClassIndex: result.classIndex,
      predictedClassName: result.classIndex < classLabels.length
          ? classLabels[result.classIndex]
          : 'Unknown (${result.classIndex})',
      confidence: result.confidence,
      allConfidences: result.allProbabilities,
      inferenceTimeMs: result.inferenceTimeMs,
      createdAt: DateTime.now(),
    );

    // 8. Save to database
    final id = await _predictionDao.insert(prediction.toMap());

    // 9. Enqueue for sync
    await _syncQueue.enqueue(
      entityType: 'prediction',
      entityId: id,
      action: 'create',
      payload: jsonEncode(prediction.toMap()),
    );

    // Return prediction with assigned ID
    return Prediction(
      id: id,
      imagePath: prediction.imagePath,
      leafType: prediction.leafType,
      modelVersion: prediction.modelVersion,
      predictedClassIndex: prediction.predictedClassIndex,
      predictedClassName: prediction.predictedClassName,
      confidence: prediction.confidence,
      allConfidences: prediction.allConfidences,
      inferenceTimeMs: prediction.inferenceTimeMs,
      createdAt: prediction.createdAt,
    );
  }

  @override
  void dispose() {
    _cachedLeafType = null;
    _cachedSelectedModel = null;
    // Fire-and-forget: async TFLite interpreter cleanup.
    // Native resources will also be reclaimed on GC if dispose doesn't complete.
    _inferenceService.dispose();
  }
}
