import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env_config.dart';

class SupabaseConfig {
  static bool _initialized = false;

  static String get url => EnvConfig.supabaseUrl;
  static String get anonKey => EnvConfig.supabaseAnonKey;
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
    if (_initialized) return;
    if (url.isEmpty || anonKey.isEmpty) {
      throw StateError(
        'Supabase credentials not provided. '
        'Add them to .env (local dev) or use --dart-define (CI/CD).',
      );
    }
    await Supabase.initialize(
      url: url,
      anonKey: anonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    _initialized = true;
  }

  /// Retry initialization after an offline cold start.
  /// Returns true if initialization succeeded (or was already initialized).
  static Future<bool> ensureInitialized() async {
    if (_initialized) return true;
    try {
      await initialize();
      return true;
    } catch (e) {
      debugPrint('[SupabaseConfig] ensureInitialized failed: $e');
      return false;
    }
  }
}
