import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/dao/model_dao.dart';
import '../data/database/dao/prediction_dao.dart';
import '../data/database/dao/preference_dao.dart';
import '../data/sync/sync_queue.dart';

final predictionDaoProvider = Provider<PredictionDao>((ref) {
  return PredictionDao();
});

final preferenceDaoProvider = Provider<PreferenceDao>((ref) {
  return PreferenceDao();
});

final syncQueueProvider = Provider<SyncQueue>((ref) {
  return SyncQueue();
});

final modelDaoProvider = Provider<ModelDao>((ref) {
  return ModelDao();
});
