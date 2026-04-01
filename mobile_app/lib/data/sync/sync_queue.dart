import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

class SyncQueue {
  Future<Database> get _db => AppDatabase.database;

  Future<int> enqueue({
    required String entityType,
    required int entityId,
    required String action,
    String? payload,
  }) async {
    final db = await _db;
    return db.insert('sync_queue', {
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'payload': payload,
      'status': 'pending',
    });
  }

  Future<List<Map<String, dynamic>>> getPending({int limit = 50}) async {
    final db = await _db;
    return db.query(
      'sync_queue',
      where: 'status = ? AND retry_count < max_retries',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> markCompleted(int id) async {
    final db = await _db;
    await db.update(
      'sync_queue',
      {
        'status': 'completed',
        'completed_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id) async {
    final db = await _db;
    await db.update(
      'sync_queue',
      {'status': 'failed'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> incrementRetry(int id) async {
    final db = await _db;
    await db.rawUpdate(
      'UPDATE sync_queue SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  /// Remove completed entries older than [age] and permanently failed entries.
  Future<int> cleanup({Duration age = const Duration(days: 7)}) async {
    final db = await _db;
    final cutoff = DateTime.now().subtract(age).toUtc().toIso8601String();
    return db.delete(
      'sync_queue',
      where: "(status = 'completed' AND completed_at < ?) OR status = 'failed'",
      whereArgs: [cutoff],
    );
  }
}
