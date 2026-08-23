import 'package:sqflite/sqflite.dart';

import '../models/knowledge_point.dart';

/// [v0.3.0] 知识库（KnowledgePoint）数据访问。
///
/// 按 book+type+text 幂等（[upsertByText]），AI 重复提取不建重复行。
class KnowledgePointDao {
  KnowledgePointDao(this.db);

  final Database db;

  static const _table = 'knowledge_points';

  /// 插入单条，返回 id。
  Future<String> insert(KnowledgePoint kp) async {
    await db.insert(
      _table,
      kp.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return kp.id;
  }

  /// 批量插入（单事务）。
  Future<void> insertAll(List<KnowledgePoint> list) async {
    if (list.isEmpty) return;
    final batch = db.batch();
    for (final kp in list) {
      batch.insert(
        _table,
        kp.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 按 book+type+text 幂等写入。
  ///
  /// 已存在则更新归属（page/chapter）与释义/附加，返回原 id；
  /// 不存在则新建。AI 重提不重复建行。
  Future<String> upsertByText(
    String bookId,
    KnowledgeType type,
    String text, {
    int? page,
    int? chapter,
    String? definition,
    String? extra,
    String source = 'ai',
  }) => upsertByTextInExecutor(
    db,
    bookId,
    type,
    text,
    page: page,
    chapter: chapter,
    definition: definition,
    extra: extra,
    source: source,
  );

  Future<String> upsertByTextInExecutor(
    DatabaseExecutor executor,
    String bookId,
    KnowledgeType type,
    String text, {
    int? page,
    int? chapter,
    String? definition,
    String? extra,
    String source = 'ai',
  }) async {
    final rows = await executor.query(
      _table,
      where: 'book_id = ? AND type = ? AND text = ?',
      whereArgs: [bookId, type.name, text],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final existing =
          KnowledgePoint.fromMap(rows.first)
            ..page = page
            ..chapter = chapter
            ..definition = definition ?? (rows.first['definition'] as String?)
            ..extra = extra ?? (rows.first['extra'] as String?);
      final data =
          existing.toMap()
            ..['updated_at'] = DateTime.now().microsecondsSinceEpoch;
      await executor.update(
        _table,
        data,
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return existing.id;
    }
    final kp = KnowledgePoint.create(
      bookId: bookId,
      page: page,
      chapter: chapter,
      type: type,
      text: text,
      definition: definition,
      extra: extra,
      source: source,
    );
    await executor.insert(
      _table,
      kp.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return kp.id;
  }

  /// 按 book+type+text 查单个。
  Future<KnowledgePoint?> findByBookTypeText(
    String bookId,
    KnowledgeType type,
    String text,
  ) async {
    final rows = await db.query(
      _table,
      where: 'book_id = ? AND type = ? AND text = ?',
      whereArgs: [bookId, type.name, text],
      limit: 1,
    );
    return rows.isEmpty ? null : KnowledgePoint.fromMap(rows.first);
  }

  /// 全部（可选类型筛选，按掌握度升序 → 未掌握优先）。
  Future<List<KnowledgePoint>> getAll({KnowledgeType? type}) async {
    final rows =
        type == null
            ? await db.query(_table, orderBy: 'mastery ASC, created_at DESC')
            : await db.query(
              _table,
              where: 'type = ?',
              whereArgs: [type.name],
              orderBy: 'mastery ASC, created_at DESC',
            );
    return rows.map(KnowledgePoint.fromMap).toList();
  }

  /// 按书取（可选类型筛选）。
  Future<List<KnowledgePoint>> getByBook(
    String bookId, {
    KnowledgeType? type,
  }) async {
    final rows =
        type == null
            ? await db.query(
              _table,
              where: 'book_id = ?',
              whereArgs: [bookId],
              orderBy: 'chapter ASC, page ASC, created_at DESC',
            )
            : await db.query(
              _table,
              where: 'book_id = ? AND type = ?',
              whereArgs: [bookId, type.name],
              orderBy: 'chapter ASC, page ASC, created_at DESC',
            );
    return rows.map(KnowledgePoint.fromMap).toList();
  }

  /// 按页取（可选类型筛选）。
  Future<List<KnowledgePoint>> getByPage(
    String bookId,
    int page, {
    KnowledgeType? type,
  }) async {
    final where =
        type == null
            ? 'book_id = ? AND page = ?'
            : 'book_id = ? AND page = ? AND type = ?';
    final args = type == null ? [bookId, page] : [bookId, page, type.name];
    final rows = await db.query(
      _table,
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return rows.map(KnowledgePoint.fromMap).toList();
  }

  /// 按章节取（可选类型筛选）。
  Future<List<KnowledgePoint>> getByChapter(
    String bookId,
    int chapter, {
    KnowledgeType? type,
  }) async {
    final where =
        type == null
            ? 'book_id = ? AND chapter = ?'
            : 'book_id = ? AND chapter = ? AND type = ?';
    final args =
        type == null ? [bookId, chapter] : [bookId, chapter, type.name];
    final rows = await db.query(
      _table,
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return rows.map(KnowledgePoint.fromMap).toList();
  }

  /// 未掌握词（mastery < [threshold]），复习/测验优先。
  Future<List<KnowledgePoint>> getUnmastered({int threshold = 3}) async {
    final rows = await db.query(
      _table,
      where: 'mastery < ?',
      whereArgs: [threshold],
      orderBy: 'mastery ASC, wrong_count DESC',
    );
    return rows.map(KnowledgePoint.fromMap).toList();
  }

  /// 更新（掌握度/错误次数/释义等）。
  Future<int> update(KnowledgePoint kp) async {
    final data =
        kp.toMap()..['updated_at'] = DateTime.now().microsecondsSinceEpoch;
    return db.update(_table, data, where: 'id = ?', whereArgs: [kp.id]);
  }

  /// 删除。
  Future<int> delete(String id) =>
      db.delete(_table, where: 'id = ?', whereArgs: [id]);

  /// 按书删除（级联）。
  Future<int> deleteByBook(String bookId) =>
      db.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);

  /// 某书知识点总数。
  Future<int> countByBook(String bookId) => countByBookInExecutor(db, bookId);

  Future<int> countByBookInExecutor(
    DatabaseExecutor executor,
    String bookId,
  ) async =>
      Sqflite.firstIntValue(
        await executor.rawQuery(
          'SELECT COUNT(*) FROM $_table WHERE book_id = ?',
          [bookId],
        ),
      ) ??
      0;
}
