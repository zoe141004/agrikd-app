import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/evaluation_provider.dart';

void main() {
  group('EvaluationNotifier.toDouble', () {
    test('null returns null', () {
      expect(EvaluationNotifier.toDouble(null), isNull);
    });

    test('double returns same value', () {
      expect(EvaluationNotifier.toDouble(0.87), 0.87);
    });

    test('int returns double', () {
      expect(EvaluationNotifier.toDouble(87), 87.0);
      expect(EvaluationNotifier.toDouble(87), isA<double>());
    });

    test('zero int returns 0.0', () {
      expect(EvaluationNotifier.toDouble(0), 0.0);
    });

    test('valid string parses to double', () {
      expect(EvaluationNotifier.toDouble('0.872'), closeTo(0.872, 0.0001));
    });

    test('valid integer string parses to double', () {
      expect(EvaluationNotifier.toDouble('100'), 100.0);
    });

    test('invalid string returns null', () {
      expect(EvaluationNotifier.toDouble('not_a_number'), isNull);
    });

    test('empty string returns null', () {
      expect(EvaluationNotifier.toDouble(''), isNull);
    });

    test('bool returns null (unsupported type)', () {
      expect(EvaluationNotifier.toDouble(true), isNull);
    });

    test('list returns null (unsupported type)', () {
      expect(EvaluationNotifier.toDouble([1.0]), isNull);
    });
  });

  group('ModelEvaluationInfo', () {
    test('constructs with required fields', () {
      const info = ModelEvaluationInfo(leafType: 'tomato', version: '1.1.0');
      expect(info.leafType, 'tomato');
      expect(info.version, '1.1.0');
      expect(info.accuracy, isNull);
    });

    test('constructs with all optional metrics', () {
      const info = ModelEvaluationInfo(
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
      const info = ModelEvaluationInfo(
        leafType: 'burmese_grape_leaf',
        version: '1.0.0',
      );
      expect(info.leafType, 'burmese_grape_leaf');
    });
  });

  group('EvaluationState', () {
    test('defaults to empty evaluations, not loading', () {
      const state = EvaluationState();
      expect(state.evaluations, isEmpty);
      expect(state.isLoading, isFalse);
    });

    test('can be constructed loading', () {
      const state = EvaluationState(isLoading: true);
      expect(state.isLoading, isTrue);
      expect(state.evaluations, isEmpty);
    });

    test('can be constructed with evaluation data', () {
      const info = ModelEvaluationInfo(leafType: 'tomato', version: '1.1.0');
      final state = EvaluationState(evaluations: {'tomato': info});
      expect(state.evaluations, hasLength(1));
      expect(state.evaluations['tomato']?.version, '1.1.0');
    });
  });
}
