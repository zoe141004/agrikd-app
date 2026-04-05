import 'dart:io' show File;

import 'package:sqflite/sqflite.dart';

import '../app_database.dart';

class ModelDao {
  Future<Database> get _db => AppDatabase.database;

  Future<int> insert(Map<String, dynamic> model) async {
    final db = await _db;
    return db.insert(
      'models',
      model,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get the selected (currently used for inference) model for a leaf type.
  Future<Map<String, dynamic>?> getSelected(String leafType) async {
    final db = await _db;
    final results = await db.query(
      'models',
      where: "leaf_type = ? AND is_selected = 1",
      whereArgs: [leafType],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// Get all active models for a leaf type (up to 2).
  Future<List<Map<String, dynamic>>> getActiveVersions(String leafType) async {
    final db = await _db;
    return db.query(
      'models',
      where: "leaf_type = ? AND role = 'active'",
      whereArgs: [leafType],
      orderBy: "updated_at DESC",
    );
  }

  /// Get the fallback model for a leaf type.
  Future<Map<String, dynamic>?> getFallback(String leafType) async {
    final db = await _db;
    final results = await db.query(
      'models',
      where: "leaf_type = ? AND role = 'fallback'",
      whereArgs: [leafType],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  Future<List<Map<String, dynamic>>> getAll() async {
    final db = await _db;
    return db.query('models', orderBy: 'leaf_type ASC, role ASC');
  }

  /// Add a new active version via OTA. Manages the 2-active-version rotation:
  /// 1. If already 2 active versions, delete the oldest (+ file on disk)
  /// 2. Deselect all versions for this leaf type
  /// 3. Insert new version as active + selected
  Future<void> promoteNewVersion({
    required String leafType,
    required String version,
    required String filePath,
    required String checksum,
    required int numClasses,
    required String classLabels,
  }) async {
    final db = await _db;
    final filesToDelete = <String>[];

    await db.transaction((txn) async {
      // 1. Get current active versions
      final actives = await txn.query(
        'models',
        where: "leaf_type = ? AND role = 'active'",
        whereArgs: [leafType],
        orderBy: "updated_at ASC",
      );

      // 2. If already 2 active, delete the oldest
      if (actives.length >= 2) {
        final oldest = actives.first;
        final path = oldest['file_path'] as String?;
        if (path != null && (oldest['is_bundled'] as int) == 0) {
          filesToDelete.add(path);
        }
        await txn.delete('models', where: "id = ?", whereArgs: [oldest['id']]);
      }

      // 3. Deselect all versions for this leaf type
      await txn.update(
        'models',
        {'is_selected': 0},
        where: "leaf_type = ?",
        whereArgs: [leafType],
      );

      // 4. Insert new version as active + selected
      await txn.insert('models', {
        'leaf_type': leafType,
        'version': version,
        'file_path': filePath,
        'sha256_checksum': checksum,
        'num_classes': numClasses,
        'class_labels': classLabels,
        'is_bundled': 0,
        'is_active': 1,
        'role': 'active',
        'is_selected': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    });

    // Delete files AFTER transaction commits successfully
    for (final path in filesToDelete) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Remove a version and select the remaining active version (if any).
  /// Returns true if a remaining version was selected.
  Future<bool> removeVersion(String leafType, String version) async {
    final db = await _db;
    final filesToDelete = <String>[];

    final success = await db.transaction((txn) async {
      // Collect files for deletion
      final rows = await txn.query(
        'models',
        where: "leaf_type = ? AND version = ?",
        whereArgs: [leafType, version],
      );
      for (final row in rows) {
        if ((row['is_bundled'] as int) == 0) {
          final path = row['file_path'] as String?;
          if (path != null) filesToDelete.add(path);
        }
      }

      // Delete the version
      await txn.delete(
        'models',
        where: "leaf_type = ? AND version = ?",
        whereArgs: [leafType, version],
      );

      // Select the remaining active version (if any)
      final remaining = await txn.query(
        'models',
        where: "leaf_type = ? AND role = 'active'",
        whereArgs: [leafType],
        orderBy: "updated_at DESC",
        limit: 1,
      );

      if (remaining.isNotEmpty) {
        await txn.update(
          'models',
          {'is_selected': 1},
          where: "id = ?",
          whereArgs: [remaining.first['id']],
        );
        return true;
      }
      return false;
    });

    for (final path in filesToDelete) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return success;
  }

  /// Select a specific version as the active inference model.
  Future<void> selectVersion(String leafType, String version) async {
    final db = await _db;
    await db.transaction((txn) async {
      // Verify the target version exists before deselecting
      final exists = await txn.query(
        'models',
        where: "leaf_type = ? AND version = ?",
        whereArgs: [leafType, version],
      );
      if (exists.isEmpty) return;

      // Deselect all for this leaf type
      await txn.update(
        'models',
        {'is_selected': 0},
        where: "leaf_type = ?",
        whereArgs: [leafType],
      );
      // Select the requested version
      await txn.update(
        'models',
        {'is_selected': 1},
        where: "leaf_type = ? AND version = ?",
        whereArgs: [leafType, version],
      );
    });
  }

  /// Get all models for a leaf type (active + fallback).
  Future<List<Map<String, dynamic>>> getByLeafType(String leafType) async {
    final db = await _db;
    return db.query(
      'models',
      where: 'leaf_type = ?',
      whereArgs: [leafType],
      orderBy:
          "CASE role WHEN 'active' THEN 0 WHEN 'fallback' THEN 1 ELSE 2 END",
    );
  }

  Future<void> seedBundledModels(
    List<Map<String, dynamic>> bundledModels,
  ) async {
    final db = await _db;
    final batch = db.batch();
    for (final model in bundledModels) {
      batch.insert('models', {
        ...model,
        'role': 'active',
        'is_selected': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }
}
