import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  const SyncState({
    this.status = SyncStatus.idle,
    this.lastResult,
    this.errorMessage,
    this.lastSyncedAt,
  });
}

class SyncNotifier extends StateNotifier<SyncState>
    with WidgetsBindingObserver {
  final SupabaseSyncService _syncService;
  final Ref _ref;
  Timer? _debounce;
  bool _disposed = false;

  bool get disposed => _disposed;

  SyncNotifier(this._syncService, this._ref) : super(const SyncState()) {
    WidgetsBinding.instance.addObserver(this);
    // Load persisted last-synced timestamp
    final raw = _ref.read(settingsProvider)['last_synced_at'];
    if (raw != null && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) {
        state = SyncState(lastSyncedAt: parsed);
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

    state = SyncState(
      status: SyncStatus.syncing,
      lastSyncedAt: state.lastSyncedAt,
    );
    try {
      final result = await _syncService.pushPendingPredictions();

      // Check for model updates after syncing predictions
      await _checkModelUpdates();

      final now = DateTime.now();
      state = SyncState(
        status: SyncStatus.success,
        lastResult: result,
        lastSyncedAt: now,
      );
      // Persist for next app launch
      _ref
          .read(settingsProvider.notifier)
          .setValue('last_synced_at', now.toIso8601String());
    } catch (e) {
      state = SyncState(
        status: SyncStatus.error,
        errorMessage: S.get('sync_failed'),
        lastSyncedAt: state.lastSyncedAt,
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
      for (final update in updates) {
        await _syncService.downloadModelUpdate(update);
      }
    } catch (_) {
      // Model update check is best-effort; don't fail the sync
    }
  }

  /// Debounced sync: waits 2 seconds after last trigger to batch requests.
  /// Respects the auto_sync setting — skips if disabled.
  void triggerSync() {
    final settings = _ref.read(settingsProvider);
    final autoSync = settings['auto_sync'] != 'false';
    if (!autoSync) return;

    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
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
        SupabaseConfig.ensureInitialized().then((ok) {
          if (notifier.disposed) return;
          if (ok) {
            ref.read(authProvider.notifier).retryInit();
            notifier.triggerSync();
          }
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
