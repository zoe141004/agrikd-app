import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/sync/supabase_sync_service.dart';
import 'package:app/providers/sync_provider.dart';

void main() {
  group('SupabaseSyncService.sanitizeName', () {
    test('accepts valid lowercase name', () {
      expect(SupabaseSyncService.sanitizeName('tomato'), 'tomato');
    });

    test('accepts name with underscores', () {
      expect(
        SupabaseSyncService.sanitizeName('burmese_grape_leaf'),
        'burmese_grape_leaf',
      );
    });

    test('accepts name with digits', () {
      expect(SupabaseSyncService.sanitizeName('v1_0_0'), 'v1_0_0');
    });

    test('rejects empty string', () {
      expect(
        () => SupabaseSyncService.sanitizeName(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects path traversal with ..', () {
      expect(
        () => SupabaseSyncService.sanitizeName('../etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects forward slashes', () {
      expect(
        () => SupabaseSyncService.sanitizeName('path/to/file'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects uppercase letters', () {
      expect(
        () => SupabaseSyncService.sanitizeName('Tomato'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects spaces', () {
      expect(
        () => SupabaseSyncService.sanitizeName('leaf type'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects hyphens', () {
      expect(
        () => SupabaseSyncService.sanitizeName('burmese-grape'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects dots (e.g. version with dots)', () {
      expect(
        () => SupabaseSyncService.sanitizeName('v1.0.0'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SyncResult', () {
    test('constructs with all required fields', () {
      const result = SyncResult(synced: 5, failed: 1, message: 'ok');
      expect(result.synced, 5);
      expect(result.failed, 1);
      expect(result.message, 'ok');
    });

    test('synced=0 failed=0 is valid', () {
      const result = SyncResult(
        synced: 0,
        failed: 0,
        message: 'nothing to sync',
      );
      expect(result.synced, 0);
      expect(result.failed, 0);
    });
  });

  group('ModelUpdate', () {
    test('constructs with required fields and no fileUrl', () {
      const update = ModelUpdate(
        leafType: 'tomato',
        version: '2.0.0',
        sha256Checksum: 'abc123',
        classLabels: ['Healthy', 'Late_blight'],
        numClasses: 2,
      );
      expect(update.leafType, 'tomato');
      expect(update.version, '2.0.0');
      expect(update.fileUrl, isNull);
      expect(update.sha256Checksum, 'abc123');
      expect(update.classLabels, hasLength(2));
      expect(update.numClasses, 2);
    });

    test('constructs with optional fileUrl', () {
      const update = ModelUpdate(
        leafType: 'burmese_grape_leaf',
        version: '1.2.0',
        fileUrl: 'https://example.com/model.tflite',
        sha256Checksum: 'def456',
        classLabels: ['Anthracnose', 'Healthy', 'Insect_Damage'],
        numClasses: 3,
      );
      expect(update.fileUrl, isNotNull);
      expect(update.numClasses, 3);
    });
  });

  group('SyncStatus enum', () {
    test('has exactly 4 values', () {
      expect(SyncStatus.values, hasLength(4));
    });

    test('contains expected statuses', () {
      expect(
        SyncStatus.values,
        containsAll([
          SyncStatus.idle,
          SyncStatus.syncing,
          SyncStatus.success,
          SyncStatus.error,
        ]),
      );
    });
  });

  group('SyncState', () {
    test('defaults to idle, no result, no error, no timestamp', () {
      const state = SyncState();
      expect(state.status, SyncStatus.idle);
      expect(state.lastResult, isNull);
      expect(state.errorMessage, isNull);
      expect(state.lastSyncedAt, isNull);
    });

    test('can be constructed with status=syncing', () {
      const state = SyncState(status: SyncStatus.syncing);
      expect(state.status, SyncStatus.syncing);
    });

    test('can be constructed with lastSyncedAt', () {
      final now = DateTime.now();
      final state = SyncState(lastSyncedAt: now);
      expect(state.lastSyncedAt, now);
    });

    test('can be constructed with errorMessage', () {
      const state = SyncState(
        status: SyncStatus.error,
        errorMessage: 'network timeout',
      );
      expect(state.status, SyncStatus.error);
      expect(state.errorMessage, 'network timeout');
    });

    test('can hold a SyncResult', () {
      const result = SyncResult(synced: 3, failed: 0, message: 'done');
      const state = SyncState(status: SyncStatus.success, lastResult: result);
      expect(state.lastResult?.synced, 3);
    });
  });

  group('SyncState.copyWith', () {
    test('no arguments preserves all fields', () {
      final now = DateTime.now();
      const result = SyncResult(synced: 3, failed: 0, message: 'ok');
      const update = ModelUpdate(
        leafType: 'tomato',
        version: '2.0.0',
        sha256Checksum: 'abc',
        classLabels: ['Healthy'],
        numClasses: 1,
      );
      final state = SyncState(
        status: SyncStatus.success,
        lastResult: result,
        errorMessage: 'err',
        lastSyncedAt: now,
        pendingModelUpdates: const [update],
        downloadingModel: (leafType: 'tomato', version: '2.0.0'),
      );
      final copy = state.copyWith();
      expect(copy.status, SyncStatus.success);
      expect(copy.lastResult?.synced, 3);
      expect(copy.errorMessage, 'err');
      expect(copy.lastSyncedAt, now);
      expect(copy.pendingModelUpdates, hasLength(1));
      expect(copy.downloadingModel?.leafType, 'tomato');
    });

    test('sets downloadingModel', () {
      const state = SyncState();
      final copy = state.copyWith(
        downloadingModel: (leafType: 'tomato', version: '1.0.0'),
      );
      expect(copy.downloadingModel?.leafType, 'tomato');
    });

    test('clearDownloading resets downloadingModel to null', () {
      final state = SyncState(
        downloadingModel: (leafType: 'tomato', version: '1.0.0'),
      );
      final copy = state.copyWith(clearDownloading: true);
      expect(copy.downloadingModel, isNull);
    });

    test('clearDownloading when already null stays null', () {
      const state = SyncState();
      final copy = state.copyWith(clearDownloading: true);
      expect(copy.downloadingModel, isNull);
    });

    test('clearDownloading takes precedence over downloadingModel', () {
      const state = SyncState();
      final copy = state.copyWith(
        downloadingModel: (leafType: 'burmese_grape_leaf', version: '1.0.0'),
        clearDownloading: true,
      );
      expect(copy.downloadingModel, isNull);
    });

    test('replaces pendingModelUpdates', () {
      const update = ModelUpdate(
        leafType: 'tomato',
        version: '2.0.0',
        sha256Checksum: 'abc',
        classLabels: ['Healthy'],
        numClasses: 1,
      );
      const state = SyncState();
      final copy = state.copyWith(pendingModelUpdates: [update]);
      expect(copy.pendingModelUpdates, hasLength(1));
      expect(copy.pendingModelUpdates.first.leafType, 'tomato');
    });

    test('empty pendingModelUpdates clears the list', () {
      const update = ModelUpdate(
        leafType: 'tomato',
        version: '1.0.0',
        sha256Checksum: 'abc',
        classLabels: ['Healthy'],
        numClasses: 1,
      );
      const state = SyncState(pendingModelUpdates: [update]);
      final copy = state.copyWith(pendingModelUpdates: []);
      expect(copy.pendingModelUpdates, isEmpty);
    });

    test('clearError resets errorMessage to null', () {
      const state = SyncState(
        status: SyncStatus.error,
        errorMessage: 'timeout',
      );
      final copy = state.copyWith(clearError: true);
      expect(copy.errorMessage, isNull);
    });

    test('clearError when no error preserves null', () {
      const state = SyncState();
      final copy = state.copyWith(clearError: true);
      expect(copy.errorMessage, isNull);
    });

    test('sets status independently', () {
      const state = SyncState();
      final copy = state.copyWith(status: SyncStatus.syncing);
      expect(copy.status, SyncStatus.syncing);
    });
  });

  group('Sync debounce backoff calculation', () {
    // Mirrors SyncNotifier logic:
    // _consecutiveFailures == 0 → 2 seconds
    // else → min(2 * (1 << failures), 60) seconds
    const maxBackoffSeconds = 60;

    int backoffSeconds(int failures) {
      return failures == 0 ? 2 : min(2 * (1 << failures), maxBackoffSeconds);
    }

    test('0 failures → 2 seconds', () => expect(backoffSeconds(0), 2));
    test('1 failure → 4 seconds', () => expect(backoffSeconds(1), 4));
    test('2 failures → 8 seconds', () => expect(backoffSeconds(2), 8));
    test('3 failures → 16 seconds', () => expect(backoffSeconds(3), 16));
    test('4 failures → 32 seconds', () => expect(backoffSeconds(4), 32));
    test(
      '5 failures → capped at 60 seconds',
      () => expect(backoffSeconds(5), 60),
    );
    test(
      '10 failures → still capped at 60 seconds',
      () => expect(backoffSeconds(10), 60),
    );
  });
}
