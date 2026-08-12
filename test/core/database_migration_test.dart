import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/storage/database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v1 库升级 v2：sentences 表存在、旧 books 数据完好', () async {
    // 临时文件库目录（迁移需要落盘路径）
    final dir = await Directory.systemTemp.createTemp('wisemuse_mig_');
    final dbPath = p.join(dir.path, DatabaseProvider.dbName);
    try {
      // 1) 用 v1 schema 手工建库并插一条 books 数据
      final v1 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source TEXT NOT NULL,
                original_file_path TEXT,
                page_count INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE word_entries (
                id TEXT PRIMARY KEY,
                word TEXT NOT NULL,
                lang TEXT NOT NULL,
                from_book_id TEXT,
                mastery INTEGER NOT NULL DEFAULT 0,
                wrong_count INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL,
                last_review_at INTEGER
              )
            ''');
            await db.execute('''
              CREATE TABLE learning_records (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                target TEXT NOT NULL,
                result REAL NOT NULL,
                detail TEXT,
                at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      await v1.insert('books', {
        'id': 'b_old',
        'title': '老教材',
        'source': 'pdf',
        'original_file_path': '/x/y.pdf',
        'page_count': 3,
        'created_at': 1,
        'updated_at': 2,
      });
      // v1 库此刻不应有 sentences 表
      expect(await _tableExists(v1, 'sentences'), false);
      await v1.close();

      // 2) 以 DatabaseProvider.openFile（v2 + onUpgrade）重开同一文件库
      final v2 = await DatabaseProvider.openFile(dbPath);

      // 3) 断言：sentences 表已建、books 数据完好、索引在
      expect(await _tableExists(v2, 'sentences'), true);
      final rows = await v2.query(
        'books',
        where: 'id = ?',
        whereArgs: ['b_old'],
      );
      expect(rows.length, 1);
      expect(rows.first['title'], '老教材');
      expect(rows.first['page_count'], 3);

      final idx = await v2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_sentences_book'",
      );
      expect(idx, isNotEmpty);
      await v2.close();
    } finally {
      // 清理临时目录
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });
}

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    [table],
  );
  return rows.isNotEmpty;
}
