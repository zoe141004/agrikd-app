import 'package:flutter_test/flutter_test.dart';
import 'package:app/data/sync/sync_queue.dart';

import 'test_helper.dart';

void main() {
  late SyncQueue queue;

  setUpAll(() {
    initTestDatabase();
  });

  setUp(() async {
    await resetTestDatabase();
    queue = SyncQueue();
  });

  group('enqueue and getPending', () {
    test('enqueue inserts a row and getPending returns it', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      expect(id, greaterThan(0));

      final pending = await queue.getPending();
      expect(pending, hasLength(1));
      expect(pending.first['entity_type'], 'prediction');
      expect(pending.first['entity_id'], 1);
      expect(pending.first['action'], 'upload');
      expect(pending.first['status'], 'pending');
      expect(pending.first['retry_count'], 0);
      expect(pending.first['max_retries'], 3);
    });

    test('enqueue stores optional payload', () async {
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'upload',
        payload: '{"key":"value"}',
      );

      final pending = await queue.getPending();
      expect(pending.first['payload'], '{"key":"value"}');
    });

    test('enqueue multiple items returns all pending', () async {
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'upload',
      );
      await queue.enqueue(entityType: 'model', entityId: 3, action: 'download');

      final pending = await queue.getPending();
      expect(pending, hasLength(3));
    });
  });

  group('getPending respects retry limit', () {
    test('items at max_retries are excluded', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      // Default max_retries is 3, so after 3 increments retry_count == 3
      // which is no longer < max_retries.
      await queue.incrementRetry(id);
      await queue.incrementRetry(id);
      await queue.incrementRetry(id);

      final pending = await queue.getPending();
      expect(pending, isEmpty);
    });

    test('items below max_retries are still returned', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.incrementRetry(id);
      await queue.incrementRetry(id);
      // retry_count == 2, still < 3

      final pending = await queue.getPending();
      expect(pending, hasLength(1));
      expect(pending.first['retry_count'], 2);
    });
  });

  group('getPending ordering', () {
    test('returns items ordered by created_at ASC', () async {
      // Insert items sequentially; SQLite default datetime('now') has
      // second-level granularity, so we rely on ROWID / insertion order
      // for items created within the same second.
      final id1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 10,
        action: 'upload',
      );
      final id2 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 20,
        action: 'upload',
      );
      final id3 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 30,
        action: 'upload',
      );

      final pending = await queue.getPending();
      expect(pending, hasLength(3));
      expect(pending[0]['id'], id1);
      expect(pending[1]['id'], id2);
      expect(pending[2]['id'], id3);
    });

    test('getPending respects limit parameter', () async {
      for (var i = 1; i <= 5; i++) {
        await queue.enqueue(
          entityType: 'prediction',
          entityId: i,
          action: 'upload',
        );
      }

      final pending = await queue.getPending(limit: 2);
      expect(pending, hasLength(2));
    });
  });

  group('markCompleted', () {
    test('changes status to completed', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.markCompleted(id);

      // Completed items should not appear in getPending.
      final pending = await queue.getPending();
      expect(pending, isEmpty);
    });

    test('does not affect other pending items', () async {
      final id1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'upload',
      );

      await queue.markCompleted(id1);

      final pending = await queue.getPending();
      expect(pending, hasLength(1));
      expect(pending.first['entity_id'], 2);
    });
  });

  group('markFailed', () {
    test('changes status to failed', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.markFailed(id);

      final pending = await queue.getPending();
      expect(pending, isEmpty);
    });

    test('does not affect other pending items', () async {
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );
      final id2 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'upload',
      );

      await queue.markFailed(id2);

      final pending = await queue.getPending();
      expect(pending, hasLength(1));
      expect(pending.first['entity_id'], 1);
    });
  });

  group('incrementRetry', () {
    test('increments retry_count by 1', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.incrementRetry(id);

      final pending = await queue.getPending();
      expect(pending.first['retry_count'], 1);
    });

    test('increments cumulatively', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.incrementRetry(id);
      await queue.incrementRetry(id);

      final pending = await queue.getPending();
      expect(pending.first['retry_count'], 2);
    });
  });

  group('cleanup', () {
    test('removes all failed entries', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.markFailed(id);

      final removed = await queue.cleanup();
      expect(removed, 1);
    });

    test('removes old completed entries beyond age threshold', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.markCompleted(id);

      // With a Duration.zero age, any completed entry qualifies for removal.
      final removed = await queue.cleanup(age: Duration.zero);
      expect(removed, 1);
    });

    test('preserves recent completed entries', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      await queue.markCompleted(id);

      // Default age is 7 days; the just-completed entry should survive.
      final removed = await queue.cleanup();
      expect(removed, 0);
    });

    test('preserves pending entries', () async {
      await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );

      final removed = await queue.cleanup();
      expect(removed, 0);

      final pending = await queue.getPending();
      expect(pending, hasLength(1));
    });

    test('mixed scenario removes failed and old completed only', () async {
      final pending1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'upload',
      );
      final failed1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'upload',
      );
      final completed1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 3,
        action: 'upload',
      );

      await queue.markFailed(failed1);
      await queue.markCompleted(completed1);

      // With default age (7 days), recent completed stays, failed removed.
      final removed = await queue.cleanup();
      expect(removed, 1); // only the failed entry

      // The pending item should still be returned.
      final remaining = await queue.getPending();
      expect(remaining, hasLength(1));
      expect(remaining.first['id'], pending1);
    });
  });
}
