import 'package:sqflite/sqflite.dart';

import '../models/profile.dart';

/// [v0.1.35] 孩子/家长档案数据访问。
class ProfileDao {
  ProfileDao(this.db);

  final Database db;

  static const _table = 'profiles';

  /// 插入档案。
  Future<String> insert(Profile p) async {
    await db.insert(
      _table,
      p.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return p.id;
  }

  /// 按 ID 查单条。
  Future<Profile?> getById(String id) async {
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Profile.fromMap(rows.first);
  }

  /// 取全部档案（按创建时间升序）。
  Future<List<Profile>> getAll() async {
    final rows = await db.query(_table, orderBy: 'created_at ASC');
    return rows.map(Profile.fromMap).toList();
  }

  /// 更新档案。
  Future<int> update(Profile p) =>
      db.update(_table, p.toMap(), where: 'id = ?', whereArgs: [p.id]);

  /// 删除档案。
  Future<int> delete(String id) =>
      db.delete(_table, where: 'id = ?', whereArgs: [id]);

  /// 档案总数。
  Future<int> count() async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_table'),
      ) ??
      0;
}
