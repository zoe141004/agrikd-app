import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/database/app_database.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/data/database/dao/preference_dao.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/sync/sync_queue.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
    await resetTestDatabase();
    await AppDatabase.database;
  });

  group('PredictionDao', () {
    late PredictionDao dao;

    setUpAll(() async {
      dao = PredictionDao();
    });

    test('insert and getById', () async {
      final id = await dao.insert({
        'image_path': '/test/photo1.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Tomato___Bacterial_spot',
        'confidence': 0.85,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_synced': 0,
      });
      expect(id, greaterThan(0));

      final row = await dao.getById(id);
      expect(row, isNotNull);
      expect(row!['leaf_type'], 'tomato');
      expect(row['confidence'], 0.85);
    });

    test('getAll with leafType filter', () async {
      await dao.insert({
        'image_path': '/test/photo2.jpg',
        'leaf_type': 'burmese_grape_leaf',
        'model_version': '1.0.0',
        'predicted_class_index': 1,
        'predicted_class_name': 'Healthy',
        'confidence': 0.92,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_synced': 0,
      });

      final burmese = await dao.getAll(leafType: 'burmese_grape_leaf');
      expect(burmese.length, greaterThanOrEqualTo(1));
      expect(burmese.every((r) => r['leaf_type'] == 'burmese_grape_leaf'), isTrue);
    });

    test('getAll with minConfidence filter', () async {
      final high = await dao.getAll(minConfidence: 0.90);
      expect(high.every((r) => (r['confidence'] as num) >= 0.90), isTrue);
    });

    test('updateNotes', () async {
      final id = await dao.insert({
        'image_path': '/test/photo3.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 9,
        'predicted_class_name': 'Tomato___healthy',
        'confidence': 0.99,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_synced': 0,
      });

      await dao.updateNotes(id, 'Healthy leaf observed');
      final row = await dao.getById(id);
      expect(row!['notes'], 'Healthy leaf observed');
    });

    test('markSynced updates sync fields', () async {
      final id = await dao.insert({
        'image_path': '/test/photo4.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Tomato___Bacterial_spot',
        'confidence': 0.7,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_synced': 0,
      });

      await dao.markSynced(id, 'server-uuid-123');
      final row = await dao.getById(id);
      expect(row!['is_synced'], 1);
      expect(row['server_id'], 'server-uuid-123');
      expect(row['synced_at'], isNotNull);
    });

    test('delete removes prediction', () async {
      final id = await dao.insert({
        'image_path': '/test/delete_me.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Tomato___Bacterial_spot',
        'confidence': 0.5,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'is_synced': 0,
      });

      await dao.delete(id);
      final row = await dao.getById(id);
      expect(row, isNull);
    });

    test('getStatistics returns correct counts', () async {
      final stats = await dao.getStatistics();
      expect(stats['total'], isA<int>());
      expect(stats['synced'], isA<int>());
      expect(stats['unsynced'], isA<int>());
      expect(stats['total'], stats['synced']! + stats['unsynced']!);
    });

    test('getDetailedStatistics returns expected keys', () async {
      final stats = await dao.getDetailedStatistics();
      expect(stats.containsKey('total'), isTrue);
      expect(stats.containsKey('synced'), isTrue);
      expect(stats.containsKey('by_leaf_type'), isTrue);
      expect(stats.containsKey('top_diseases'), isTrue);
      expect(stats.containsKey('daily_scans'), isTrue);
    });
  });

  group('PreferenceDao', () {
    late PreferenceDao dao;

    setUpAll(() async {
      dao = PreferenceDao();
    });

    test('default preferences are seeded', () async {
      final defaultLeaf = await dao.getValue('default_leaf_type');
      expect(defaultLeaf, 'tomato');

      final theme = await dao.getValue('theme');
      expect(theme, 'system');
    });

    test('setValue and getValue', () async {
      await dao.setValue('test_key', 'test_value');
      final result = await dao.getValue('test_key');
      expect(result, 'test_value');
    });

    test('setValue overwrites existing value', () async {
      await dao.setValue('theme', 'dark');
      final result = await dao.getValue('theme');
      expect(result, 'dark');
      // Restore
      await dao.setValue('theme', 'system');
    });

    test('getValue returns null for non-existent key', () async {
      final result = await dao.getValue('nonexistent_key_xyz');
      expect(result, isNull);
    });

    test('getAllPreferences returns a map', () async {
      final all = await dao.getAllPreferences();
      expect(all, isA<Map<String, String>>());
      expect(all.containsKey('default_leaf_type'), isTrue);
    });
  });

  group('ModelDao', () {
    late ModelDao dao;

    setUpAll(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      dao = ModelDao();
    });

    test('seedBundledModels inserts models', () async {
      await dao.seedBundledModels([
        {
          'leaf_type': 'test_model',
          'version': '1.0.0',
          'file_path': 'assets/models/test.tflite',
          'sha256_checksum': 'abc123',
          'num_classes': 3,
          'class_labels': '["A","B","C"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      final model = await dao.getActive('test_model');
      expect(model, isNotNull);
      expect(model!['version'], '1.0.0');
      expect(model['num_classes'], 3);
    });

    test('getActive returns null for non-existent leaf type', () async {
      final model = await dao.getActive('nonexistent_leaf');
      expect(model, isNull);
    });

    test('getAll returns list of models', () async {
      final models = await dao.getAll();
      expect(models, isA<List<Map<String, dynamic>>>());
      expect(models.isNotEmpty, isTrue);
    });

    test('updateVersion modifies model entry', () async {
      await dao.updateVersion('test_model', '1.1.0', 'assets/new.tflite', 'def456');
      final model = await dao.getActive('test_model');
      expect(model!['version'], '1.1.0');
      expect(model['sha256_checksum'], 'def456');
    });
  });

  group('SyncQueue', () {
    late SyncQueue queue;

    setUpAll(() async {
      queue = SyncQueue();
    });

    test('enqueue creates pending item', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 999,
        action: 'create',
        payload: '{"test": true}',
      );
      expect(id, greaterThan(0));

      final pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isTrue);
    });

    test('markCompleted changes status', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1000,
        action: 'create',
      );

      await queue.markCompleted(id);

      final pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isFalse);
    });

    test('incrementRetry increases count', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1001,
        action: 'create',
      );

      await queue.incrementRetry(id);
      await queue.incrementRetry(id);
      await queue.incrementRetry(id);

      // After 3 retries, if max_retries=3, it should no longer appear in pending
      final pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isFalse);
    });

    test('markFailed changes status to failed', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1002,
        action: 'create',
      );

      await queue.markFailed(id);

      final pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isFalse);
    });
  });
}
