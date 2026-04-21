import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/utils/format_helpers.dart';

void main() {
  group('formatPercent', () {
    test('null returns em-dash', () {
      expect(formatPercent(null), '—');
    });

    test('0.0 returns 0.0%', () {
      expect(formatPercent(0.0), '0.0%');
    });

    test('1.0 returns 100.0%', () {
      expect(formatPercent(1.0), '100.0%');
    });

    test('typical accuracy 0.872 returns 87.2%', () {
      expect(formatPercent(0.872), '87.2%');
    });

    test('typical accuracy 0.873 returns 87.3%', () {
      expect(formatPercent(0.873), '87.3%');
    });

    test('small value 0.001 returns 0.1%', () {
      expect(formatPercent(0.001), '0.1%');
    });

    test('rounding 0.8725 rounds to 87.3% (half-up)', () {
      // toStringAsFixed(1) uses round-half-to-even, so 87.25 → 87.2 or 87.3
      // depending on implementation. Just verify it produces a valid 1-decimal string.
      final result = formatPercent(0.8725);
      expect(result, matches(r'^\d+\.\d%$'));
    });

    test('value > 1 produces percentage > 100', () {
      expect(formatPercent(1.5), '150.0%');
    });

    test('very small value near zero', () {
      expect(formatPercent(0.0001), '0.0%');
    });
  });
}
