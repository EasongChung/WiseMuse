import 'package:sqflite/sqflite.dart';

import '../models/quiz_attempt.dart';

/// [v0.3.0] 测验结果（QuizAttempt）数据访问。
class QuizAttemptDao {
  QuizAttemptDao(this.db);

  final Database db;

  static const _table = 'quiz_attempts';

  /// 插入测验记录，返回 id。
  Future<String> insert(QuizAttempt attempt) async {
    await db.insert(
      _table,
      attempt.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return attempt.id;
  }

  /// 某书某章测验记录（时间倒序）。
  Future<List<QuizAttempt>> getByChapter(
    String bookId,
    int chapter, {
    int? limit,
  }) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ? AND chapter = ?',
      whereArgs: [bookId, chapter],
      orderBy: 'at DESC',
      limit: limit,
    );
    return rows.map(QuizAttempt.fromMap).toList();
  }

  /// 某书全部测验记录（时间倒序）。
  Future<List<QuizAttempt>> getByBook(String bookId) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'at DESC',
    );
    return rows.map(QuizAttempt.fromMap).toList();
  }

  /// 某书某章最佳得分（总分最高的一条），无记录返回 null。
  Future<QuizAttempt?> bestByChapter(String bookId, int chapter) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ? AND chapter = ?',
      whereArgs: [bookId, chapter],
      orderBy: 'total_score DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : QuizAttempt.fromMap(rows.first);
  }

  /// 某书某章测验次数。
  Future<int> countByChapter(String bookId, int chapter) async =>
      Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM $_table WHERE book_id = ? AND chapter = ?',
          [bookId, chapter],
        ),
      ) ??
      0;

  /// 按书删除（级联）。
  Future<int> deleteByBook(String bookId) =>
      db.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);
}
