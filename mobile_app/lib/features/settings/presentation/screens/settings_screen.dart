import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/auth_provider.dart';
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
              ListTile(
                leading: const Icon(Icons.memory),
                title: Text(S.get('models')),
                subtitle: _buildModelVersionsSummary(ref),
              ),
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

  Widget _buildModelVersionsSummary(WidgetRef ref) {
    final mvState = ref.watch(modelVersionProvider);
    if (mvState.isLoading) {
      return const Text('...');
    }

    final lines = <String>[];
    for (final leafType in ModelConstants.availableLeafTypes) {
      final m = ModelConstants.getModel(leafType);
      final versions = mvState.versions[leafType] ?? [];
      final active = versions.where((v) => v.role == 'active').firstOrNull;
      final fallback = versions.where((v) => v.role == 'fallback').firstOrNull;

      final activeLabel = active != null
          ? 'v${active.version}${active.isBundled ? '' : ' (OTA)'}'
          : '-';
      final fbLabel = fallback != null
          ? ' | FB: v${fallback.version}'
          : '';

      lines.add('${m.localizedName(S.locale)}: $activeLabel$fbLabel');
    }
    return Text(lines.join('\n'));
  }
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
