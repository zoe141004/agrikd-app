import 'dart:convert';
import 'package:flutter/foundation.dart';

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
    // 1. Try selected OTA model from DB
    final active = await _modelDao.getSelected(leafType);
    if (active != null && (active['is_bundled'] as int) == 0) {
      final filePath = active['file_path'] as String;
      final loaded = await _inferenceService.loadModelFromFile(
        filePath,
        leafType: leafType,
      );
      if (loaded) {
        _loadedModelVersion = active['version'] as String;
        _setClassLabelsFromRecord(active, leafType);
        return;
      }

      // Selected OTA failed — try removing and selecting another
      await _modelDao.removeVersion(leafType, active['version'] as String);

      final fallback = await _modelDao.getSelected(leafType);
      if (fallback != null && (fallback['is_bundled'] as int) == 0) {
        final fbPath = fallback['file_path'] as String;
        final fbLoaded = await _inferenceService.loadModelFromFile(
          fbPath,
          leafType: leafType,
        );
        if (fbLoaded) {
          _loadedModelVersion = fallback['version'] as String;
          _setClassLabelsFromRecord(fallback, leafType);
          return;
        }
      }
    }

    // 2. Fallback to bundled asset (ultimate fallback)
    final modelInfo = ModelConstants.getModel(leafType);
    await _inferenceService.loadModel(modelInfo.assetPath, leafType: leafType);
    _loadedClassLabels = modelInfo.classLabels;
    _loadedNumClasses = modelInfo.numClasses;

    // Use bundled model version from DB if available, else default
    if (active != null && (active['is_bundled'] as int) == 1) {
      _loadedModelVersion = active['version'] as String;
    } else {
      _loadedModelVersion = '1.0.0';
    }
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
    _inferenceService.dispose();
  }
}
