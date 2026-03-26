import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:app/core/utils/file_helper.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/utils/image_preprocessor.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/data/sync/sync_queue.dart';
import '../domain/models/prediction.dart';
import '../domain/repositories/diagnosis_repository.dart';
import 'tflite_inference_service.dart';

class DiagnosisRepositoryImpl implements DiagnosisRepository {
  final TfliteInferenceService _inferenceService;
  final PredictionDao _predictionDao;
  final SyncQueue _syncQueue;

  DiagnosisRepositoryImpl({
    required TfliteInferenceService inferenceService,
    required PredictionDao predictionDao,
    required SyncQueue syncQueue,
  }) : _inferenceService = inferenceService,
       _predictionDao = predictionDao,
       _syncQueue = syncQueue;

  @override
  Future<void> loadModel(String leafType) async {
    final modelInfo = ModelConstants.getModel(leafType);
    await _inferenceService.loadModel(modelInfo.assetPath, leafType: leafType);
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

    // 4. Load model if needed
    await loadModel(leafType);

    // 5. Preprocess image in background isolate (decode + resize + normalize)
    // This prevents UI jank from CPU-heavy image processing on the main thread.
    final input = await compute(preprocessImageFromPath, normalizedPath);

    // 6. Run inference (must stay on main thread — native TFLite pointer)
    final modelInfo = ModelConstants.getModel(leafType);
    final result = _inferenceService.runInference(input, modelInfo.numClasses);

    // 7. Build prediction
    final prediction = Prediction(
      imagePath: normalizedPath,
      leafType: leafType,
      modelVersion: '1.0.0',
      predictedClassIndex: result.classIndex,
      predictedClassName: modelInfo.classLabels[result.classIndex],
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
