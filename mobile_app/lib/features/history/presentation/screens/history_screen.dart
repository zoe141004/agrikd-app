import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/history_provider.dart';
import 'detail_screen.dart';
import 'stats_screen.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(historyProvider.notifier).loadInitial();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(historyProvider.notifier).setSearchQuery(query);
    });
  }

  Future<void> _pickDateRange() async {
    final state = ref.read(historyProvider);
    final now = DateTime.now();
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange:
          state.filterStartDate != null && state.filterEndDate != null
          ? DateTimeRange(
              start: state.filterStartDate!,
              end: state.filterEndDate!,
            )
          : null,
    );

    if (result != null) {
      ref.read(historyProvider.notifier).setDateRange(result.start, result.end);
    }
  }

  void _showSortOptions() {
    final state = ref.read(historyProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  S.get('sort_by'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            _SortOption(
              label: S.get('newest_first'),
              icon: Icons.arrow_downward,
              isSelected: state.sortBy == 'created_at DESC',
              onTap: () {
                ref.read(historyProvider.notifier).setSortBy('created_at DESC');
                Navigator.pop(context);
              },
            ),
            _SortOption(
              label: S.get('oldest_first'),
              icon: Icons.arrow_upward,
              isSelected: state.sortBy == 'created_at ASC',
              onTap: () {
                ref.read(historyProvider.notifier).setSortBy('created_at ASC');
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _sortLabel(String sortBy) {
    switch (sortBy) {
      case 'created_at DESC':
        return S.get('newest_first');
      case 'created_at ASC':
        return S.get('oldest_first');
      default:
        return S.get('newest_first');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(historyProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final hasDateFilter =
        state.filterStartDate != null && state.filterEndDate != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(S.get('history')),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: S.get('statistics'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StatsScreen()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              // ── Search bar ──
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: S.get('search_history'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),

              // ── Filter chip bar ──
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // Leaf type dropdown
                    PopupMenuButton<String?>(
                      initialValue: state.filterLeafType,
                      onSelected: (value) {
                        ref.read(historyProvider.notifier).setFilter(value);
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String?>(
                          value: null,
                          child: Text(S.get('all_types')),
                        ),
                        ...ModelConstants.models.values.map((model) {
                          return PopupMenuItem<String?>(
                            value: model.leafType,
                            child: Text(model.localizedName(S.locale)),
                          );
                        }),
                      ],
                      child: state.filterLeafType != null
                          ? InputChip(
                              avatar: const Icon(Icons.filter_list, size: 18),
                              label: Text(
                                ModelConstants.getModel(
                                  state.filterLeafType!,
                                ).localizedName(S.locale),
                              ),
                              onPressed: () {},
                              onDeleted: () {
                                ref
                                    .read(historyProvider.notifier)
                                    .setFilter(null);
                              },
                              side: BorderSide(color: colorScheme.primary),
                            )
                          : Chip(
                              avatar: const Icon(Icons.filter_list, size: 18),
                              label: Text(S.get('all_types')),
                            ),
                    ),
                    const SizedBox(width: 8),

                    // Sort chip
                    ActionChip(
                      avatar: const Icon(Icons.swap_vert, size: 18),
                      label: Text(_sortLabel(state.sortBy)),
                      onPressed: _showSortOptions,
                    ),
                    const SizedBox(width: 8),

                    // Date chip
                    hasDateFilter
                        ? InputChip(
                            avatar: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              '${DateFormat('MM/dd').format(state.filterStartDate!)} – ${DateFormat('MM/dd').format(state.filterEndDate!)}',
                            ),
                            onPressed: _pickDateRange,
                            onDeleted: () {
                              ref
                                  .read(historyProvider.notifier)
                                  .setDateRange(null, null);
                            },
                          )
                        : ActionChip(
                            avatar: const Icon(Icons.calendar_today, size: 16),
                            label: Text(S.get('all_time')),
                            onPressed: _pickDateRange,
                          ),
                  ],
                ),
              ),

              // ── List ──
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => ref.read(historyProvider.notifier).refresh(),
                  child: state.predictions.isEmpty && !state.isLoading
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.history,
                                size: 64,
                                color: colorScheme.outline,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                S.get('no_scans'),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(color: colorScheme.outline),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                S.get('scans_appear_here'),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount:
                              state.predictions.length +
                              (state.hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= state.predictions.length) {
                              Future.microtask(() {
                                ref.read(historyProvider.notifier).loadMore();
                              });
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final prediction = state.predictions[index];
                            final predModelInfo = ModelConstants.getModel(
                              prediction.leafType,
                            );

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: colorScheme.primaryContainer,
                                  child: Icon(
                                    prediction.leafType == 'tomato'
                                        ? Icons.grass
                                        : Icons.eco,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                title: Text(
                                  predModelInfo.localizedClassName(
                                    prediction.predictedClassName,
                                    S.locale,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  _formatDate(prediction.createdAt),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          DetailScreen(prediction: prediction),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return S.get('just_now');
    if (diff.inMinutes < 60) return S.fmt('minutes_ago', [diff.inMinutes]);
    if (diff.inHours < 24) return S.fmt('hours_ago', [diff.inHours]);
    if (diff.inDays < 7) return S.fmt('days_ago', [diff.inDays]);
    return DateFormat('dd/MM/yyyy').format(date);
  }
}

class _SortOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _SortOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      title: Text(label),
      trailing: isSelected
          ? Icon(Icons.check, color: colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
