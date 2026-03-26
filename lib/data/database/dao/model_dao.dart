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

  Future<Map<String, dynamic>?> getActive(String leafType) async {
    final db = await _db;
    final results = await db.query(
      'models',
      where: 'leaf_type = ? AND is_active = 1',
      whereArgs: [leafType],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  Future<List<Map<String, dynamic>>> getAll() async {
    final db = await _db;
    return db.query('models', orderBy: 'leaf_type ASC');
  }

  Future<int> updateVersion(
    String leafType,
    String version,
    String filePath,
    String checksum,
  ) async {
    final db = await _db;
    return db.update(
      'models',
      {
        'version': version,
        'file_path': filePath,
        'sha256_checksum': checksum,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'leaf_type = ?',
      whereArgs: [leafType],
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
        model,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }
}
