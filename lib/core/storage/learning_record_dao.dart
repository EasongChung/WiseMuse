import 'package:sqflite/sqflite.dart';

import '../models/learning_record.dart';

/// [v0.1.0] 学习记录（LearningRecord）数据访问。
/// [v2.9.0] 多孩子模式：构造传入 [profileId]，null=不过滤（家长模式）。

class LearningRecordDao {
  LearningRecordDao(this.db, {this.profileId});

  final Database db;
  final String? profileId;

  static const _table = 'learning_records';

  /// 插入记录，自动关联 profileId。
  Future<String> insert(LearningRecord record) async {
    final map = record.toMap();
    if (profileId != null) map['profile_id'] = profileId;
    await db.insert(_table, map, conflictAlgorithm: ConflictAlgorithm.replace);
    return record.id;
  }

  /// 按类型取记录（时间倒序，当前孩子的）。
  Future<List<LearningRecord>> getByType(
    LearningType type, {
    int limit = 100,
  }) async {
    final (where, args) =
        profileId != null
            ? (
              'profile_id = ? AND type = ?',
              [profileId, type.name] as List<dynamic>,
            )
            : ('type = ?', [type.name] as List<dynamic>);
    final rows = await db.query(
      _table,
      where: where,
      whereArgs: args,
      orderBy: 'at DESC',
      limit: limit,
    );
    return rows.map(LearningRecord.fromMap).toList();
  }

  /// 最近记录（时间倒序，当前孩子的）。
  Future<List<LearningRecord>> getRecent({int limit = 100}) async {
    final rows =
        profileId != null
            ? await db.query(
              _table,
              where: 'profile_id = ?',
              whereArgs: [profileId],
              orderBy: 'at DESC',
              limit: limit,
            )
            : await db.query(_table, orderBy: 'at DESC', limit: limit);
    return rows.map(LearningRecord.fromMap).toList();
  }

  /// 某类型记录数（当前孩子的）。
  Future<int> countByType(LearningType type) async {
    final sql =
        profileId != null
            ? 'SELECT COUNT(*) FROM $_table WHERE profile_id = ? AND type = ?'
            : 'SELECT COUNT(*) FROM $_table WHERE type = ?';
    final args = profileId != null ? [profileId, type.name] : [type.name];
    return Sqflite.firstIntValue(await db.rawQuery(sql, args)) ?? 0;
  }

  /// 某类型平均得分（0-100，当前孩子的）。
  Future<double> avgResultByType(LearningType type) async {
    final sql =
        profileId != null
            ? 'SELECT AVG(result) AS avg_result FROM $_table WHERE profile_id = ? AND type = ?'
            : 'SELECT AVG(result) AS avg_result FROM $_table WHERE type = ?';
    final args = profileId != null ? [profileId, type.name] : [type.name];
    final rows = await db.rawQuery(sql, args);
    if (rows.isEmpty || rows.first['avg_result'] == null) return 0;
    return (rows.first['avg_result'] as num).toDouble();
  }

  /// 删除。
  Future<int> delete(String id) =>
      db.delete(_table, where: 'id = ?', whereArgs: [id]);
}
