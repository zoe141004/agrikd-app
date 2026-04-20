import 'package:flutter_test/flutter_test.dart';

import 'package:app/providers/auth_provider.dart';

void main() {
  group('AuthStatus enum', () {
    test('has exactly 4 values', () {
      expect(AuthStatus.values, hasLength(4));
    });

    test('contains expected statuses', () {
      expect(
        AuthStatus.values,
        containsAll([
          AuthStatus.unknown,
          AuthStatus.authenticated,
          AuthStatus.unauthenticated,
          AuthStatus.passwordRecovery,
        ]),
      );
    });
  });

  group('AuthState', () {
    test('defaults to unknown status, not loading, no user, no error', () {
      const state = AuthState();
      expect(state.status, AuthStatus.unknown);
      expect(state.isLoading, isFalse);
      expect(state.user, isNull);
      expect(state.errorMessage, isNull);
    });

    test('copyWith preserves existing values when no args supplied', () {
      const original = AuthState(
        status: AuthStatus.authenticated,
        isLoading: false,
        errorMessage: null,
      );
      final copy = original.copyWith();
      expect(copy.status, AuthStatus.authenticated);
      expect(copy.isLoading, isFalse);
      expect(copy.errorMessage, isNull);
    });

    test('copyWith overrides only supplied fields', () {
      const original = AuthState(
        status: AuthStatus.authenticated,
        isLoading: false,
      );
      final copy = original.copyWith(isLoading: true);
      expect(copy.status, AuthStatus.authenticated);
      expect(copy.isLoading, isTrue);
    });

    test('copyWith always clears errorMessage (nullable override)', () {
      const original = AuthState(errorMessage: 'old error');
      // Calling copyWith without errorMessage resets it to null (by design)
      final cleared = original.copyWith();
      expect(cleared.errorMessage, isNull);
    });

    test('copyWith sets errorMessage when provided', () {
      const original = AuthState();
      final withError = original.copyWith(errorMessage: 'sign in failed');
      expect(withError.errorMessage, 'sign in failed');
    });

    test('copyWith can transition from unauthenticated to authenticated', () {
      const state = AuthState(status: AuthStatus.unauthenticated);
      final next = state.copyWith(status: AuthStatus.authenticated);
      expect(next.status, AuthStatus.authenticated);
    });

    test('loading state is isolated from status', () {
      const state = AuthState(status: AuthStatus.unknown);
      final loading = state.copyWith(isLoading: true);
      expect(loading.status, AuthStatus.unknown);
      expect(loading.isLoading, isTrue);
    });

    test('passwordRecovery is a distinct state', () {
      final state = AuthState(status: AuthStatus.passwordRecovery);
      expect(state.status, AuthStatus.passwordRecovery);
      expect(state.status, isNot(AuthStatus.authenticated));
    });
  });
}
