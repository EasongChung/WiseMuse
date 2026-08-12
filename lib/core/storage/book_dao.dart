import 'package:sqflite/sqflite.dart';

import '../models/book.dart';
import 'sentence_dao.dart';

/// [v0.1.0] 教材（Book）数据访问。

class BookDao {
  BookDao(this.db);

  final Database db;

  static const _table = 'books';

  /// 插入新教材，返回 id。
  Future<String> insert(Book book) async {
    await db.insert(
      _table,
      book.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return book.id;
  }

  /// 按更新时间倒序取全部教材。
  Future<List<Book>> getAll() async {
    final rows = await db.query(_table, orderBy: 'updated_at DESC');
    return rows.map(Book.fromMap).toList();
  }

  /// 按 id 取单个。
  Future<Book?> getById(String id) async {
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  /// 更新教材（title/pageCount 等），同步刷新 updated_at。
  Future<int> update(Book book) async {
    final data = book.toMap();
    data['updated_at'] = DateTime.now().microsecondsSinceEpoch;
    return db.update(_table, data, where: 'id = ?', whereArgs: [book.id]);
  }

  /// 删除教材及其引用。
  Future<int> delete(String id) async {
    // 关联清理：生词引用置空、学习记录保留（历史）、句子级联删。
    await db.update(
      'word_entries',
      {'from_book_id': null},
      where: 'from_book_id = ?',
      whereArgs: [id],
    );
    await SentenceDao(db).deleteByBook(id);
    return db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
