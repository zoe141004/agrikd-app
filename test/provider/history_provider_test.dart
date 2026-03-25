import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/history_provider.dart';
import 'package:app/data/database/app_database.dart';

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

      await container.read(historyProvider.notifier).setSortBy('confidence DESC');

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
  });
}
