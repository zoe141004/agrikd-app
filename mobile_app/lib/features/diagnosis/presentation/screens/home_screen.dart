import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/available_models_provider.dart';
import 'package:app/providers/diagnosis_provider.dart';
import 'package:app/providers/model_version_provider.dart';
import 'package:app/features/history/presentation/screens/history_screen.dart';
import 'package:app/features/settings/presentation/screens/settings_screen.dart';
import '../widgets/stats_card.dart';
import 'camera_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [_HomeBody(), HistoryScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: S.get('nav_home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.history_outlined),
            selectedIcon: const Icon(Icons.history),
            label: S.get('nav_history'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: S.get('nav_settings'),
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => _openCamera(context),
              icon: const Icon(Icons.camera_alt),
              label: Text(S.get('scan')),
            )
          : null,
    );
  }

  void _openCamera(BuildContext context) {
    final leafType = ref.read(selectedLeafTypeProvider);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CameraScreen(leafType: leafType)),
    );
  }
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody();

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedLeafType = ref.watch(selectedLeafTypeProvider);
    final allModels = ref.watch(availableModelsProvider).values.toList();
    final colorScheme = Theme.of(context).colorScheme;

    final filteredModels = _searchQuery.isEmpty
        ? allModels
        : allModels
              .where(
                (m) =>
                    m.englishName.toLowerCase().contains(_searchQuery) ||
                    m.vietnameseName.toLowerCase().contains(_searchQuery) ||
                    m.leafType.toLowerCase().contains(_searchQuery),
              )
              .toList();

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            children: [
              // ── Branded header ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.eco,
                      size: 24,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.get('app_name'),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        S.get('app_subtitle'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Quick guide ── (1 row of 4)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.get('quick_guide'),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _StepItem(
                            number: '1',
                            label: S.get('step_select'),
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _StepItem(
                            number: '2',
                            label: S.get('step_scan'),
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _StepItem(
                            number: '3',
                            label: S.get('step_result'),
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _StepItem(
                            number: '4',
                            label: S.get('step_history'),
                            colorScheme: colorScheme,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── Leaf type selector ──
              Text(
                S.get('select_leaf_type'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),

              // Search
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: S.get('search_leaf'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value.toLowerCase());
                },
              ),
              const SizedBox(height: 8),

              // Model list
              if (filteredModels.isEmpty && _searchQuery.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      S.get('no_match'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),

              ...filteredModels.map((modelInfo) {
                final isSelected = selectedLeafType == modelInfo.leafType;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _LeafTypeItem(
                    modelInfo: modelInfo,
                    isSelected: isSelected,
                    onTap: () {
                      ref.read(selectedLeafTypeProvider.notifier).state =
                          modelInfo.leafType;
                    },
                  ),
                );
              }),
              const SizedBox(height: 12),

              // ── Stats ──
              const StatsCard(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A selectable leaf-type card with expandable disease details.
class _LeafTypeItem extends ConsumerWidget {
  final LeafModelInfo modelInfo;
  final bool isSelected;
  final VoidCallback onTap;

  const _LeafTypeItem({
    required this.modelInfo,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final versionState = ref.watch(modelVersionProvider);
    final versions = versionState.versions[modelInfo.leafType] ?? [];
    final activeVersions = versions.where((v) => v.role == 'active').toList();

    return Card(
      elevation: isSelected ? 0 : 1,
      color: isSelected ? colorScheme.primaryContainer : colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? BorderSide(color: colorScheme.primary, width: 1.5)
            : BorderSide(color: colorScheme.outlineVariant, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            children: [
              // Header row
              Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.outline,
                    size: 24,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          modelInfo.localizedName(S.locale),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isSelected
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurface,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          S.fmt('n_diseases', [modelInfo.diseaseCount]),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: isSelected
                                    ? colorScheme.onPrimaryContainer.withValues(
                                        alpha: 0.7,
                                      )
                                    : colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primary.withValues(alpha: 0.15)
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${modelInfo.diseaseCount}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),

              // Expandable disease detail
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: isSelected
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, left: 38),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Divider(
                              height: 1,
                              color: colorScheme.outlineVariant,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              S.get('detectable_diseases'),
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            ...modelInfo.diseaseLabels.map((label) {
                              final displayName = modelInfo.localizedClassName(
                                label,
                                S.locale,
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Icon(
                                        Icons.circle,
                                        size: 6,
                                        color: colorScheme.onPrimaryContainer
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        displayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colorScheme
                                                  .onPrimaryContainer
                                                  .withValues(alpha: 0.85),
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                            if (modelInfo.hasHealthyClass)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline,
                                      size: 14,
                                      color: Colors.green.shade700,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      S.get('plus_healthy'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Colors.green.shade700,
                                            fontStyle: FontStyle.italic,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            // Version picker (only when ≥2 active versions)
                            if (activeVersions.length >= 2) ...[
                              const SizedBox(height: 8),
                              Divider(
                                height: 1,
                                color: colorScheme.outlineVariant,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                S.get('model_version_label'),
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              ...activeVersions.map((v) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: v.isSelected
                                      ? null
                                      : () => ref
                                            .read(modelVersionProvider.notifier)
                                            .selectVersion(
                                              modelInfo.leafType,
                                              v.version,
                                            ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          v.isSelected
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          size: 18,
                                          color: v.isSelected
                                              ? colorScheme.primary
                                              : colorScheme.onPrimaryContainer
                                                    .withValues(alpha: 0.5),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'v${v.version}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontWeight: v.isSelected
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                  color: colorScheme
                                                      .onPrimaryContainer,
                                                ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: colorScheme
                                                .surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            v.isBundled
                                                ? S.get('bundled')
                                                : S.get('ota'),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                            const SizedBox(height: 4),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepItem extends StatelessWidget {
  final String number;
  final String label;
  final ColorScheme colorScheme;

  const _StepItem({
    required this.number,
    required this.label,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
