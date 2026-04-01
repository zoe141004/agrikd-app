import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  // Provided at build time via --dart-define-from-file=.env
  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static bool _initialized = false;

  static String get url => _url;
  static String get anonKey => _anonKey;
  static bool get isInitialized => _initialized;

  static SupabaseClient get client {
    if (!_initialized) {
      throw StateError(
        'Supabase not initialized. Check network or .env config.',
      );
    }
    return Supabase.instance.client;
  }

  static Future<void> initialize() async {
    if (_url.isEmpty || _anonKey.isEmpty) {
      throw StateError(
        'Supabase credentials not provided. '
        'Build with: flutter run --dart-define-from-file=.env',
      );
    }
    await Supabase.initialize(
      url: _url,
      anonKey: _anonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    _initialized = true;
  }
}
