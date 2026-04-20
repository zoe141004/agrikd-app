import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/settings_provider.dart';
import 'package:app/data/database/dao/preference_dao.dart';

import '../test_helper.dart';
import 'package:app/data/database/app_database.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
    await resetTestDatabase();
    await AppDatabase.database;
  });

  group('SettingsNotifier', () {
    test('loadAll populates state from DB', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();
      final state = container.read(settingsProvider);

      expect(state, isA<Map<String, String>>());
      expect(state['default_leaf_type'], isNotNull);
    });

    test('setValue updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();
      await container
          .read(settingsProvider.notifier)
          .setValue('test_setting', 'abc');

      final state = container.read(settingsProvider);
      expect(state['test_setting'], 'abc');

      // Also check DB directly
      final dao = PreferenceDao();
      final dbValue = await dao.getValue('test_setting');
      expect(dbValue, 'abc');
    });
  });

  group('themeModeProvider', () {
    test('returns ThemeMode.system by default', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();
      // Restore theme to system
      await container
          .read(settingsProvider.notifier)
          .setValue('theme', 'system');

      final mode = container.read(themeModeProvider);
      expect(mode, ThemeMode.system);
    });

    test('returns ThemeMode.dark when set', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();
      await container.read(settingsProvider.notifier).setValue('theme', 'dark');

      final mode = container.read(themeModeProvider);
      expect(mode, ThemeMode.dark);

      // Cleanup
      await container
          .read(settingsProvider.notifier)
          .setValue('theme', 'system');
    });

    test('returns ThemeMode.light when set', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();
      await container
          .read(settingsProvider.notifier)
          .setValue('theme', 'light');

      final mode = container.read(themeModeProvider);
      expect(mode, ThemeMode.light);

      // Cleanup
      await container
          .read(settingsProvider.notifier)
          .setValue('theme', 'system');
    });
  });

  group('Language setting', () {
    test('language can be changed between vi and en', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).loadAll();

      await container
          .read(settingsProvider.notifier)
          .setValue('language', 'vi');
      expect(container.read(settingsProvider)['language'], 'vi');

      await container
          .read(settingsProvider.notifier)
          .setValue('language', 'en');
      expect(container.read(settingsProvider)['language'], 'en');

      // Restore default
      await container
          .read(settingsProvider.notifier)
          .setValue('language', 'en');
    });
  });
}
