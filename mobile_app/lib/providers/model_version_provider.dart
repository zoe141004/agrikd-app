import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/config/supabase_config.dart';
import 'package:app/core/constants/model_constants.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'database_provider.dart';

/// Info about a single model version on device.
class ModelVersionInfo {
  final String leafType;
  final String version;
  final String role; // 'active' or 'fallback'
  final bool isBundled;

  const ModelVersionInfo({
    required this.leafType,
    required this.version,
    required this.role,
    required this.isBundled,
  });
}

/// State for all model versions per leaf type.
class ModelVersionState {
  final Map<String, List<ModelVersionInfo>> versions;
  final bool isLoading;

  const ModelVersionState({this.versions = const {}, this.isLoading = false});
}

class ModelVersionNotifier extends StateNotifier<ModelVersionState> {
  final ModelDao _modelDao;

  ModelVersionNotifier(this._modelDao) : super(const ModelVersionState()) {
    load();
  }

  Future<void> load() async {
    state = ModelVersionState(versions: state.versions, isLoading: true);

    final result = <String, List<ModelVersionInfo>>{};
    for (final leafType in ModelConstants.availableLeafTypes) {
      final rows = await _modelDao.getByLeafType(leafType);
      result[leafType] = rows
          .map(
            (r) => ModelVersionInfo(
              leafType: r['leaf_type'] as String,
              version: r['version'] as String,
              role: r['role'] as String,
              isBundled: (r['is_bundled'] as int) == 1,
            ),
          )
          .toList();
    }

    state = ModelVersionState(versions: result);
  }

  Future<void> switchVersion(String leafType) async {
    await _modelDao.switchRole(leafType);
    await load();
  }
}

final modelVersionProvider =
    StateNotifierProvider<ModelVersionNotifier, ModelVersionState>((ref) {
      final modelDao = ref.watch(modelDaoProvider);
      return ModelVersionNotifier(modelDao);
    });

/// Submit a model report to Supabase.
Future<bool> submitModelReport({
  required String modelVersion,
  required String leafType,
  required int? predictionId,
  required String reason,
}) async {
  if (!SupabaseConfig.isInitialized) return false;
  final client = SupabaseConfig.client;
  final userId = client.auth.currentUser?.id;
  if (userId == null) return false;

  try {
    await client.from('model_reports').insert({
      'user_id': userId,
      'model_version': modelVersion,
      'leaf_type': leafType,
      'prediction_id': predictionId,
      'reason': reason,
    });
    return true;
  } catch (_) {
    return false;
  }
}
