import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/benchmark_provider.dart';

void main() {
  group('BenchmarkNotifier.toDouble', () {
    test('null returns null', () {
      expect(BenchmarkNotifier.toDouble(null), isNull);
    });

    test('double returns same value', () {
      expect(BenchmarkNotifier.toDouble(0.87), 0.87);
    });

    test('int returns double', () {
      expect(BenchmarkNotifier.toDouble(87), 87.0);
      expect(BenchmarkNotifier.toDouble(87), isA<double>());
    });

    test('zero int returns 0.0', () {
      expect(BenchmarkNotifier.toDouble(0), 0.0);
    });

    test('valid string parses to double', () {
      expect(BenchmarkNotifier.toDouble('0.872'), closeTo(0.872, 0.0001));
    });

    test('valid integer string parses to double', () {
      expect(BenchmarkNotifier.toDouble('100'), 100.0);
    });

    test('invalid string returns null', () {
      expect(BenchmarkNotifier.toDouble('not_a_number'), isNull);
    });

    test('empty string returns null', () {
      expect(BenchmarkNotifier.toDouble(''), isNull);
    });

    test('bool returns null (unsupported type)', () {
      expect(BenchmarkNotifier.toDouble(true), isNull);
    });

    test('list returns null (unsupported type)', () {
      expect(BenchmarkNotifier.toDouble([1.0]), isNull);
    });
  });

  group('ModelBenchmarkInfo', () {
    test('constructs with required fields', () {
      const info = ModelBenchmarkInfo(leafType: 'tomato', version: '1.1.0');
      expect(info.leafType, 'tomato');
      expect(info.version, '1.1.0');
      expect(info.accuracy, isNull);
    });

    test('constructs with all optional metrics', () {
      const info = ModelBenchmarkInfo(
        leafType: 'tomato',
        version: '1.1.0',
        accuracy: 0.872,
        precisionMacro: 0.865,
        recallMacro: 0.870,
        f1Macro: 0.867,
        flopsM: 150.0,
        latencyMeanMs: 12.5,
        sizeMb: 0.96,
        paramsM: 3.4,
      );
      expect(info.accuracy, closeTo(0.872, 0.0001));
      expect(info.sizeMb, closeTo(0.96, 0.001));
      expect(info.paramsM, closeTo(3.4, 0.01));
    });

    test('supports burmese_grape_leaf type', () {
      const info = ModelBenchmarkInfo(
        leafType: 'burmese_grape_leaf',
        version: '1.0.0',
      );
      expect(info.leafType, 'burmese_grape_leaf');
    });
  });

  group('BenchmarkState', () {
    test('defaults to empty benchmarks, not loading', () {
      const state = BenchmarkState();
      expect(state.benchmarks, isEmpty);
      expect(state.isLoading, isFalse);
    });

    test('can be constructed loading', () {
      const state = BenchmarkState(isLoading: true);
      expect(state.isLoading, isTrue);
      expect(state.benchmarks, isEmpty);
    });

    test('can be constructed with benchmark data', () {
      const info = ModelBenchmarkInfo(leafType: 'tomato', version: '1.1.0');
      final state = BenchmarkState(benchmarks: {'tomato': info});
      expect(state.benchmarks, hasLength(1));
      expect(state.benchmarks['tomato']?.version, '1.1.0');
    });
  });
}
