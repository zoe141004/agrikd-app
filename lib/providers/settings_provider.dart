import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'database_provider.dart';

class SettingsNotifier extends StateNotifier<Map<String, String>> {
  final Ref _ref;

  SettingsNotifier(this._ref) : super({});

  Future<void> loadAll() async {
    final dao = _ref.read(preferenceDaoProvider);
    state = await dao.getAllPreferences();
    // Apply saved language
    final lang = state['language'] ?? 'en';
    S.setLocale(lang);
  }

  Future<void> setValue(String key, String value) async {
    final dao = _ref.read(preferenceDaoProvider);
    await dao.setValue(key, value);
    state = {...state, key: value};
    // Keep locale in sync
    if (key == 'language') {
      S.setLocale(value);
    }
  }

  String getValue(String key, {String defaultValue = ''}) {
    return state[key] ?? defaultValue;
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, Map<String, String>>((ref) {
      return SettingsNotifier(ref);
    });

final themeModeProvider = Provider<ThemeMode>((ref) {
  final theme = ref.watch(
    settingsProvider.select((s) => s['theme'] ?? 'system'),
  );
  switch (theme) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
});
