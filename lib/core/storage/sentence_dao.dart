import 'package:sqflite/sqflite.dart';

import '../models/sentence.dart';

/// [v0.2.0] 书籍句（Sentence）数据访问。
///
/// 一次导入在事务内批量写入；按 book/page 读取供阅读页使用。
class SentenceDao {
  SentenceDao(this.db);

  final Database db;

  static const _table = 'sentences';

  /// 批量插入（单事务），失败整体回滚。
  Future<int> insertAll(List<Sentence> rows) async {
    if (rows.isEmpty) return 0;
    return db.transaction((txn) async {
      var n = 0;
      for (final s in rows) {
        await txn.insert(
          _table,
          s.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        n++;
      }
      return n;
    });
  }

  /// 删除某书籍的全部句子（删除书籍时级联）。
  Future<int> deleteByBook(String bookId) async {
    return db.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);
  }

  /// 原子替换某书籍的全部句子，供分句规则升级使用。
  Future<void> replaceByBook(String bookId, List<Sentence> rows) async {
    await db.transaction((txn) async {
      await txn.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);
      for (final s in rows) {
        await txn.insert(
          _table,
          s.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 按书籍取全部句子（页序、句序）。
  Future<List<Sentence>> getByBook(String bookId) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'page ASC, sentence_index ASC',
    );
    return rows.map(Sentence.fromMap).toList();
  }

  /// 按书籍 + 页码取句子（页内句序）。
  Future<List<Sentence>> getByPage(String bookId, int page) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ? AND page = ?',
      whereArgs: [bookId, page],
      orderBy: 'sentence_index ASC',
    );
    return rows.map(Sentence.fromMap).toList();
  }

  /// 某书籍的句子总数。
  Future<int> countByBook(String bookId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE book_id = ?',
      [bookId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }
}
