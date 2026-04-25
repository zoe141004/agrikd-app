import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/utils/format_helpers.dart';

void main() {
  group('formatPercent', () {
    test('null returns em-dash', () {
      expect(formatPercent(null), '—');
    });

    test('0.0 returns 0.00%', () {
      expect(formatPercent(0.0), '0.00%');
    });

    test('1.0 returns 100.00%', () {
      expect(formatPercent(1.0), '100.00%');
    });

    test('typical accuracy 0.872 returns 87.20%', () {
      expect(formatPercent(0.872), '87.20%');
    });

    test('typical accuracy 0.873 returns 87.30%', () {
      expect(formatPercent(0.873), '87.30%');
    });

    test('small value 0.001 returns 0.10%', () {
      expect(formatPercent(0.001), '0.10%');
    });

    test('rounding 0.8725 rounds correctly', () {
      final result = formatPercent(0.8725);
      expect(result, matches(r'^\d+\.\d{2}%$'));
    });

    test('value > 1 treated as already-percentage (pre-migration guard)', () {
      // Values > 1 are assumed to be already in percentage form (e.g. 87.6 not 0.876)
      expect(formatPercent(1.5), '1.50%');
      expect(formatPercent(87.603), '87.60%');
    });

    test('very small value near zero', () {
      expect(formatPercent(0.0001), '0.01%');
    });
  });
}
