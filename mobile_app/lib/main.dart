import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'core/config/supabase_config.dart';
import 'core/constants/model_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/model_integrity.dart';
import 'data/database/app_database.dart';
import 'data/database/dao/model_dao.dart';
import 'features/auth/presentation/screens/reset_password_screen.dart';
import 'features/diagnosis/presentation/screens/home_screen.dart';
import 'providers/auth_provider.dart';
import 'providers/diagnosis_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/sync_provider.dart';

/// Global key for showing snackbars from anywhere (e.g., error boundary).
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

bool _showOfflineNotification = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global error boundary: catch Flutter framework errors
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  // Catch errors not handled by Flutter framework (async, platform, etc.)
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    return true;
  };

  // 0. Initialize web database factory if on web
  if (kIsWeb) {
    await _initWebDb();
  }

  // 1. Initialize database (creates tables + seeds default preferences)
  await AppDatabase.database;

  // 2. Initialize Supabase in background (non-blocking: app works offline)
  SupabaseConfig.initialize().catchError((_) {
    _showOfflineNotification = true;
  });

  // 3. Seed bundled models + load settings in parallel (both need DB, independent of each other)
  final container = ProviderContainer();
  await Future.wait([
    _seedBundledModels(),
    container.read(settingsProvider.notifier).loadAll(),
  ]);

  // 4. Apply default_leaf_type from settings
  final defaultLeaf = container.read(settingsProvider)['default_leaf_type'];
  if (defaultLeaf != null && defaultLeaf.isNotEmpty) {
    container.read(selectedLeafTypeProvider.notifier).state = defaultLeaf;
  }

  runApp(
    UncontrolledProviderScope(container: container, child: const AgriKDApp()),
  );
}

Future<void> _initWebDb() async {
  // Import is handled via sqflite_common_ffi_web setup
  // The package auto-registers itself when imported
  await AppDatabase.initWebFactory();
}

Future<void> _seedBundledModels() async {
  final modelDao = ModelDao();

  // Fast path: skip if models already seeded (avoids ~2MB rootBundle + SHA-256)
  final existing = await modelDao.getAll();
  if (existing.length >= ModelConstants.models.length) return;

  final models = <Map<String, dynamic>>[];

  for (final entry in ModelConstants.models.entries) {
    final info = entry.value;

    // On web, skip SHA-256 checksum (asset loading for hashing not reliable)
    String checksum = '';
    if (!kIsWeb) {
      checksum = await ModelIntegrity.sha256Asset(info.assetPath);
    }

    models.add({
      'leaf_type': info.leafType,
      'version': '1.0.0',
      'file_path': info.assetPath,
      'sha256_checksum': checksum,
      'num_classes': info.numClasses,
      'class_labels': jsonEncode(info.classLabels),
      'is_bundled': 1,
      'is_active': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  await modelDao.seedBundledModels(models);
}

class AgriKDApp extends ConsumerStatefulWidget {
  const AgriKDApp({super.key});

  @override
  ConsumerState<AgriKDApp> createState() => _AgriKDAppState();
}

class _AgriKDAppState extends ConsumerState<AgriKDApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (_showOfflineNotification) {
      _showOfflineNotification = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(S.get('offline_mode')),
            duration: const Duration(seconds: 4),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    // Watch settings to rebuild when language changes
    final settings = ref.watch(settingsProvider);
    final lang = settings['language'] ?? 'en';
    S.setLocale(lang);

    // Eagerly instantiate syncProvider so auto-sync listeners activate
    ref.watch(syncProvider);

    // Navigate to ResetPasswordScreen when password recovery deep link is opened
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.passwordRecovery &&
          previous?.status != AuthStatus.passwordRecovery) {
        _navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
        );
      }
    });

    return MaterialApp(
      key: ValueKey(lang),
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'AgriKD',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: const HomeScreen(),
    );
  }
}
