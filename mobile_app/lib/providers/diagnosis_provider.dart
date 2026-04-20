import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/l10n/app_strings.dart';
import '../features/diagnosis/data/diagnosis_repository_impl.dart';
import '../features/diagnosis/domain/models/prediction.dart';
import '../features/diagnosis/domain/repositories/diagnosis_repository.dart';
import 'database_provider.dart';
import 'history_provider.dart';
import 'inference_provider.dart';

final selectedLeafTypeProvider = StateProvider<String>((ref) => 'tomato');

final diagnosisRepositoryProvider = Provider<DiagnosisRepository>((ref) {
  final inferenceService = ref.watch(inferenceServiceProvider);
  final predictionDao = ref.watch(predictionDaoProvider);
  final syncQueue = ref.watch(syncQueueProvider);
  final modelDao = ref.watch(modelDaoProvider);
  final repo = DiagnosisRepositoryImpl(
    inferenceService: inferenceService,
    predictionDao: predictionDao,
    syncQueue: syncQueue,
    modelDao: modelDao,
  );
  ref.onDispose(() => repo.dispose());
  return repo;
});

enum DiagnosisStatus { idle, loading, success, error }

class DiagnosisState {
  final DiagnosisStatus status;
  final Prediction? prediction;
  final String? errorMessage;

  const DiagnosisState({
    this.status = DiagnosisStatus.idle,
    this.prediction,
    this.errorMessage,
  });

  DiagnosisState copyWith({
    DiagnosisStatus? status,
    Prediction? prediction,
    String? errorMessage,
  }) {
    return DiagnosisState(
      status: status ?? this.status,
      prediction: prediction ?? this.prediction,
      errorMessage: errorMessage,
    );
  }
}

class DiagnosisNotifier extends StateNotifier<DiagnosisState> {
  final DiagnosisRepository _repository;
  final Ref _ref;

  DiagnosisNotifier(this._repository, this._ref)
    : super(const DiagnosisState());

  Future<void> diagnose(String imagePath, String leafType) async {
    state = const DiagnosisState(status: DiagnosisStatus.loading);
    try {
      final prediction = await _repository.diagnose(imagePath, leafType);
      state = DiagnosisState(
        status: DiagnosisStatus.success,
        prediction: prediction,
      );
      // Refresh history so the new prediction appears immediately without restart
      _ref.read(historyProvider.notifier).refresh();
    } catch (e) {
      state = DiagnosisState(
        status: DiagnosisStatus.error,
        errorMessage: friendlyDiagnosisError(e),
      );
    }
  }

  @visibleForTesting
  static String friendlyDiagnosisError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('integrity check failed') || msg.contains('corrupted')) {
      return S.get('err_model_corrupted');
    }
    if (msg.contains('not loaded') || msg.contains('loadmodel')) {
      return S.get('err_model_not_loaded');
    }
    if (msg.contains('too large')) return S.get('err_image_too_large');
    if (msg.contains('unsupported') || msg.contains('format')) {
      return S.get('err_unsupported_format');
    }
    if (msg.contains('not found')) return S.get('err_image_not_found');
    if (msg.contains('invalid image') || msg.contains('could not decode')) {
      return S.get('err_invalid_image');
    }
    return S.get('err_diagnosis_failed');
  }

  void reset() {
    state = const DiagnosisState();
  }
}

final diagnosisProvider =
    StateNotifierProvider<DiagnosisNotifier, DiagnosisState>((ref) {
      final repository = ref.watch(diagnosisRepositoryProvider);
      return DiagnosisNotifier(repository, ref);
    });
