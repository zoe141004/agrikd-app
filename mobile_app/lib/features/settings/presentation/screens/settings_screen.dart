import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/benchmark_provider.dart';
import 'package:app/providers/model_version_provider.dart';
import 'package:app/providers/settings_provider.dart';
import 'package:app/providers/sync_provider.dart';
import 'package:app/features/auth/presentation/screens/login_screen.dart';
import 'benchmark_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final authState = ref.watch(authProvider);

    final currentTheme = settings['theme'] ?? 'system';
    final defaultLeafType = settings['default_leaf_type'] ?? 'tomato';
    final autoSync = settings['auto_sync'] != 'false';

    return Scaffold(
      appBar: AppBar(title: Text(S.get('settings'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              _SectionHeader(S.get('account')),
              if (authState.status == AuthStatus.authenticated) ...[
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(S.get('signed_in')),
                  subtitle: Text(authState.user?.email ?? ''),
                  trailing: TextButton(
                    onPressed: () {
                      ref.read(authProvider.notifier).signOut();
                    },
                    child: Text(S.get('sign_out')),
                  ),
                ),
              ] else ...[
                ListTile(
                  leading: const Icon(Icons.login),
                  title: Text(S.get('login_to_backup')),
                  subtitle: Text(S.get('login_subtitle')),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  },
                ),
              ],
              const Divider(),
              _SectionHeader(S.get('general')),
              ListTile(
                leading: const Icon(Icons.eco),
                title: Text(S.get('default_crop')),
                subtitle: Text(
                  ModelConstants.getModel(
                    defaultLeafType,
                  ).localizedName(S.locale),
                ),
                onTap: () => _showLeafTypePicker(notifier, defaultLeafType),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.cloud_upload_outlined),
                title: Text(S.get('auto_backup')),
                subtitle: Text(S.get('auto_backup_sub')),
                value: autoSync,
                onChanged: (value) {
                  notifier.setValue('auto_sync', value.toString());
                },
              ),
              ListTile(
                leading: const Icon(Icons.sync),
                title: Text(S.get('sync_now')),
                subtitle: Builder(
                  builder: (context) {
                    final syncState = ref.watch(syncProvider);
                    if (syncState.status == SyncStatus.syncing) {
                      return Text(S.get('sync_syncing'));
                    }
                    if (syncState.status == SyncStatus.error) {
                      return Text(
                        S.get('sync_failed_short'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      );
                    }
                    if (syncState.lastSyncedAt != null) {
                      return Text(_formatRelativeTime(syncState.lastSyncedAt!));
                    }
                    return Text(S.get('sync_not_synced_yet'));
                  },
                ),
                trailing: ref.watch(syncProvider).status == SyncStatus.syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: () async {
                  final syncState = ref.read(syncProvider);
                  if (syncState.status == SyncStatus.syncing) return;

                  final authState2 = ref.read(authProvider);
                  if (authState2.status != AuthStatus.authenticated) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(S.get('sync_not_logged_in'))),
                    );
                    return;
                  }

                  await ref.read(syncProvider.notifier).syncNow();
                },
              ),
              const Divider(),
              _SectionHeader(S.get('appearance')),
              ListTile(
                leading: const Icon(Icons.palette),
                title: Text(S.get('theme')),
                subtitle: Text(S.get('theme_$currentTheme')),
                onTap: () => _showThemePicker(notifier, currentTheme),
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(S.get('language')),
                subtitle: Text(S.locale == 'vi' ? 'Tiếng Việt' : 'English'),
                onTap: () => _showLanguagePicker(notifier),
              ),
              const Divider(),
              _SectionHeader(S.get('about')),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(S.get('benchmark')),
                subtitle: Text(S.get('benchmark_sub')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BenchmarkScreen()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(S.get('app_name')),
                subtitle: Text(S.get('app_version')),
              ),
              ...ModelConstants.availableLeafTypes.map((leafType) {
                final modelInfo = ModelConstants.getModel(leafType);
                return ListTile(
                  leading: const Icon(Icons.memory),
                  title: Text(modelInfo.localizedName(S.locale)),
                  subtitle: _buildModelVersionLine(ref, leafType),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showModelSpecsSheet(context, ref, leafType),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemePicker(SettingsNotifier notifier, String current) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(S.get('choose_theme')),
        children: ['system', 'light', 'dark'].map((theme) {
          return SimpleDialogOption(
            onPressed: () {
              notifier.setValue('theme', theme);
              Navigator.pop(context);
            },
            child: Row(
              children: [
                Icon(
                  current == theme
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(S.get('theme_$theme')),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showLeafTypePicker(SettingsNotifier notifier, String current) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(S.get('default_crop')),
        children: ModelConstants.availableLeafTypes.map((type) {
          final info = ModelConstants.getModel(type);
          return SimpleDialogOption(
            onPressed: () {
              notifier.setValue('default_leaf_type', type);
              Navigator.pop(context);
            },
            child: Row(
              children: [
                Icon(
                  current == type
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(info.localizedName(S.locale))),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showLanguagePicker(SettingsNotifier notifier) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(S.get('choose_language')),
        children: [
          SimpleDialogOption(
            onPressed: () {
              notifier.setValue('language', 'en');
              S.setLocale('en');
              Navigator.pop(context);
              setState(() {});
            },
            child: Row(
              children: [
                Icon(
                  S.locale == 'en'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Text('English'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () {
              notifier.setValue('language', 'vi');
              S.setLocale('vi');
              Navigator.pop(context);
              setState(() {});
            },
            child: Row(
              children: [
                Icon(
                  S.locale == 'vi'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Text('Tiếng Việt'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatRelativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return S.get('just_now');
    if (diff.inMinutes < 60) return S.fmt('minutes_ago', [diff.inMinutes]);
    if (diff.inHours < 24) return S.fmt('hours_ago', [diff.inHours]);
    return S.fmt('days_ago', [diff.inDays]);
  }

  Widget _buildModelVersionLine(WidgetRef ref, String leafType) {
    final mvState = ref.watch(modelVersionProvider);
    if (mvState.isLoading) return const Text('...');

    final versions = mvState.versions[leafType] ?? [];
    final selected = versions.where((v) => v.isSelected).firstOrNull;
    if (selected == null) return Text(S.get('no_data'));

    final label = 'v${selected.version}${selected.isBundled ? '' : ' (OTA)'}';
    return Text(label);
  }

  void _showModelSpecsSheet(
    BuildContext context,
    WidgetRef ref,
    String leafType,
  ) {
    final benchState = ref.read(benchmarkProvider);
    final bench = benchState.benchmarks[leafType];
    final modelInfo = ModelConstants.getModel(leafType);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  modelInfo.localizedName(S.locale),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                if (bench != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'v${bench.version} — TFLite Float16',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
                if (bench == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Icon(
                          Icons.cloud_off,
                          size: 48,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          S.get('model_specs_unavailable'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else ...[
                  _SpecRow(S.get('spec_accuracy'), _pct(bench.accuracy)),
                  _SpecRow(S.get('spec_precision'), _pct(bench.precisionMacro)),
                  _SpecRow(S.get('spec_recall'), _pct(bench.recallMacro)),
                  _SpecRow(S.get('spec_f1'), _pct(bench.f1Macro)),
                  const Divider(height: 24),
                  _SpecRow(
                    S.get('spec_flops'),
                    bench.flopsM != null
                        ? '${bench.flopsM!.toStringAsFixed(1)} M'
                        : '—',
                  ),
                  _SpecRow(
                    S.get('spec_latency'),
                    bench.latencyMeanMs != null
                        ? '${bench.latencyMeanMs!.toStringAsFixed(1)} ms'
                        : '—',
                  ),
                  _SpecRow(
                    S.get('spec_size'),
                    bench.sizeMb != null
                        ? '${bench.sizeMb!.toStringAsFixed(2)} MB'
                        : '—',
                  ),
                  _SpecRow(
                    S.get('spec_params'),
                    bench.paramsM != null
                        ? '${bench.paramsM!.toStringAsFixed(2)} M'
                        : '—',
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  String _pct(double? v) => v != null ? '${v.toStringAsFixed(1)}%' : '—';
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SpecRow extends StatelessWidget {
  final String label;
  final String value;

  const _SpecRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
