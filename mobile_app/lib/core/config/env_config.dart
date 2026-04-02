import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Hybrid environment config for production-ready credential management.
///
/// Priority: `--dart-define` (compile-time, CI/CD) > `dotenv` (runtime, local dev).
///
/// In production builds, secrets are injected via `--dart-define` flags and the
/// `.env` file is stripped from the APK. In local development, `.env` is loaded
/// via `flutter_dotenv` as an asset for convenience.
class EnvConfig {
  // Compile-time values from --dart-define (empty string if not provided)
  static const _kUrl = String.fromEnvironment('SUPABASE_URL');
  static const _kAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _kGoogleClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const _kSentryDsn = String.fromEnvironment('SENTRY_DSN');

  /// Supabase project URL.
  static String get supabaseUrl =>
      _kUrl.isNotEmpty ? _kUrl : (dotenv.env['SUPABASE_URL'] ?? '');

  /// Supabase anonymous (publishable) key.
  static String get supabaseAnonKey => _kAnonKey.isNotEmpty
      ? _kAnonKey
      : (dotenv.env['SUPABASE_ANON_KEY'] ?? '');

  /// Google OAuth Web Client ID for Google Sign-In.
  static String get googleWebClientId => _kGoogleClientId.isNotEmpty
      ? _kGoogleClientId
      : (dotenv.env['GOOGLE_WEB_CLIENT_ID'] ?? '');

  /// Sentry DSN for error tracking.
  static String get sentryDsn =>
      _kSentryDsn.isNotEmpty ? _kSentryDsn : (dotenv.env['SENTRY_DSN'] ?? '');
}
