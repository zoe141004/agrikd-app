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
      expect(S.fmt('minutes_ago', [5]), '5 min ago');
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
      for (final key in [
        'app_name',
        'history',
        'settings',
        'scan',
        'result',
        'login',
        'email',
        'password',
        'clear',
        'apply',
        'offline_mode',
        'model_version_label',
        'bundled',
        'ota',
        // Keys added in production audit
        'error_saving',
        'error_timeout',
        'interval_1m',
        'interval_5m',
        'interval_15m',
        'interval_30m',
        'interval_1h',
        'interval_6h',
        'interval_24h',
      ]) {
        S.setLocale('vi');
        final vi = S.get(key);
        S.setLocale('en');
        // Vietnamese should not return the key itself (meaning it exists)
        expect(
          vi,
          isNot(equals(key)),
          reason: 'Missing Vietnamese translation for key: $key',
        );
      }
    });

    test('interval keys return expected English values', () {
      S.setLocale('en');
      expect(S.get('interval_1m'), '1 minute');
      expect(S.get('interval_5m'), '5 minutes');
      expect(S.get('interval_15m'), '15 minutes');
      expect(S.get('interval_30m'), '30 minutes');
      expect(S.get('interval_1h'), '1 hour');
      expect(S.get('interval_6h'), '6 hours');
      expect(S.get('interval_24h'), '24 hours');
    });

    test('interval keys return expected Vietnamese values', () {
      S.setLocale('vi');
      expect(S.get('interval_1m'), '1 phút');
      expect(S.get('interval_5m'), '5 phút');
      expect(S.get('interval_15m'), '15 phút');
      expect(S.get('interval_30m'), '30 phút');
      expect(S.get('interval_1h'), '1 giờ');
      expect(S.get('interval_6h'), '6 giờ');
      expect(S.get('interval_24h'), '24 giờ');
    });

    test('error keys return expected values both locales', () {
      S.setLocale('en');
      expect(S.get('error_saving'), 'Failed to save. Please try again.');
      expect(S.get('error_timeout'), 'Request timed out. Please try again.');
      S.setLocale('vi');
      expect(S.get('error_saving'), 'Lưu thất bại. Vui lòng thử lại.');
      expect(
        S.get('error_timeout'),
        'Yêu cầu hết thời gian chờ. Vui lòng thử lại.',
      );
    });
  });
}
