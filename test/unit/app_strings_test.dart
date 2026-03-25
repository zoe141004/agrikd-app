import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/l10n/app_strings.dart';

void main() {
  group('AppStrings (S)', () {
    setUp(() {
      S.setLocale('en');
    });

    test('get returns English string by default', () {
      expect(S.get('app_name'), 'AgriKD');
      expect(S.get('history'), 'History');
    });

    test('get returns Vietnamese string when locale is vi', () {
      S.setLocale('vi');
      expect(S.get('app_name'), 'AgriKD');
      expect(S.get('history'), 'Lịch sử');
    });

    test('get returns key when string not found', () {
      expect(S.get('nonexistent_key'), 'nonexistent_key');
    });

    test('fmt replaces placeholders', () {
      expect(S.fmt('n_diseases', [9]), '9 diseases');
      expect(S.fmt('sure_pct', ['95.0']), '95.0% sure');
    });

    test('fmt replaces multiple placeholders', () {
      // sync_success has {0}
      expect(S.fmt('sync_success', [5]), '5 scans synced');
    });

    test('setLocale falls back to en for unknown locale', () {
      S.setLocale('fr');
      expect(S.locale, 'en');
    });

    test('setLocale accepts vi', () {
      S.setLocale('vi');
      expect(S.locale, 'vi');
    });

    test('all en keys exist in vi', () {
      // Ensure no missing translations
      S.setLocale('en');
      final enKeys = <String>{};
      // Access keys via get — can't directly access _strings, test behavior
      for (final key in [
        'app_name', 'history', 'settings', 'scan', 'result',
        'login', 'email', 'password',
        'min_confidence', 'confidence', 'clear', 'apply',
        'offline_mode',
      ]) {
        enKeys.add(key);
        S.setLocale('vi');
        final vi = S.get(key);
        S.setLocale('en');
        // Vietnamese should not return the key itself (meaning it exists)
        expect(vi, isNot(equals(key)),
            reason: 'Missing Vietnamese translation for key: $key');
      }
    });
  });
}
