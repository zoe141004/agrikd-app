import 'package:sqflite/sqflite.dart';

import '../app_database.dart';

class PreferenceDao {
  Future<Database> get _db => AppDatabase.database;

  Future<String?> getValue(String key) async {
    final db = await _db;
    final results = await db.query(
      'user_preferences',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first['value'] as String;
  }

  Future<void> setValue(String key, String value) async {
    final db = await _db;
    await db.insert('user_preferences', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getAllPreferences() async {
    final db = await _db;
    final results = await db.query('user_preferences');
    return {
      for (final row in results) row['key'] as String: row['value'] as String,
    };
  }
}
