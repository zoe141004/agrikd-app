import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:app/core/config/env_config.dart';
import 'package:app/core/config/supabase_config.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/data/database/app_database.dart';

enum AuthStatus { unknown, authenticated, unauthenticated, passwordRecovery }

class AuthState {
  final AuthStatus status;
  final User? user;
  final String? errorMessage;
  final bool isLoading;

  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.errorMessage,
    this.isLoading = false,
  });

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    String? errorMessage,
    bool? isLoading,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      errorMessage: errorMessage,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  StreamSubscription? _authSub;
  GoogleSignIn? _googleSignIn;

  AuthNotifier() : super(const AuthState()) {
    _init();
  }

  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(errorMessage: null);
    }
  }

  /// Map raw Supabase AuthException messages to user-friendly localized strings.
  static String _friendlyAuthError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('invalid login credentials') ||
        lower.contains('invalid_credentials')) {
      return S.get('err_invalid_credentials');
    }
    if (lower.contains('email not confirmed')) {
      return S.get('err_email_not_confirmed');
    }
    if (lower.contains('already registered') ||
        lower.contains('already been registered') ||
        lower.contains('already exists')) {
      return S.get('err_user_already_registered');
    }
    if (lower.contains('email rate limit') ||
        lower.contains('email_rate_limit')) {
      return S.get('err_email_rate_limit');
    }
    if (lower.contains('rate limit') || lower.contains('too many requests')) {
      return S.get('err_rate_limit');
    }
    if (lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('connection')) {
      return S.get('err_network');
    }
    if (lower.contains('password') && lower.contains('weak')) {
      return S.get('password_short');
    }
    return S.get('err_auth_generic');
  }

  void _init() {
    if (!SupabaseConfig.isInitialized) {
      // Supabase not initialized (offline cold start).
      // Stay in 'unknown' so the app shows a loading/splash screen
      // instead of prematurely showing the login page.
      // retryInit() will be called when connectivity restores.
      return;
    }

    try {
      final client = SupabaseConfig.client;
      final currentUser = client.auth.currentUser;

      if (currentUser != null) {
        state = AuthState(status: AuthStatus.authenticated, user: currentUser);
      } else {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }

      _authSub = client.auth.onAuthStateChange.listen((event) {
        final user = event.session?.user;
        if (event.event == AuthChangeEvent.passwordRecovery && user != null) {
          state = AuthState(status: AuthStatus.passwordRecovery, user: user);
        } else if (user != null) {
          state = AuthState(status: AuthStatus.authenticated, user: user);
        } else {
          state = const AuthState(status: AuthStatus.unauthenticated);
        }
      });
    } catch (_) {
      // Unexpected error accessing Supabase — stay unknown for retry
    }
  }

  /// Re-attempt auth initialization after Supabase becomes available.
  /// Called when connectivity restores after an offline cold start.
  void retryInit() {
    if (SupabaseConfig.isInitialized && _authSub == null) {
      _init();
    }
  }

  Future<void> signIn(String email, String password) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await SupabaseConfig.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      // onAuthStateChange will set authenticated; clear loading here
      state = state.copyWith(isLoading: false);
    } on AuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyAuthError(e.message),
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: S.get('err_network'),
      );
    }
  }

  Future<void> signUp(String email, String password) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final response = await SupabaseConfig.client.auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: 'com.agrikd.app://callback',
      );
      // If email confirmation is required, user won't be authenticated yet.
      // Signal success so UI can show "check your email" message.
      if (response.user != null && response.user!.emailConfirmedAt == null) {
        state = state.copyWith(
          isLoading: false,
          status: AuthStatus.unauthenticated,
          errorMessage: 'check_email_confirm',
        );
      } else {
        state = state.copyWith(isLoading: false);
      }
    } on AuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyAuthError(e.message),
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: S.get('err_network'),
      );
    }
  }

  Future<bool> resetPassword(String email) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await SupabaseConfig.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'com.agrikd.app://callback',
      );
      state = state.copyWith(isLoading: false);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyAuthError(e.message),
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: S.get('err_network'),
      );
      return false;
    }
  }

  Future<bool> updatePassword(String newPassword) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await SupabaseConfig.client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.authenticated,
      );
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyAuthError(e.message),
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: S.get('err_network'),
      );
      return false;
    }
  }

  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final webClientId = EnvConfig.googleWebClientId;
      if (webClientId.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: S.get('err_google_not_available'),
        );
        return;
      }

      _googleSignIn ??= GoogleSignIn(serverClientId: webClientId);
      final googleUser = await _googleSignIn!.signIn();
      if (googleUser == null) {
        // User cancelled the sign-in flow
        state = state.copyWith(isLoading: false);
        return;
      }

      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: S.get('err_google_signin_failed'),
        );
        return;
      }

      await SupabaseConfig.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      // onAuthStateChange listener handles the state update; clear loading
      state = state.copyWith(isLoading: false);
    } on AuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: _friendlyAuthError(e.message),
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: S.get('err_google_signin_failed'),
      );
    }
  }

  Future<void> signOut() async {
    try {
      await SupabaseConfig.client.auth.signOut();
    } catch (_) {
      // Supabase may fail if offline — still clear local state
    }
    await _clearLocalUserData();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<void> _clearLocalUserData() async {
    try {
      final db = await AppDatabase.database;
      await db.delete('sync_queue');
    } catch (_) {
      // Best-effort cleanup
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
