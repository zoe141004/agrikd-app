import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/diagnosis/domain/models/prediction.dart';
import 'database_provider.dart';

class HistoryState {
  final List<Prediction> predictions;
  final bool isLoading;
  final bool hasMore;
  final String? filterLeafType;
  final DateTime? filterStartDate;
  final DateTime? filterEndDate;
  final double? minConfidence;
  final String? searchQuery;
  final String sortBy; // 'created_at DESC' or 'confidence DESC'

  const HistoryState({
    this.predictions = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.filterLeafType,
    this.filterStartDate,
    this.filterEndDate,
    this.minConfidence,
    this.searchQuery,
    this.sortBy = 'created_at DESC',
  });

  HistoryState copyWith({
    List<Prediction>? predictions,
    bool? isLoading,
    bool? hasMore,
    String? filterLeafType,
    DateTime? filterStartDate,
    DateTime? filterEndDate,
    double? minConfidence,
    String? searchQuery,
    String? sortBy,
    bool clearLeafFilter = false,
    bool clearDateFilter = false,
    bool clearConfidenceFilter = false,
    bool clearSearch = false,
  }) {
    return HistoryState(
      predictions: predictions ?? this.predictions,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      filterLeafType: clearLeafFilter
          ? null
          : (filterLeafType ?? this.filterLeafType),
      filterStartDate: clearDateFilter
          ? null
          : (filterStartDate ?? this.filterStartDate),
      filterEndDate: clearDateFilter
          ? null
          : (filterEndDate ?? this.filterEndDate),
      minConfidence: clearConfidenceFilter
          ? null
          : (minConfidence ?? this.minConfidence),
      searchQuery: clearSearch ? null : (searchQuery ?? this.searchQuery),
      sortBy: sortBy ?? this.sortBy,
    );
  }
}

class HistoryNotifier extends StateNotifier<HistoryState> {
  final Ref _ref;
  static const int _pageSize = 20;
  bool _isLoadingMore = false;

  HistoryNotifier(this._ref) : super(const HistoryState());

  Future<void> loadInitial() async {
    state = state.copyWith(isLoading: true, predictions: []);
    await _loadPage(0);
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || state.isLoading || !state.hasMore) return;
    _isLoadingMore = true;
    state = state.copyWith(isLoading: true);
    await _loadPage(state.predictions.length);
    _isLoadingMore = false;
  }

  Future<void> _loadPage(int offset) async {
    try {
      final dao = _ref.read(predictionDaoProvider);
      final rows = await dao.getAll(
        limit: _pageSize,
        offset: offset,
        leafType: state.filterLeafType,
        startDate: state.filterStartDate?.toUtc().toIso8601String(),
        endDate: state.filterEndDate
            ?.add(const Duration(days: 1))
            .toUtc()
            .toIso8601String(),
        minConfidence: state.minConfidence,
        searchQuery: state.searchQuery,
        orderBy: state.sortBy,
      );
      final newPredictions = rows.map((r) => Prediction.fromMap(r)).toList();

      state = state.copyWith(
        predictions: [...state.predictions, ...newPredictions],
        isLoading: false,
        hasMore: newPredictions.length >= _pageSize,
      );
    } catch (e) {
      debugPrint('[HistoryProvider] Failed to load page: $e');
      state = state.copyWith(isLoading: false, hasMore: false);
    }
  }

  Future<void> setFilter(String? leafType) async {
    state = state.copyWith(
      filterLeafType: leafType,
      clearLeafFilter: leafType == null,
      predictions: [],
      hasMore: true,
    );
    await loadInitial();
  }

  Future<void> setDateRange(DateTime? start, DateTime? end) async {
    state = state.copyWith(
      filterStartDate: start,
      filterEndDate: end,
      clearDateFilter: start == null,
      predictions: [],
      hasMore: true,
    );
    await loadInitial();
  }

  Future<void> setSortBy(String sortBy) async {
    state = state.copyWith(sortBy: sortBy, predictions: [], hasMore: true);
    await loadInitial();
  }

  Future<void> setMinConfidence(double? minConfidence) async {
    state = state.copyWith(
      minConfidence: minConfidence,
      clearConfidenceFilter: minConfidence == null,
      predictions: [],
      hasMore: true,
    );
    await loadInitial();
  }

  Future<void> setSearchQuery(String? query) async {
    final q = (query?.isEmpty == true) ? null : query;
    state = state.copyWith(
      searchQuery: q,
      clearSearch: q == null,
      predictions: [],
      hasMore: true,
    );
    await loadInitial();
  }

  Future<void> refresh() async {
    await loadInitial();
  }

  Future<void> deletePrediction(int id) async {
    final dao = _ref.read(predictionDaoProvider);
    await dao.delete(id);
    state = state.copyWith(
      predictions: state.predictions.where((p) => p.id != id).toList(),
    );
  }
}

final historyProvider = StateNotifierProvider<HistoryNotifier, HistoryState>((
  ref,
) {
  return HistoryNotifier(ref);
});
