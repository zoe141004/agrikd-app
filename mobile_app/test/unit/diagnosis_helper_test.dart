import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/diagnosis_provider.dart';

void main() {
  group('DiagnosisStatus enum', () {
    test('has exactly 4 values', () {
      expect(DiagnosisStatus.values, hasLength(4));
    });

    test('contains expected statuses', () {
      expect(
        DiagnosisStatus.values,
        containsAll([
          DiagnosisStatus.idle,
          DiagnosisStatus.loading,
          DiagnosisStatus.success,
          DiagnosisStatus.error,
        ]),
      );
    });
  });

  group('DiagnosisState', () {
    test('defaults to idle, no prediction, no error', () {
      const state = DiagnosisState();
      expect(state.status, DiagnosisStatus.idle);
      expect(state.prediction, isNull);
      expect(state.errorMessage, isNull);
    });

    test('copyWith preserves existing values when no args supplied', () {
      const original = DiagnosisState(status: DiagnosisStatus.loading);
      final copy = original.copyWith();
      expect(copy.status, DiagnosisStatus.loading);
      expect(copy.prediction, isNull);
      expect(copy.errorMessage, isNull);
    });

    test('copyWith overrides only supplied field', () {
      const original = DiagnosisState(status: DiagnosisStatus.idle);
      final copy = original.copyWith(status: DiagnosisStatus.loading);
      expect(copy.status, DiagnosisStatus.loading);
    });

    test('copyWith always clears errorMessage when not supplied', () {
      const original = DiagnosisState(errorMessage: 'previous error');
      final copy = original.copyWith(status: DiagnosisStatus.loading);
      expect(copy.errorMessage, isNull);
    });

    test('copyWith sets errorMessage when provided', () {
      const state = DiagnosisState();
      final errState = state.copyWith(
        status: DiagnosisStatus.error,
        errorMessage: 'model corrupted',
      );
      expect(errState.status, DiagnosisStatus.error);
      expect(errState.errorMessage, 'model corrupted');
    });

    test('success state can be set', () {
      const state = DiagnosisState(status: DiagnosisStatus.success);
      expect(state.status, DiagnosisStatus.success);
    });

    test('status transitions: idle → loading → success', () {
      const idle = DiagnosisState();
      final loading = idle.copyWith(status: DiagnosisStatus.loading);
      final success = loading.copyWith(status: DiagnosisStatus.success);
      expect(idle.status, DiagnosisStatus.idle);
      expect(loading.status, DiagnosisStatus.loading);
      expect(success.status, DiagnosisStatus.success);
    });

    test('status transitions: idle → loading → error', () {
      const idle = DiagnosisState();
      final loading = idle.copyWith(status: DiagnosisStatus.loading);
      final error = loading.copyWith(
        status: DiagnosisStatus.error,
        errorMessage: 'inference failed',
      );
      expect(error.status, DiagnosisStatus.error);
      expect(error.errorMessage, 'inference failed');
    });
  });
}
