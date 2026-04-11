import 'dart:typed_data';

/// Stub inference result, shared between mobile and web.
class InferenceResult {
  final int classIndex;
  final double confidence;
  final List<double> allProbabilities;
  final double inferenceTimeMs;
  final String delegateUsed;

  const InferenceResult({
    required this.classIndex,
    required this.confidence,
    required this.allProbabilities,
    required this.inferenceTimeMs,
    required this.delegateUsed,
  });
}

/// Web stub — TFLite inference is not available on web.
class TfliteInferenceService {
  bool get isLoaded => false;
  String get currentLeafType => '';
  String get currentVersion => '';
  String get delegateUsed => 'none';

  Future<void> loadModel(
    String assetPath, {
    String? leafType,
    String? version,
  }) async {
    throw UnsupportedError('TFLite inference is not supported on web.');
  }

  Future<bool> loadModelFromFile(
    String filePath, {
    String? leafType,
    String? version,
  }) async {
    throw UnsupportedError('TFLite inference is not supported on web.');
  }

  InferenceResult runInference(Float32List input, int numClasses) {
    throw UnsupportedError('TFLite inference is not supported on web.');
  }

  void dispose() {}
}
