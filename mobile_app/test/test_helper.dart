// Shared test helpers for AgriKD tests.
// Call [initTestDatabase] in setUpAll() for any test that needs SQLite.
// This uses databaseFactoryFfiNoIsolate to avoid file locking between test files.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:app/data/database/app_database.dart';

void initTestDatabase() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  AppDatabase.useInMemory = true;
}

/// Reset the AppDatabase singleton so each test group gets a fresh DB.
Future<void> resetTestDatabase() async {
  await AppDatabase.resetForTest();
}
