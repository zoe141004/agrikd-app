import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/database/app_database.dart';
import 'package:app/data/database/dao/prediction_dao.dart';

import '../test_helper.dart';

void main() {
  late PredictionDao dao;

  setUpAll(() async {
    initTestDatabase();
  });

  setUp(() async {
    await resetTestDatabase();
    await AppDatabase.database;
    dao = PredictionDao();
  });

  /// Helper to insert a prediction with sensible defaults.
  Future<int> _insert({
    String leafType = 'tomato',
    String className = 'Tomato___Bacterial_spot',
    double confidence = 0.85,
    String? createdAt,
    String? notes,
    int isSynced = 0,
  }) {
    return dao.insert({
      'image_path': '/test/photo.jpg',
      'leaf_type': leafType,
      'model_version': '1.0.0',
      'predicted_class_index': 0,
      'predicted_class_name': className,
      'confidence': confidence,
      'created_at': createdAt ?? DateTime.now().toUtc().toIso8601String(),
      'notes': notes,
      'is_synced': isSynced,
    });
  }

  group('getAll filter combinations', () {
    test('searchQuery matches predicted_class_name', () async {
      await _insert(className: 'Tomato___Late_blight');
      await _insert(className: 'Tomato___Bacterial_spot');

      final results = await dao.getAll(searchQuery: 'Late_blight');
      expect(results, hasLength(1));
      expect(results.first['predicted_class_name'], 'Tomato___Late_blight');
    });

    test('searchQuery matches notes field', () async {
      await _insert(notes: 'Found in greenhouse');
      await _insert(notes: 'Outdoor sample');

      final results = await dao.getAll(searchQuery: 'greenhouse');
      expect(results, hasLength(1));
      expect(results.first['notes'], 'Found in greenhouse');
    });

    test('date range filter', () async {
      await _insert(createdAt: '2026-01-10T12:00:00.000Z');
      await _insert(createdAt: '2026-02-15T12:00:00.000Z');
      await _insert(createdAt: '2026-03-20T12:00:00.000Z');

      final results = await dao.getAll(
        startDate: '2026-02-01T00:00:00.000Z',
        endDate: '2026-02-28T23:59:59.000Z',
      );
      expect(results, hasLength(1));
    });

    test('combined leafType + minConfidence', () async {
      await _insert(leafType: 'tomato', confidence: 0.95);
      await _insert(leafType: 'tomato', confidence: 0.50);
      await _insert(leafType: 'burmese_grape_leaf', confidence: 0.99);

      final results = await dao.getAll(leafType: 'tomato', minConfidence: 0.80);
      expect(results, hasLength(1));
      expect(results.first['confidence'], 0.95);
    });

    test('combined leafType + searchQuery + minConfidence', () async {
      await _insert(
        leafType: 'tomato',
        className: 'Tomato___Late_blight',
        confidence: 0.92,
      );
      await _insert(
        leafType: 'tomato',
        className: 'Tomato___Late_blight',
        confidence: 0.40,
      );
      await _insert(
        leafType: 'burmese_grape_leaf',
        className: 'Healthy',
        confidence: 0.95,
      );

      final results = await dao.getAll(
        leafType: 'tomato',
        searchQuery: 'Late_blight',
        minConfidence: 0.80,
      );
      expect(results, hasLength(1));
      expect(results.first['confidence'], 0.92);
    });

    test('orderBy confidence DESC', () async {
      await _insert(confidence: 0.50);
      await _insert(confidence: 0.99);
      await _insert(confidence: 0.75);

      final results = await dao.getAll(orderBy: 'confidence DESC');
      final confidences = results
          .map((r) => r['confidence'] as double)
          .toList();
      expect(confidences, orderedEquals([0.99, 0.75, 0.50]));
    });

    test('limit and offset pagination', () async {
      for (var i = 0; i < 10; i++) {
        await _insert(
          createdAt: DateTime.utc(2026, 1, i + 1).toIso8601String(),
        );
      }

      final page1 = await dao.getAll(
        limit: 3,
        offset: 0,
        orderBy: 'created_at ASC',
      );
      final page2 = await dao.getAll(
        limit: 3,
        offset: 3,
        orderBy: 'created_at ASC',
      );

      expect(page1, hasLength(3));
      expect(page2, hasLength(3));
      // No overlap
      final ids1 = page1.map((r) => r['id']).toSet();
      final ids2 = page2.map((r) => r['id']).toSet();
      expect(ids1.intersection(ids2), isEmpty);
    });
  });

  group('getUnsynced', () {
    test('returns only unsynced predictions', () async {
      final syncedId = await _insert(isSynced: 1);
      final unsyncedId = await _insert(isSynced: 0);

      final unsynced = await dao.getUnsynced();
      final ids = unsynced.map((r) => r['id']).toList();
      expect(ids, contains(unsyncedId));
      expect(ids, isNot(contains(syncedId)));
    });
  });

  group('getStatistics', () {
    test('returns correct counts by leaf type', () async {
      await _insert(leafType: 'tomato', isSynced: 1);
      await _insert(leafType: 'tomato', isSynced: 0);
      await _insert(leafType: 'burmese_grape_leaf', isSynced: 1);

      final tomatoStats = await dao.getStatistics(leafType: 'tomato');
      expect(tomatoStats['total'], 2);
      expect(tomatoStats['synced'], 1);
      expect(tomatoStats['unsynced'], 1);
    });
  });

  group('getDetailedStatistics', () {
    test('returns by_leaf_type and top_diseases aggregates', () async {
      await _insert(leafType: 'tomato', className: 'Tomato___Late_blight');
      await _insert(leafType: 'tomato', className: 'Tomato___Late_blight');
      await _insert(leafType: 'burmese_grape_leaf', className: 'Healthy');

      final stats = await dao.getDetailedStatistics();
      expect(stats['total'], 3);

      final byLeaf = stats['by_leaf_type'] as List<Map<String, dynamic>>;
      expect(byLeaf.any((r) => r['leaf_type'] == 'tomato'), isTrue);

      final topDiseases = stats['top_diseases'] as List<Map<String, dynamic>>;
      expect(topDiseases.first['predicted_class_name'], 'Tomato___Late_blight');
      expect(topDiseases.first['count'], 2);
    });
  });
}
