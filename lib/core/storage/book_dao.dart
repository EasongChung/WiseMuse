import 'package:sqflite/sqflite.dart';

import '../models/book.dart';
import 'sentence_dao.dart';

/// [v0.1.0] 书籍（Book）数据访问。
///
/// [v0.1.35] 多孩子模式：构造时传入 [profileId]，null=家长模式不过滤。

class BookDao {
  BookDao(this.db, {this.profileId});

  final Database db;
  final String? profileId;

  static const _table = 'books';

  /// 插入新书籍，自动关联 profileId。
  Future<String> insert(Book book) async {
    final map = book.toMap();
    if (profileId != null) map['profile_id'] = profileId;
    await db.insert(_table, map, conflictAlgorithm: ConflictAlgorithm.replace);
    return book.id;
  }

  /// 按更新时间倒序取全部书籍（当前孩子的）。
  Future<List<Book>> getAll() async {
    final rows =
        profileId != null
            ? await db.query(
              _table,
              where: 'profile_id = ?',
              whereArgs: [profileId],
              orderBy: 'updated_at DESC',
            )
            : await db.query(_table, orderBy: 'updated_at DESC');
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

  /// 更新书籍（title/pageCount 等），同步刷新 updated_at。
  Future<int> update(Book book) async {
    final data = book.toMap();
    data['updated_at'] = DateTime.now().microsecondsSinceEpoch;
    return db.update(_table, data, where: 'id = ?', whereArgs: [book.id]);
  }

  /// 删除书籍及其引用。
  Future<int> delete(String id) async {
    // 关联清理：生词引用置空、学习记录保留（历史）、句子级联删。
    await db.update(
      'word_entries',
      {'from_book_id': null},
      where: 'from_book_id = ?',
      whereArgs: [id],
    );
    await SentenceDao(db).deleteByBook(id);
    // 知识库与测验级联（v3）
    await db.delete('knowledge_points', where: 'book_id = ?', whereArgs: [id]);
    await db.delete('quiz_attempts', where: 'book_id = ?', whereArgs: [id]);
    return db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
