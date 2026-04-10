import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/history_provider.dart';
import 'package:app/data/database/app_database.dart';
import 'package:app/data/database/dao/prediction_dao.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
    await resetTestDatabase();
    await AppDatabase.database;
  });

  group('HistoryNotifier', () {
    test('initial state is empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(historyProvider);
      expect(state.predictions, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.hasMore, isTrue);
      expect(state.filterLeafType, isNull);
      expect(state.minConfidence, isNull);
    });

    test('loadInitial sets isLoading and loads data', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).loadInitial();

      final state = container.read(historyProvider);
      expect(state.isLoading, isFalse);
      // Predictions may be empty if DB is fresh
      expect(state.predictions, isA<List>());
    });

    test('setFilter updates filterLeafType and reloads', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).setFilter('tomato');

      final state = container.read(historyProvider);
      expect(state.filterLeafType, 'tomato');
    });

    test('setMinConfidence updates minConfidence', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).setMinConfidence(0.8);

      final state = container.read(historyProvider);
      expect(state.minConfidence, 0.8);
    });

    test('setSortBy updates sort order', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(historyProvider.notifier)
          .setSortBy('confidence DESC');

      final state = container.read(historyProvider);
      expect(state.sortBy, 'confidence DESC');
    });

    test('setDateRange updates dates', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final start = DateTime(2026, 1, 1);
      final end = DateTime(2026, 3, 23);
      await container.read(historyProvider.notifier).setDateRange(start, end);

      final state = container.read(historyProvider);
      expect(state.filterStartDate, start);
      expect(state.filterEndDate, end);
    });

    test('setMinConfidence null clears filter', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).setMinConfidence(0.9);
      expect(container.read(historyProvider).minConfidence, 0.9);

      await container.read(historyProvider.notifier).setMinConfidence(null);
      expect(container.read(historyProvider).minConfidence, isNull);
    });
  });

  group('HistoryState', () {
    test('copyWith preserves values when not overridden', () {
      final state = HistoryState(
        filterLeafType: 'tomato',
        sortBy: 'confidence DESC',
        minConfidence: 0.8,
      );

      final copied = state.copyWith(isLoading: true);
      expect(copied.filterLeafType, 'tomato');
      expect(copied.sortBy, 'confidence DESC');
      expect(copied.minConfidence, 0.8);
      expect(copied.isLoading, isTrue);
    });

    test('copyWith clearConfidenceFilter sets minConfidence to null', () {
      final state = HistoryState(minConfidence: 0.9);
      final cleared = state.copyWith(clearConfidenceFilter: true);
      expect(cleared.minConfidence, isNull);
    });

    test('copyWith clearLeafFilter sets filterLeafType to null', () {
      final state = HistoryState(filterLeafType: 'tomato');
      final cleared = state.copyWith(clearLeafFilter: true);
      expect(cleared.filterLeafType, isNull);
    });

    test('copyWith clearDateFilter clears both dates', () {
      final state = HistoryState(
        filterStartDate: DateTime(2026, 1, 1),
        filterEndDate: DateTime(2026, 3, 1),
      );
      final cleared = state.copyWith(clearDateFilter: true);
      expect(cleared.filterStartDate, isNull);
      expect(cleared.filterEndDate, isNull);
    });

    test('copyWith clearSearch sets searchQuery to null', () {
      final state = HistoryState(searchQuery: 'blight');
      final cleared = state.copyWith(clearSearch: true);
      expect(cleared.searchQuery, isNull);
    });
  });

  group('HistoryNotifier with data', () {
    late PredictionDao dao;

    setUp(() async {
      await resetTestDatabase();
      await AppDatabase.database;
      dao = PredictionDao();
    });

    Future<void> _seedPredictions(int count) async {
      for (var i = 0; i < count; i++) {
        await dao.insert({
          'image_path': '/test/photo_$i.jpg',
          'leaf_type': 'tomato',
          'model_version': '1.0.0',
          'predicted_class_index': 0,
          'predicted_class_name': 'Tomato___Bacterial_spot',
          'confidence': 0.80 + (i % 20) * 0.01,
          'created_at': DateTime.utc(2026, 1, 1, 0, 0, i).toIso8601String(),
          'is_synced': 0,
        });
      }
    }

    test('loadInitial loads first page of data', () async {
      await _seedPredictions(25);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).loadInitial();
      final state = container.read(historyProvider);

      expect(state.predictions.length, 20); // _pageSize = 20
      expect(state.hasMore, isTrue);
      expect(state.isLoading, isFalse);
    });

    test('loadMore appends next page', () async {
      await _seedPredictions(50);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).loadInitial();
      expect(container.read(historyProvider).predictions.length, 20);

      await container.read(historyProvider.notifier).loadMore();
      expect(container.read(historyProvider).predictions.length, 40);
    });

    test('deletePrediction removes from state', () async {
      await _seedPredictions(5);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(historyProvider.notifier).loadInitial();
      final before = container.read(historyProvider).predictions;
      expect(before.length, 5);

      final idToDelete = before.first.id!;
      await container
          .read(historyProvider.notifier)
          .deletePrediction(idToDelete);

      final after = container.read(historyProvider).predictions;
      expect(after.length, 4);
      expect(after.any((p) => p.id == idToDelete), isFalse);
    });

    test('setSearchQuery filters results', () async {
      // Insert predictions with different class names
      await dao.insert({
        'image_path': '/test/p1.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 3,
        'predicted_class_name': 'Tomato___Late_blight',
        'confidence': 0.90,
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'is_synced': 0,
      });
      await dao.insert({
        'image_path': '/test/p2.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Tomato___Bacterial_spot',
        'confidence': 0.85,
        'created_at': DateTime.utc(2026, 1, 2).toIso8601String(),
        'is_synced': 0,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(historyProvider.notifier)
          .setSearchQuery('Late_blight');
      final state = container.read(historyProvider);
      expect(state.predictions.length, 1);
      expect(
        state.predictions.first.predictedClassName,
        'Tomato___Late_blight',
      );
    });
  });
}
