import 'package:sqflite/sqflite.dart';

import '../models/word_entry.dart';

/// [v0.1.0] 生词本（WordEntry）数据访问。
/// [v0.1.35] 多孩子：构造传入 [profileId]，null=不过滤（家长模式）。

class WordEntryDao {
  WordEntryDao(this.db, {this.profileId});

  final Database db;
  final String? profileId;

  static const _table = 'word_entries';

  /// 插入生词；若同一词已存在则更新（幂等，去重按 word+lang）。
  /// 自动关联当前 profileId。
  Future<String> upsert(WordEntry entry) async {
    final existing = await findByWord(entry.word, lang: entry.lang);
    if (existing != null) {
      final data = entry.toMap()..['id'] = existing.id;
      if (profileId != null) data['profile_id'] = profileId;
      await db.update(_table, data, where: 'id = ?', whereArgs: [existing.id]);
      return existing.id;
    }
    final data = entry.toMap();
    if (profileId != null) data['profile_id'] = profileId;
    await db.insert(_table, data, conflictAlgorithm: ConflictAlgorithm.replace);
    return entry.id;
  }

  /// 按词 + 语言查单个。
  Future<WordEntry?> findByWord(String word, {String? lang}) async {
    final rows = await db.query(
      _table,
      where: lang == null ? 'word = ?' : 'word = ? AND lang = ?',
      whereArgs: lang == null ? [word] : [word, lang],
      limit: 1,
    );
    return rows.isEmpty ? null : WordEntry.fromMap(rows.first);
  }

  /// 取全部（按掌握度升序 → 未掌握优先，当前孩子的）。
  Future<List<WordEntry>> getAll() async {
    final rows =
        profileId != null
            ? await db.query(
              _table,
              where: 'profile_id = ?',
              whereArgs: [profileId],
              orderBy: 'mastery ASC, added_at DESC',
            )
            : await db.query(_table, orderBy: 'mastery ASC, added_at DESC');
    return rows.map(WordEntry.fromMap).toList();
  }

  /// 按教材取生词。
  Future<List<WordEntry>> getByBook(String bookId) async {
    final rows = await db.query(
      _table,
      where: 'from_book_id = ?',
      whereArgs: [bookId],
      orderBy: 'added_at DESC',
    );
    return rows.map(WordEntry.fromMap).toList();
  }

  /// 未掌握词（mastery < [threshold]），复习优先。
  Future<List<WordEntry>> getUnmastered({int threshold = 3}) async {
    final where =
        profileId != null ? 'profile_id = ? AND mastery < ?' : 'mastery < ?';
    final args = profileId != null ? [profileId, threshold] : [threshold];
    final rows = await db.query(
      _table,
      where: where,
      whereArgs: args,
      orderBy: 'mastery ASC, wrong_count DESC',
    );
    return rows.map(WordEntry.fromMap).toList();
  }

  /// 更新（掌握度/错误次数/复习时间）。
  Future<int> update(WordEntry entry) =>
      db.update(_table, entry.toMap(), where: 'id = ?', whereArgs: [entry.id]);

  /// 删除。
  Future<int> delete(String id) =>
      db.delete(_table, where: 'id = ?', whereArgs: [id]);

  /// 生词总数（当前孩子的）。
  Future<int> count() async {
    final sql =
        profileId != null
            ? 'SELECT COUNT(*) FROM $_table WHERE profile_id = ?'
            : 'SELECT COUNT(*) FROM $_table';
    final args = profileId != null ? [profileId] : null;
    return Sqflite.firstIntValue(await db.rawQuery(sql, args)) ?? 0;
  }
}
