import 'package:sqflite/sqflite.dart';

import '../models/learning_record.dart';

/// [v0.1.0] 学习记录（LearningRecord）数据访问。

class LearningRecordDao {
  LearningRecordDao(this.db);

  final Database db;

  static const _table = 'learning_records';

  /// 插入记录，返回 id。
  Future<String> insert(LearningRecord record) async {
    await db.insert(
      _table,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return record.id;
  }

  /// 按类型取记录（时间倒序）。
  Future<List<LearningRecord>> getByType(
    LearningType type, {
    int limit = 100,
  }) async {
    final rows = await db.query(
      _table,
      where: 'type = ?',
      whereArgs: [type.name],
      orderBy: 'at DESC',
      limit: limit,
    );
    return rows.map(LearningRecord.fromMap).toList();
  }

  /// 最近记录（时间倒序）。
  Future<List<LearningRecord>> getRecent({int limit = 100}) async {
    final rows = await db.query(_table, orderBy: 'at DESC', limit: limit);
    return rows.map(LearningRecord.fromMap).toList();
  }

  /// 某类型记录数。
  Future<int> countByType(LearningType type) async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_table WHERE type = ?', [
          type.name,
        ]),
      ) ??
      0;

  /// 某类型平均得分（0-100），无记录返回 0。
  Future<double> avgResultByType(LearningType type) async {
    final rows = await db.rawQuery(
      'SELECT AVG(result) AS avg_result FROM $_table WHERE type = ?',
      [type.name],
    );
    if (rows.isEmpty || rows.first['avg_result'] == null) return 0;
    return (rows.first['avg_result'] as num).toDouble();
  }

  /// 删除。
  Future<int> delete(String id) =>
      db.delete(_table, where: 'id = ?', whereArgs: [id]);
}
