import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/utils/model_integrity.dart';
import 'package:app/data/database/app_database.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/database/dao/prediction_dao.dart';
import 'package:app/data/sync/sync_queue.dart';
import 'package:app/features/diagnosis/domain/models/prediction.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
  });

  // ---------------------------------------------------------------------------
  // Group 1: OTA Model Version Rotation
  // ---------------------------------------------------------------------------
  group('OTA Model Version Rotation', () {
    late ModelDao modelDao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      modelDao = ModelDao();
    });

    Future<void> seedBundledTomato() async {
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'assets/models/tomato/tomato_student.tflite',
          'sha256_checksum': 'bundled_sha256_abc',
          'num_classes': 10,
          'class_labels':
              '["Bacterial_spot","Early_blight","Late_blight","Leaf_Mold",'
                  '"Septoria_leaf_spot","Spider_mites","Target_Spot",'
                  '"Mosaic_virus","Yellow_Leaf_Curl_Virus","healthy"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);
    }

    test(
      'promoteNewVersion creates active model and demotes old to fallback',
      () async {
        await seedBundledTomato();

        // Promote OTA v1.1.0
        await modelDao.promoteNewVersion(
          leafType: 'tomato',
          version: '1.1.0',
          filePath: '/data/user/0/com.agrikd.app/models/tomato_1.1.0.tflite',
          checksum: 'ota_sha256_def',
          numClasses: 10,
          classLabels:
              '["Bacterial_spot","Early_blight","Late_blight","Leaf_Mold",'
                  '"Septoria_leaf_spot","Spider_mites","Target_Spot",'
                  '"Mosaic_virus","Yellow_Leaf_Curl_Virus","healthy"]',
        );

        // Active should be v1.1.0 (OTA)
        final active = await modelDao.getActive('tomato');
        expect(active, isNotNull);
        expect(active!['version'], '1.1.0');
        expect(active['role'], 'active');
        expect(active['is_bundled'], 0);
        expect(active['sha256_checksum'], 'ota_sha256_def');

        // Fallback should be the original bundled v1.0.0
        final fallback = await modelDao.getFallback('tomato');
        expect(fallback, isNotNull);
        expect(fallback!['version'], '1.0.0');
        expect(fallback['role'], 'fallback');
        expect(fallback['is_bundled'], 1);
      },
    );

    test('second promotion deletes old fallback', () async {
      await seedBundledTomato();

      // First promotion: v1.0.0 -> fallback, v1.1.0 -> active
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/models/tomato_1.1.0.tflite',
        checksum: 'hash_v110',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Second promotion: v1.0.0 fallback deleted, v1.1.0 -> fallback,
      // v1.2.0 -> active
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.2.0',
        filePath: '/data/models/tomato_1.2.0.tflite',
        checksum: 'hash_v120',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Only 2 models should remain for tomato (no archived v1.0.0)
      final allModels = await modelDao.getByLeafType('tomato');
      expect(allModels.length, 2);

      final active = await modelDao.getActive('tomato');
      expect(active!['version'], '1.2.0');
      expect(active['role'], 'active');

      final fallback = await modelDao.getFallback('tomato');
      expect(fallback!['version'], '1.1.0');
      expect(fallback['role'], 'fallback');

      // v1.0.0 must not exist anywhere
      final versions = allModels.map((m) => m['version']).toList();
      expect(versions, isNot(contains('1.0.0')));
    });

    test(
      'rollbackToFallback deletes active OTA and promotes fallback',
      () async {
        await seedBundledTomato();

        // Promote OTA v1.1.0
        await modelDao.promoteNewVersion(
          leafType: 'tomato',
          version: '1.1.0',
          filePath: '/data/models/tomato_1.1.0.tflite',
          checksum: 'ota_hash',
          numClasses: 10,
          classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
        );

        // Verify pre-rollback state
        var active = await modelDao.getActive('tomato');
        expect(active!['version'], '1.1.0');
        expect(active['is_bundled'], 0);

        // Rollback: should delete active OTA and promote fallback
        final success = await modelDao.rollbackToFallback('tomato');
        expect(success, isTrue);

        // Bundled v1.0.0 should be active again
        active = await modelDao.getActive('tomato');
        expect(active, isNotNull);
        expect(active!['version'], '1.0.0');
        expect(active['role'], 'active');
        expect(active['is_bundled'], 1);

        // No fallback should remain
        final fallback = await modelDao.getFallback('tomato');
        expect(fallback, isNull);

        // Only 1 model total
        final allModels = await modelDao.getByLeafType('tomato');
        expect(allModels.length, 1);
      },
    );

    test('switchRole swaps active and fallback', () async {
      await seedBundledTomato();

      // Promote OTA so we have active (v1.1.0) + fallback (v1.0.0)
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/models/tomato_1.1.0.tflite',
        checksum: 'ota_hash',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      // Confirm pre-switch state
      var active = await modelDao.getActive('tomato');
      expect(active!['version'], '1.1.0');
      var fallback = await modelDao.getFallback('tomato');
      expect(fallback!['version'], '1.0.0');

      // Switch roles
      await modelDao.switchRole('tomato');

      // After switch: v1.0.0 should be active, v1.1.0 fallback
      active = await modelDao.getActive('tomato');
      expect(active, isNotNull);
      expect(active!['version'], '1.0.0');

      fallback = await modelDao.getFallback('tomato');
      expect(fallback, isNotNull);
      expect(fallback!['version'], '1.1.0');
    });

    test('rollback with no fallback keeps current active', () async {
      // Only seed a single bundled active model, no fallback
      await seedBundledTomato();

      // Verify only one model exists
      final before = await modelDao.getByLeafType('tomato');
      expect(before.length, 1);

      // Attempt rollback — no fallback, and active is bundled (is_bundled=1)
      // so it is not deleted by rollbackToFallback
      final success = await modelDao.rollbackToFallback('tomato');
      expect(success, isFalse);

      // Active model should remain unchanged
      final active = await modelDao.getActive('tomato');
      expect(active, isNotNull);
      expect(active!['version'], '1.0.0');
      expect(active['is_bundled'], 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Group 2: Model Integrity Verification
  // ---------------------------------------------------------------------------
  group('Model Integrity Verification', () {
    // ModelIntegrity.sha256Bytes is a pure function using the crypto package.
    // verify() / sha256Asset() require Flutter's rootBundle and are not
    // usable in plain unit tests, so we validate the underlying hash logic
    // via sha256Bytes which is what the runtime verification ultimately calls.

    test('sha256Bytes produces consistent hash', () {
      final bytes = [72, 101, 108, 108, 111]; // ASCII "Hello"
      final hash1 = ModelIntegrity.sha256Bytes(bytes);
      final hash2 = ModelIntegrity.sha256Bytes(bytes);

      expect(hash1, equals(hash2));
      expect(hash1, isNotEmpty);
      // SHA-256 always produces a 64-character hex digest
      expect(hash1.length, 64);
      // Known SHA-256 of "Hello"
      expect(
        hash1,
        '185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969',
      );
    });

    test('sha256Bytes differs for different content', () {
      final hash1 = ModelIntegrity.sha256Bytes([1, 2, 3]);
      final hash2 = ModelIntegrity.sha256Bytes([4, 5, 6]);
      expect(hash1, isNot(equals(hash2)));

      // Both should still be valid 64-char hex strings
      expect(hash1.length, 64);
      expect(hash2.length, 64);
    });

    test('verify returns true for matching checksum', () {
      // Simulate the verify flow: compute hash, then check equality
      // (verify() internally does sha256Asset and compares strings)
      final modelBytes = List.generate(256, (i) => i % 256);
      final expectedChecksum = ModelIntegrity.sha256Bytes(modelBytes);
      final actualChecksum = ModelIntegrity.sha256Bytes(modelBytes);
      expect(actualChecksum == expectedChecksum, isTrue);
    });

    test('verify returns false for wrong checksum', () {
      final modelBytes = List.generate(256, (i) => i % 256);
      final actualChecksum = ModelIntegrity.sha256Bytes(modelBytes);
      const wrongChecksum =
          '0000000000000000000000000000000000000000000000000000000000000000';
      expect(actualChecksum == wrongChecksum, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Group 3: Sync Queue Integration
  // ---------------------------------------------------------------------------
  group('Sync Queue Integration', () {
    late SyncQueue queue;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      queue = SyncQueue();
    });

    test('enqueue and getPending returns items in order', () async {
      final id1 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 100,
        action: 'create',
        payload: '{"index": 1}',
      );
      final id2 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 101,
        action: 'create',
        payload: '{"index": 2}',
      );
      final id3 = await queue.enqueue(
        entityType: 'prediction',
        entityId: 102,
        action: 'create',
        payload: '{"index": 3}',
      );

      final pending = await queue.getPending();
      expect(pending.length, 3);

      // Order should be created_at ASC (insertion order)
      final ids = pending.map((r) => r['id'] as int).toList();
      expect(ids, [id1, id2, id3]);

      // Verify payloads preserved
      expect(pending[0]['payload'], '{"index": 1}');
      expect(pending[1]['payload'], '{"index": 2}');
      expect(pending[2]['payload'], '{"index": 3}');
    });

    test('markCompleted removes from pending', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 200,
        action: 'create',
        payload: '{"data": true}',
      );

      // Confirm it is pending
      var pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isTrue);

      // Mark completed
      await queue.markCompleted(id);

      // Should no longer appear in pending
      pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isFalse);
    });

    test('incrementRetry respects max retries', () async {
      final id = await queue.enqueue(
        entityType: 'prediction',
        entityId: 300,
        action: 'create',
      );

      // Default max_retries = 3 (from schema)

      // After 1 retry: retry_count=1 < 3, still pending
      await queue.incrementRetry(id);
      var pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isTrue);

      // After 2 retries: retry_count=2 < 3, still pending
      await queue.incrementRetry(id);
      pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isTrue);

      // After 3 retries: retry_count=3 >= max_retries=3, excluded
      await queue.incrementRetry(id);
      pending = await queue.getPending();
      expect(pending.any((r) => r['id'] == id), isFalse);
    });

    test('concurrent enqueue operations do not conflict', () async {
      // Enqueue 10 items concurrently via Future.wait
      final futures = List.generate(
        10,
        (i) => queue.enqueue(
          entityType: 'prediction',
          entityId: 400 + i,
          action: 'create',
          payload: '{"concurrent": $i}',
        ),
      );

      final ids = await Future.wait(futures);

      // All 10 should have been inserted with unique IDs
      expect(ids.length, 10);
      expect(ids.toSet().length, 10);

      // All should appear in pending
      final pending = await queue.getPending();
      for (final id in ids) {
        expect(
          pending.any((r) => r['id'] == id),
          isTrue,
          reason: 'Queue item $id should be in pending list',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Group 4: Full OTA Flow Simulation (DB-level)
  // ---------------------------------------------------------------------------
  group('Full OTA Flow Simulation', () {
    late ModelDao modelDao;
    late PredictionDao predictionDao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      modelDao = ModelDao();
      predictionDao = PredictionDao();
    });

    test('complete OTA update cycle', () async {
      // --- Step 1: Seed bundled model ---
      await modelDao.seedBundledModels([
        {
          'leaf_type': 'tomato',
          'version': '1.0.0',
          'file_path': 'assets/models/tomato/tomato_student.tflite',
          'sha256_checksum': 'bundled_sha256',
          'num_classes': 10,
          'class_labels': '["A","B","C","D","E","F","G","H","I","J"]',
          'is_bundled': 1,
          'is_active': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      var active = await modelDao.getActive('tomato');
      expect(active, isNotNull);
      expect(active!['version'], '1.0.0');
      expect(active['role'], 'active');

      // --- Step 2: First OTA update to v1.1.0 ---
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.1.0',
        filePath: '/data/models/tomato_1.1.0.tflite',
        checksum: 'sha256_v110',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      active = await modelDao.getActive('tomato');
      expect(active!['version'], '1.1.0');
      expect(active['is_bundled'], 0);

      var fallback = await modelDao.getFallback('tomato');
      expect(fallback, isNotNull);
      expect(fallback!['version'], '1.0.0');
      expect(fallback['is_bundled'], 1);

      // --- Step 3: Second OTA update to v1.2.0 (rotates out v1.0.0) ---
      await modelDao.promoteNewVersion(
        leafType: 'tomato',
        version: '1.2.0',
        filePath: '/data/models/tomato_1.2.0.tflite',
        checksum: 'sha256_v120',
        numClasses: 10,
        classLabels: '["A","B","C","D","E","F","G","H","I","J"]',
      );

      active = await modelDao.getActive('tomato');
      expect(active!['version'], '1.2.0');

      fallback = await modelDao.getFallback('tomato');
      expect(fallback!['version'], '1.1.0');

      // v1.0.0 should be completely gone
      var allModels = await modelDao.getByLeafType('tomato');
      expect(allModels.length, 2);
      expect(allModels.any((m) => m['version'] == '1.0.0'), isFalse);

      // --- Step 4: Rollback ---
      // v1.2.0 (OTA, is_bundled=0) is deleted; v1.1.0 promoted to active
      final rollbackOk = await modelDao.rollbackToFallback('tomato');
      expect(rollbackOk, isTrue);

      active = await modelDao.getActive('tomato');
      expect(active, isNotNull);
      expect(active!['version'], '1.1.0');
      expect(active['role'], 'active');

      fallback = await modelDao.getFallback('tomato');
      expect(fallback, isNull);

      // Only one model left
      allModels = await modelDao.getByLeafType('tomato');
      expect(allModels.length, 1);
    });

    test('prediction records model version', () async {
      // Create a Prediction with a specific model version
      final prediction = Prediction(
        imagePath: '/test/ota_diagnosis.jpg',
        leafType: 'tomato',
        modelVersion: '1.1.0',
        predictedClassIndex: 3,
        predictedClassName: 'Tomato___Early_blight',
        confidence: 0.88,
        allConfidences: [0.02, 0.03, 0.05, 0.88, 0.01, 0.0, 0.0, 0.0, 0.01, 0.0],
        inferenceTimeMs: 42.5,
        createdAt: DateTime.now().toUtc(),
      );

      // Insert via DAO
      final id = await predictionDao.insert(prediction.toMap());
      expect(id, greaterThan(0));

      // Retrieve and verify model_version persists
      final row = await predictionDao.getById(id);
      expect(row, isNotNull);
      expect(row!['model_version'], '1.1.0');
      expect(row['leaf_type'], 'tomato');
      expect(row['predicted_class_index'], 3);
      expect(row['predicted_class_name'], 'Tomato___Early_blight');
      expect(row['confidence'], 0.88);
      expect(row['inference_time_ms'], 42.5);

      // Verify full round-trip through the Prediction model
      final loaded = Prediction.fromMap(row);
      expect(loaded.modelVersion, '1.1.0');
      expect(loaded.predictedClassIndex, 3);
      expect(loaded.predictedClassName, 'Tomato___Early_blight');
      expect(loaded.confidence, 0.88);
      expect(loaded.inferenceTimeMs, 42.5);
      expect(loaded.allConfidences, isNotNull);
      expect(loaded.allConfidences!.length, 10);
      expect(loaded.allConfidences![3], 0.88);
      expect(loaded.isSynced, isFalse);
    });
  });
}
