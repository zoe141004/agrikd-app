import 'package:sqflite/sqflite.dart';

import '../app_database.dart';

class PredictionDao {
  Future<Database> get _db => AppDatabase.database;

  Future<int> insert(Map<String, dynamic> prediction) async {
    final db = await _db;
    return db.insert('predictions', prediction);
  }

  Future<List<Map<String, dynamic>>> getAll({
    int limit = 20,
    int offset = 0,
    String? leafType,
    String? startDate,
    String? endDate,
    double? minConfidence,
    String? searchQuery,
    String? orderBy,
  }) async {
    final db = await _db;
    final where = <String>[];
    final whereArgs = <dynamic>[];

    if (leafType != null) {
      where.add('leaf_type = ?');
      whereArgs.add(leafType);
    }
    if (startDate != null) {
      where.add('created_at >= ?');
      whereArgs.add(startDate);
    }
    if (endDate != null) {
      where.add('created_at <= ?');
      whereArgs.add(endDate);
    }
    if (minConfidence != null) {
      where.add('confidence >= ?');
      whereArgs.add(minConfidence);
    }
    if (searchQuery != null && searchQuery.isNotEmpty) {
      where.add('(predicted_class_name LIKE ? OR notes LIKE ?)');
      final pattern = '%$searchQuery%';
      whereArgs.addAll([pattern, pattern]);
    }

    return db.query(
      'predictions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: orderBy ?? 'created_at DESC',
      limit: limit,
      offset: offset,
    );
  }

  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await _db;
    final results = await db.query(
      'predictions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  Future<List<Map<String, dynamic>>> getUnsynced() async {
    final db = await _db;
    return db.query(
      'predictions',
      where: 'is_synced = 0',
      orderBy: 'created_at ASC',
    );
  }

  Future<int> markSynced(int id, String serverId) async {
    final db = await _db;
    return db.update(
      'predictions',
      {
        'is_synced': 1,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
        'server_id': serverId,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updateNotes(int id, String notes) async {
    final db = await _db;
    return db.update(
      'predictions',
      {'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _db;
    return db.delete('predictions', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>> getStatistics({String? leafType}) async {
    final db = await _db;
    final whereClause = leafType != null ? 'WHERE leaf_type = ?' : '';
    final whereArgs = leafType != null ? [leafType] : <dynamic>[];

    final total =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM predictions $whereClause',
            whereArgs,
          ),
        ) ??
        0;

    final synced =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM predictions $whereClause ${whereClause.isEmpty ? "WHERE" : "AND"} is_synced = 1',
            whereArgs,
          ),
        ) ??
        0;

    return {'total': total, 'synced': synced, 'unsynced': total - synced};
  }

  Future<Map<String, dynamic>> getDetailedStatistics() async {
    final db = await _db;

    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM predictions'),
        ) ??
        0;

    final synced =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM predictions WHERE is_synced = 1',
          ),
        ) ??
        0;

    final byLeafType = await db.rawQuery(
      'SELECT leaf_type, COUNT(*) as count FROM predictions GROUP BY leaf_type ORDER BY count DESC',
    );

    final topDiseases = await db.rawQuery(
      'SELECT predicted_class_name, leaf_type, COUNT(*) as count FROM predictions '
      'GROUP BY predicted_class_name, leaf_type ORDER BY count DESC LIMIT 5',
    );

    final sevenDaysAgo = DateTime.now()
        .subtract(const Duration(days: 7))
        .toUtc()
        .toIso8601String();
    final dailyScans = await db.rawQuery(
      "SELECT DATE(created_at) as date, COUNT(*) as count FROM predictions "
      "WHERE created_at >= ? GROUP BY DATE(created_at) ORDER BY date ASC",
      [sevenDaysAgo],
    );

    return {
      'total': total,
      'synced': synced,
      'unsynced': total - synced,
      'by_leaf_type': byLeafType,
      'top_diseases': topDiseases,
      'daily_scans': dailyScans,
    };
  }
}
