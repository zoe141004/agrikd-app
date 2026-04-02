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

  /// Get the active model for a leaf type.
  Future<Map<String, dynamic>?> getActive(String leafType) async {
    final db = await _db;
    final results = await db.query(
      'models',
      where: "leaf_type = ? AND is_active = 1 AND role = 'active'",
      whereArgs: [leafType],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
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

  /// Promote a new OTA model version. Manages the 2-version rotation:
  /// 1. Delete any archived model (+ file on disk)
  /// 2. Demote current active → fallback
  /// 3. Insert new version as active
  Future<void> promoteNewVersion({
    required String leafType,
    required String version,
    required String filePath,
    required String checksum,
    required int numClasses,
    required String classLabels,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      // 1. Delete archived models + their files
      final archived = await txn.query(
        'models',
        where: "leaf_type = ? AND role = 'archived'",
        whereArgs: [leafType],
      );
      for (final row in archived) {
        final path = row['file_path'] as String?;
        if (path != null && (row['is_bundled'] as int) == 0) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
      await txn.delete(
        'models',
        where: "leaf_type = ? AND role = 'archived'",
        whereArgs: [leafType],
      );

      // 2. Demote current fallback → archived (delete file + row)
      final fallback = await txn.query(
        'models',
        where: "leaf_type = ? AND role = 'fallback'",
        whereArgs: [leafType],
      );
      for (final row in fallback) {
        final path = row['file_path'] as String?;
        if (path != null && (row['is_bundled'] as int) == 0) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
      await txn.delete(
        'models',
        where: "leaf_type = ? AND role = 'fallback'",
        whereArgs: [leafType],
      );

      // 3. Demote current active → fallback
      await txn.update(
        'models',
        {'role': 'fallback'},
        where: "leaf_type = ? AND role = 'active'",
        whereArgs: [leafType],
      );

      // 4. Insert new version as active
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
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  /// Rollback: delete current active OTA model, promote fallback → active.
  /// Returns true if rollback succeeded (had a fallback to promote).
  Future<bool> rollbackToFallback(String leafType) async {
    final db = await _db;
    return await db.transaction((txn) async {
      // Delete current active (if OTA, delete file too)
      final active = await txn.query(
        'models',
        where: "leaf_type = ? AND role = 'active'",
        whereArgs: [leafType],
      );
      for (final row in active) {
        if ((row['is_bundled'] as int) == 0) {
          try {
            await File(row['file_path'] as String).delete();
          } catch (_) {}
        }
      }
      await txn.delete(
        'models',
        where: "leaf_type = ? AND role = 'active' AND is_bundled = 0",
        whereArgs: [leafType],
      );

      // Promote fallback → active
      final updated = await txn.update(
        'models',
        {'role': 'active', 'is_active': 1},
        where: "leaf_type = ? AND role = 'fallback'",
        whereArgs: [leafType],
      );
      return updated > 0;
    });
  }

  /// Swap active ↔ fallback for a leaf type (user manual switch).
  /// Uses 'archived' as a valid intermediate role to satisfy the CHECK
  /// constraint (role IN ('active', 'fallback', 'archived')) while avoiding
  /// the UNIQUE(leaf_type, role) conflict during the swap.
  Future<void> switchRole(String leafType) async {
    final db = await _db;
    await db.transaction((txn) async {
      // 1. Temporarily park current active → 'archived'
      await txn.rawUpdate(
        "UPDATE models SET role = 'archived' "
        "WHERE leaf_type = ? AND role = 'active'",
        [leafType],
      );
      // 2. Promote fallback → active
      await txn.rawUpdate(
        "UPDATE models SET role = 'active' "
        "WHERE leaf_type = ? AND role = 'fallback'",
        [leafType],
      );
      // 3. Move archived (was active) → fallback
      await txn.rawUpdate(
        "UPDATE models SET role = 'fallback' "
        "WHERE leaf_type = ? AND role = 'archived'",
        [leafType],
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
      orderBy: "CASE role WHEN 'active' THEN 0 WHEN 'fallback' THEN 1 ELSE 2 END",
    );
  }

  Future<void> seedBundledModels(
    List<Map<String, dynamic>> bundledModels,
  ) async {
    final db = await _db;
    final batch = db.batch();
    for (final model in bundledModels) {
      batch.insert(
        'models',
        {...model, 'role': 'active'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }
}
