import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/benchmark_provider.dart';
import 'package:app/providers/diagnosis_provider.dart';
import 'package:app/providers/model_version_provider.dart';
import 'package:app/core/config/supabase_config.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/data/sync/supabase_sync_service.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/connectivity_provider.dart';
import 'package:app/providers/database_provider.dart';
import 'package:app/providers/settings_provider.dart';

final supabaseSyncServiceProvider = Provider<SupabaseSyncService>((ref) {
  final predictionDao = ref.watch(predictionDaoProvider);
  final syncQueue = ref.watch(syncQueueProvider);
  final modelDao = ref.watch(modelDaoProvider);
  return SupabaseSyncService(
    predictionDao: predictionDao,
    syncQueue: syncQueue,
    modelDao: modelDao,
  );
});

enum SyncStatus { idle, syncing, success, error }

class SyncState {
  final SyncStatus status;
  final SyncResult? lastResult;
  final String? errorMessage;
  final DateTime? lastSyncedAt;

  /// Model updates available for manual download (check-only, no auto-download).
  final List<ModelUpdate> pendingModelUpdates;

  /// Leaf type currently being downloaded (null = idle).
  final String? downloadingLeafType;

  const SyncState({
    this.status = SyncStatus.idle,
    this.lastResult,
    this.errorMessage,
    this.lastSyncedAt,
    this.pendingModelUpdates = const [],
    this.downloadingLeafType,
  });

  SyncState copyWith({
    SyncStatus? status,
    SyncResult? lastResult,
    String? errorMessage,
    DateTime? lastSyncedAt,
    List<ModelUpdate>? pendingModelUpdates,
    String? downloadingLeafType,
    bool clearDownloading = false,
    bool clearError = false,
  }) {
    return SyncState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      pendingModelUpdates: pendingModelUpdates ?? this.pendingModelUpdates,
      downloadingLeafType: clearDownloading
          ? null
          : (downloadingLeafType ?? this.downloadingLeafType),
    );
  }
}

class SyncNotifier extends StateNotifier<SyncState>
    with WidgetsBindingObserver {
  final SupabaseSyncService _syncService;
  final Ref _ref;
  Timer? _debounce;
  bool _disposed = false;
  int _consecutiveFailures = 0;
  static const _maxBackoffSeconds = 60;

  bool get disposed => _disposed;

  SyncNotifier(this._syncService, this._ref) : super(const SyncState()) {
    WidgetsBinding.instance.addObserver(this);
    // Load persisted last-synced timestamp
    final raw = _ref.read(settingsProvider)['last_synced_at'];
    if (raw != null && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) {
        state = state.copyWith(lastSyncedAt: parsed);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      triggerSync();
    }
  }

  Future<void> syncNow() async {
    if (state.status == SyncStatus.syncing) return;
    if (!_syncService.isAuthenticated) return;

    state = state.copyWith(status: SyncStatus.syncing, clearError: true);
    try {
      final result = await _syncService.pushPendingPredictions();

      // Check-only: detect available updates and store in state for manual download
      await _checkModelUpdates();

      final now = DateTime.now();
      state = state.copyWith(
        status: SyncStatus.success,
        lastResult: result,
        lastSyncedAt: now,
      );
      // Persist for next app launch
      _ref
          .read(settingsProvider.notifier)
          .setValue('last_synced_at', now.toIso8601String());
      _consecutiveFailures = 0;
    } catch (e) {
      _consecutiveFailures++;
      state = state.copyWith(
        status: SyncStatus.error,
        errorMessage: S.get('sync_failed'),
      );
    }
  }

  Future<void> _checkModelUpdates() async {
    try {
      final modelDao = _ref.read(modelDaoProvider);
      final allModels = await modelDao.getAll();
      final localVersionsByLeaf = <String, Set<String>>{};
      for (final m in allModels) {
        final lt = m['leaf_type'] as String;
        localVersionsByLeaf
            .putIfAbsent(lt, () => {})
            .add(m['version'] as String);
      }

      final updates = await _syncService.checkModelUpdates(localVersionsByLeaf);
      // Store available updates in state — user triggers download manually from Settings
      state = state.copyWith(pendingModelUpdates: updates);
    } catch (e) {
      debugPrint('[SyncProvider] Model update check failed: $e');
      // Best-effort: don't fail the sync if update check fails
    }
  }

  /// Manually download a model update for the given leaf type.
  /// Called from the Settings screen when the user taps the download button.
  Future<void> downloadUpdate(String leafType) async {
    final updates = state.pendingModelUpdates;
    final update = updates.cast<ModelUpdate?>().firstWhere(
      (u) => u?.leafType == leafType,
      orElse: () => null,
    );
    if (update == null) return;
    if (state.downloadingLeafType != null) return; // already downloading

    state = state.copyWith(downloadingLeafType: leafType);
    try {
      final ok = await _syncService.downloadModelUpdate(update);
      if (ok) {
        // Refresh UI providers so the new model is immediately available
        _ref.read(modelVersionProvider.notifier).load();
        _ref.read(benchmarkProvider.notifier).load();
        // Invalidate diagnosis repository so the stale model cache is cleared
        _ref.invalidate(diagnosisRepositoryProvider);

        // Remove this update from the pending list
        final remaining = state.pendingModelUpdates
            .where((u) => u.leafType != leafType)
            .toList();
        state = state.copyWith(
          pendingModelUpdates: remaining,
          clearDownloading: true,
        );
      } else {
        state = state.copyWith(clearDownloading: true);
      }
    } catch (e) {
      debugPrint('[SyncProvider] Model download failed: $e');
      state = state.copyWith(clearDownloading: true);
    }
  }

  /// Debounced sync with exponential backoff on consecutive failures.
  /// Base delay: 2s. After N failures: min(2^N * 2, 60) seconds.
  /// Respects the auto_sync setting — skips if disabled.
  void triggerSync() {
    final settings = _ref.read(settingsProvider);
    final autoSync = settings['auto_sync'] != 'false';
    if (!autoSync) return;

    _debounce?.cancel();
    final backoffSeconds = _consecutiveFailures == 0
        ? 2
        : min(2 * (1 << _consecutiveFailures), _maxBackoffSeconds);
    _debounce = Timer(Duration(seconds: backoffSeconds), () {
      syncNow();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    super.dispose();
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final syncService = ref.watch(supabaseSyncServiceProvider);
  final notifier = SyncNotifier(syncService, ref);

  // Auto-trigger sync when connectivity changes to online
  ref.listen<bool>(isOnlineProvider, (previous, next) {
    if (next && previous == false) {
      // Retry Supabase init if app started offline (C1 fix)
      if (!SupabaseConfig.isInitialized) {
        SupabaseConfig.ensureInitialized()
            .then((ok) {
              if (notifier.disposed) return;
              if (ok) {
                ref.read(authProvider.notifier).retryInit();
                notifier.triggerSync();
              }
            })
            .catchError((e) {
              debugPrint('[SyncProvider] Supabase re-init failed: $e');
            });
      } else {
        notifier.triggerSync();
      }
    }
  });

  // Auto-trigger sync when auth state changes to authenticated
  ref.listen<AuthState>(authProvider, (previous, next) {
    if (next.status == AuthStatus.authenticated &&
        previous?.status != AuthStatus.authenticated) {
      notifier.triggerSync();
    }
  });

  return notifier;
});
