import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/diagnosis/data/tflite_inference_service.dart';

final inferenceServiceProvider = Provider<TfliteInferenceService>((ref) {
  final service = TfliteInferenceService();
  ref.onDispose(() => service.dispose());
  return service;
});
