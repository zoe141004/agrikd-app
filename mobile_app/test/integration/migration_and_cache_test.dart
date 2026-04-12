import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/database/app_database.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/data/database/dao/preference_dao.dart';
import 'package:app/data/sync/sync_queue.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
  });

  // ---------------------------------------------------------------------------
  // Group 1: Database Schema Integrity (post-migration)
  // ---------------------------------------------------------------------------
  group('Database Schema Integrity', () {
    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
    });

    test('models table has all expected columns after migration', () async {
      final db = await AppDatabase.database;
      final info = await db.rawQuery("PRAGMA table_info(models)");
      final columns = info.map((r) => r['name'] as String).toSet();

      expect(
        columns,
        containsAll([
          'id',
          'leaf_type',
          'version',
          'file_path',
          'sha256_checksum',
          'num_classes',
          'class_labels',
          'accuracy_top1',
          'is_bundled',
          'is_active',
          'role',
          'is_selected',
          'updated_at',
        ]),
      );
    });

    test('models table enforces UNIQUE(leaf_type, version)', () async {
      final modelDao = ModelDao();
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'assets/models/tomato.tflite',
          'sha256_checksum': 'abc123',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Inserting same leaf_type+version should replace (ConflictAlgorithm.replace)
      final id = await modelDao.insert({
        'leaf_type': 'tomato',
        'version': '1.0.0',
        'file_path': 'assets/models/tomato_v2.tflite',
        'sha256_checksum': 'def456',
        'num_classes': 10,
        'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
        'is_bundled': 1,
        'is_active': 1,
        'role': 'active',
        'is_selected': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      expect(id, greaterThan(0));
      final all = await modelDao.getByLeafType('tomato');
      expect(all.length, 1);
      expect(all.first['sha256_checksum'], 'def456');
    });

    test('models table role CHECK constraint accepts valid roles', () async {
      final db = await AppDatabase.database;
      for (final role in ['active', 'fallback', 'archived']) {
        await db.insert('models', {
          'leaf_type': 'test_$role',
          'version': '1.0.0',
          'file_path': 'test.tflite',
          'sha256_checksum': 'hash',
          'num_classes': 5,
          'class_labels': '["A","B","C","D","E"]',
          'is_bundled': 1,
          'is_active': 1,
          'role': role,
          'is_selected': 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final all = await db.query('models');
      expect(all.length, 3);
    });

    test('predictions table has all expected columns', () async {
      final db = await AppDatabase.database;
      final info = await db.rawQuery("PRAGMA table_info(predictions)");
      final columns = info.map((r) => r['name'] as String).toSet();

      expect(
        columns,
        containsAll([
          'id',
          'image_path',
          'leaf_type',
          'model_version',
          'predicted_class_index',
          'predicted_class_name',
          'confidence',
          'all_confidences',
          'inference_time_ms',
          'notes',
          'created_at',
          'is_synced',
          'synced_at',
          'server_id',
        ]),
      );
    });

    test('sync_queue table has all expected columns', () async {
      final db = await AppDatabase.database;
      final info = await db.rawQuery("PRAGMA table_info(sync_queue)");
      final columns = info.map((r) => r['name'] as String).toSet();

      expect(
        columns,
        containsAll([
          'id',
          'entity_type',
          'entity_id',
          'action',
          'payload',
          'retry_count',
          'max_retries',
          'status',
          'created_at',
          'completed_at',
        ]),
      );
    });

    test('user_preferences table is seeded with defaults', () async {
      final prefDao = PreferenceDao();
      final defaultLeaf = await prefDao.getValue('default_leaf_type');
      expect(defaultLeaf, 'tomato');

      final autoSync = await prefDao.getValue('auto_sync');
      expect(autoSync, 'true');

      final theme = await prefDao.getValue('theme');
      expect(theme, 'system');
    });

    test('indexes exist on predictions table', () async {
      final db = await AppDatabase.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='predictions'",
      );
      final names = indexes.map((r) => r['name'] as String).toSet();
      expect(names, contains('idx_predictions_leaf_type'));
      expect(names, contains('idx_predictions_created_at'));
      expect(names, contains('idx_predictions_is_synced'));
    });
  });

  // ---------------------------------------------------------------------------
  // Group 2: Cross-leaf type isolation
  // ---------------------------------------------------------------------------
  group('Cross-Leaf Type Isolation', () {
    late ModelDao modelDao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      modelDao = ModelDao();
    });

    test('models for different leaf types are independent', () async {
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'assets/models/tomato.tflite',
          'sha256_checksum': 'hash_tomato',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        {
          'leaf_type': 'burmese_grape_leaf',
          'version': '1.0.0',
          'file_path': 'assets/models/burmese.tflite',
          'sha256_checksum': 'hash_burmese',
          'num_classes': 5,
          'class_labels': '["A","B","C","D","E"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Promote OTA for tomato only
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/models/tomato_1.1.0.tflite',
        checksum: 'ota_hash',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Tomato should have 2 models
      final tomatoModels = await modelDao.getByLeafType('tomato');
      expect(tomatoModels.length, 2);

      // Burmese should still have 1 model, unaffected
      final burmeseModels = await modelDao.getByLeafType('burmese_grape_leaf');
      expect(burmeseModels.length, 1);
      expect(burmeseModels.first['version'], '1.0.0');
    });

    test('selectVersion only affects target leaf type', () async {
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'assets/models/tomato.tflite',
          'sha256_checksum': 'hash_tomato',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        {
          'leaf_type': 'burmese_grape_leaf',
          'version': '1.0.0',
          'file_path': 'assets/models/burmese.tflite',
          'sha256_checksum': 'hash_burmese',
          'num_classes': 5,
          'class_labels': '["A","B","C","D","E"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Add OTA to tomato
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/models/tomato_1.1.0.tflite',
        checksum: 'ota_hash',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Switch tomato selection to 1.0.0
      await modelDao.selectVersion('tomato', '1.0.0');

      final tomatoSelected = await modelDao.getSelected('tomato');
      expect(tomatoSelected!['version'], '1.0.0');

      // Burmese should still have its own selection
      final burmeseSelected = await modelDao.getSelected('burmese_grape_leaf');
      expect(burmeseSelected, isNotNull);
      expect(burmeseSelected!['version'], '1.0.0');
      expect(burmeseSelected['leaf_type'], 'burmese_grape_leaf');
    });
  });

  // ---------------------------------------------------------------------------
  // Group 3: ModelDao edge cases
  // ---------------------------------------------------------------------------
  group('ModelDao Edge Cases', () {
    late ModelDao modelDao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      modelDao = ModelDao();
    });

    test('getSelected returns null for empty database', () async {
      final result = await modelDao.getSelected('nonexistent');
      expect(result, isNull);
    });

    test('getActiveVersions returns empty for no models', () async {
      final result = await modelDao.getActiveVersions('nonexistent');
      expect(result, isEmpty);
    });

    test('selectVersion is a no-op for nonexistent version', () async {
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'test.tflite',
          'sha256_checksum': 'hash',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Try selecting a version that doesn't exist
      await modelDao.selectVersion('tomato', '9.9.9');

      // Should not deselect the existing model
      final selected = await modelDao.getSelected('tomato');
      expect(selected, isNotNull);
      expect(selected!['version'], '1.0.0');
    });

    test('promoteNewVersion handles concurrent rapid promotions', () async {
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'test.tflite',
          'sha256_checksum': 'hash',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Promote 3 versions rapidly
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/1.1.0.tflite',
        checksum: 'h1',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.2.0',
        filePath: '/data/1.2.0.tflite',
        checksum: 'h2',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.3.0',
        filePath: '/data/1.3.0.tflite',
        checksum: 'h3',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Should only have 2 active (max rule)
      final actives = await modelDao.getActiveVersions('tomato');
      expect(actives.length, 2);

      // Selected should be the latest
      final selected = await modelDao.getSelected('tomato');
      expect(selected!['version'], '1.3.0');

      // Only v1.2.0 and v1.3.0 should remain
      final all = await modelDao.getByLeafType('tomato');
      final versions = all.map((m) => m['version']).toSet();
      expect(versions, containsAll(['1.2.0', '1.3.0']));
      expect(versions.contains('1.0.0'), isFalse);
      expect(versions.contains('1.1.0'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Group 4: Sync Queue stress and edge cases
  // ---------------------------------------------------------------------------
  group('Sync Queue Stress', () {
    late SyncQueue queue;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      queue = SyncQueue();
    });

    test('handles 100+ enqueue items correctly', () async {
      const count = 100;
      final ids = <int>[];
      for (int i = 0; i < count; i++) {
        final id = await queue.enqueue(
          entityType: 'prediction',
          entityId: 1000 + i,
          action: 'create',
          payload: '{"i": $i}',
        );
        ids.add(id);
      }

      // All 100 should be unique
      expect(ids.toSet().length, count);

      // All should be pending
      final pending = await queue.getPending(limit: 200);
      expect(pending.length, count);
    });

    test('cleanup preserves pending while removing failed', () async {
      final id1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 1,
        action: 'create',
      );
      final id2 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 2,
        action: 'create',
      );

      // Mark id2 as failed
      await queue.markFailed(id2);

      // Cleanup
      await queue.cleanup();

      // id1 should still be pending
      final pending = await queue.getPending();
      expect(pending.length, 1);
      expect(pending.first['id'], id1);
    });

    test('markCompleted then re-enqueue same entity works', () async {
      final id1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 500,
        action: 'create',
      );
      await queue.markCompleted(id1);

      // Re-enqueue same entity (e.g., update after create)
      final id2 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 500,
        action: 'update',
        payload: '{"updated": true}',
      );

      expect(id2, isNot(equals(id1)));
      final pending = await queue.getPending();
      expect(pending.length, 1);
      expect(pending.first['action'], 'update');
    });
  });

  // ---------------------------------------------------------------------------
  // Group 5: PredictionDao advanced queries
  // ---------------------------------------------------------------------------
  group('PredictionDao Advanced', () {
    late PredictionDao predictionDao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      predictionDao = PredictionDao();
    });

    test('insert prediction with all fields and retrieve', () async {
      final id = await predictionDao.insert({
        'image_path': '/test/image.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.2.0',
        'predicted_class_index': 5,
        'predicted_class_name': 'Spider_mites',
        'confidence': 0.95,
        'all_confidences': '[0.01,0.01,0.01,0.01,0.01,0.95,0.0,0.0,0.0,0.0]',
        'inference_time_ms': 35.2,
        'notes': 'Test note',
      });

      final row = await predictionDao.getById(id);
      expect(row, isNotNull);
      expect(row!['leaf_type'], 'tomato');
      expect(row['model_version'], '1.2.0');
      expect(row['predicted_class_name'], 'Spider_mites');
      expect(row['confidence'], 0.95);
      expect(row['inference_time_ms'], 35.2);
      expect(row['notes'], 'Test note');
      expect(row['is_synced'], 0);
    });

    test('markSynced updates sync fields correctly', () async {
      final id = await predictionDao.insert({
        'image_path': '/test/img.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Bacterial_spot',
        'confidence': 0.8,
      });

      await predictionDao.markSynced(id, 'srv_abc123');

      final row = await predictionDao.getById(id);
      expect(row!['is_synced'], 1);
      expect(row['server_id'], 'srv_abc123');
      expect(row['synced_at'], isNotNull);
    });

    test('delete removes prediction and it cannot be retrieved', () async {
      final id = await predictionDao.insert({
        'image_path': '/test/del.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Test',
        'confidence': 0.5,
      });

      await predictionDao.delete(id);
      final row = await predictionDao.getById(id);
      expect(row, isNull);
    });

    test('getStatistics counts by leaf type', () async {
      // Insert 3 tomato + 2 burmese predictions
      for (int i = 0; i < 3; i++) {
        await predictionDao.insert({
          'image_path': '/test/tomato_$i.jpg',
          'leaf_type': 'tomato',
          'model_version': '1.0.0',
          'predicted_class_index': i,
          'predicted_class_name': 'Class_$i',
          'confidence': 0.9,
        });
      }
      for (int i = 0; i < 2; i++) {
        await predictionDao.insert({
          'image_path': '/test/burmese_$i.jpg',
          'leaf_type': 'burmese_grape_leaf',
          'model_version': '1.0.0',
          'predicted_class_index': i,
          'predicted_class_name': 'Class_$i',
          'confidence': 0.85,
        });
      }

      final stats = await predictionDao.getStatistics();
      expect(stats['total'], 5);
    });
  });
}
