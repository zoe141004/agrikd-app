import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'db_factory_stub.dart'
    if (dart.library.html) 'db_factory_web.dart'
    as db_setup;

class AppDatabase {
  static Future<Database>? _dbFuture;
  static const int _version = 1;
  static const String _dbName = 'agrikd.db';

  /// When true, use in-memory DB (for tests).
  @visibleForTesting
  static bool useInMemory = false;

  AppDatabase._();

  static Future<void> initWebFactory() async {
    db_setup.initFactory();
  }

  static Future<Database> get database {
    _dbFuture ??= _initDb();
    return _dbFuture!;
  }

  /// Reset the singleton for testing. After calling this, the next access
  /// to [database] will create a fresh database instance.
  @visibleForTesting
  static Future<void> resetForTest() async {
    if (_dbFuture != null) {
      final db = await _dbFuture!;
      await db.close();
      _dbFuture = null;
    }
  }

  static Future<Database> _initDb() async {
    if (kIsWeb || useInMemory) {
      return openDatabase(
        inMemoryDatabasePath,
        version: _version,
        onCreate: _onCreate,
      );
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // Future migrations go here:
    // if (oldVersion < 2) { ... }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE predictions (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        image_path            TEXT NOT NULL,
        leaf_type             TEXT NOT NULL,
        model_version         TEXT NOT NULL,
        predicted_class_index INTEGER NOT NULL,
        predicted_class_name  TEXT NOT NULL,
        confidence            REAL NOT NULL,
        all_confidences       TEXT,
        inference_time_ms     REAL,
        latitude              REAL,
        longitude             REAL,
        notes                 TEXT,
        created_at            TEXT NOT NULL DEFAULT (datetime('now')),
        is_synced             INTEGER NOT NULL DEFAULT 0,
        synced_at             TEXT,
        server_id             TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_predictions_leaf_type ON predictions(leaf_type)',
    );
    await db.execute(
      'CREATE INDEX idx_predictions_created_at ON predictions(created_at)',
    );
    await db.execute(
      'CREATE INDEX idx_predictions_is_synced ON predictions(is_synced)',
    );

    await db.execute('''
      CREATE TABLE models (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        leaf_type       TEXT NOT NULL UNIQUE,
        version         TEXT NOT NULL,
        file_path       TEXT NOT NULL,
        sha256_checksum TEXT NOT NULL,
        num_classes     INTEGER NOT NULL,
        class_labels    TEXT NOT NULL,
        accuracy_top1   REAL,
        is_bundled      INTEGER NOT NULL DEFAULT 1,
        is_active       INTEGER NOT NULL DEFAULT 1,
        updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE user_preferences (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.insert('user_preferences', {
      'key': 'default_leaf_type',
      'value': 'tomato',
    });
    await db.insert('user_preferences', {'key': 'auto_sync', 'value': 'true'});
    await db.insert('user_preferences', {'key': 'theme', 'value': 'system'});
    await db.insert('user_preferences', {
      'key': 'save_images',
      'value': 'true',
    });
    await db.insert('user_preferences', {'key': 'language', 'value': 'en'});

    await db.execute('''
      CREATE TABLE sync_queue (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type   TEXT NOT NULL,
        entity_id     INTEGER NOT NULL,
        action        TEXT NOT NULL,
        payload       TEXT,
        retry_count   INTEGER NOT NULL DEFAULT 0,
        max_retries   INTEGER NOT NULL DEFAULT 3,
        status        TEXT NOT NULL DEFAULT 'pending',
        created_at    TEXT NOT NULL DEFAULT (datetime('now')),
        completed_at  TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_sync_queue_status ON sync_queue(status)',
    );
  }
}
