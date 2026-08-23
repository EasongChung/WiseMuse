import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/seed_data.dart';

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
        'title': '老书籍',
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
      expect(rows.first['title'], '老书籍');
      expect(rows.first['page_count'], 3);
      expect(
        await v2.query(
          'knowledge_points',
          where: 'book_id = ?',
          whereArgs: ['builtin_kindergarten_bridge'],
        ),
        hasLength(113),
        reason: 'v1-v7 跨级升 v9 也必须执行首次种子迁移',
      );

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

  test('v8 库升级 v9：补写内置书籍并保留 113 条孤儿知识点', () async {
    final dir = await Directory.systemTemp.createTemp('wisemuse_mig_v89_');
    final dbPath = p.join(dir.path, DatabaseProvider.dbName);
    try {
      final v8 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, version) async {
            final fresh = await DatabaseProvider.openTest();
            final schema = await fresh.rawQuery(
              "SELECT sql FROM sqlite_master WHERE type='table' AND name IN ('books','knowledge_points') ORDER BY name",
            );
            for (final row in schema) {
              var sql = row['sql'] as String?;
              if (sql != null && sql.contains('CREATE TABLE books')) {
                sql = sql.replaceFirst(
                  RegExp(
                    r',\s*sentence_split_version INTEGER NOT NULL DEFAULT 0',
                  ),
                  '',
                );
              }
              if (sql != null) await db.execute(sql);
            }
            await fresh.close();
          },
        ),
      );

      final seeded = await DatabaseProvider.openTest();
      final points = await seeded.query('knowledge_points');
      await seeded.close();
      final batch = v8.batch();
      for (final point in points) {
        batch.insert('knowledge_points', point);
      }
      await batch.commit(noResult: true);
      expect(await v8.query('books'), isEmpty);
      expect(await v8.query('knowledge_points'), hasLength(113));
      await v8.close();

      final v9 = await DatabaseProvider.openFile(dbPath);
      final books = await v9.query(
        'books',
        where: 'id = ?',
        whereArgs: ['builtin_kindergarten_bridge'],
      );
      expect(books, hasLength(1));
      expect(books.single['title'], '幼小衔接基础知识');
      expect(await v9.query('knowledge_points'), hasLength(113));
      // v9 repair is non-destructive: a user-deleted/customized point is not restored.
      await v9.delete(
        'knowledge_points',
        where: 'book_id = ? AND text = ?',
        whereArgs: ['builtin_kindergarten_bridge', 'b'],
      );
      await SeedData.repairBuiltinBook(v9);
      expect(
        await v9.query(
          'knowledge_points',
          where: 'book_id = ? AND text = ?',
          whereArgs: ['builtin_kindergarten_bridge', 'b'],
        ),
        isEmpty,
      );
      final columns = await v9.rawQuery('PRAGMA table_info(books)');
      expect(
        columns.map((row) => row['name']),
        contains('sentence_split_version'),
      );
      await v9.close();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('v10 库升级 v11：知识提取任务表存在且不改导入状态', () async {
    final dir = await Directory.systemTemp.createTemp('wisemuse_mig_v1011_');
    final dbPath = p.join(dir.path, DatabaseProvider.dbName);
    try {
      final v10 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (db, version) async {
            final fresh = await DatabaseProvider.openTest();
            final tables = await fresh.rawQuery(
              "SELECT sql FROM sqlite_master WHERE type='table' AND name IN ('books','knowledge_points','sentences') ORDER BY name",
            );
            for (final row in tables) {
              final sql = row['sql'] as String?;
              if (sql != null) await db.execute(sql);
            }
            await fresh.close();
          },
        ),
      );
      await v10.insert('books', {
        'id': 'b_import',
        'title': '导入中',
        'source': 'pdf',
        'import_status': 1,
        'import_progress': '识别中 2/5 页',
        'created_at': 1,
        'updated_at': 2,
      });
      await v10.close();

      final v11 = await DatabaseProvider.openFile(dbPath);
      expect(await _tableExists(v11, 'knowledge_extraction_jobs'), true);
      expect(await _tableExists(v11, 'knowledge_extraction_job_pages'), true);
      final row =
          (await v11.query(
            'books',
            where: 'id = ?',
            whereArgs: ['b_import'],
          )).single;
      expect(row['import_status'], 1);
      expect(row['import_progress'], '识别中 2/5 页');
      await v11.close();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('v2 库升级 v3：knowledge_points / quiz_attempts 存在、旧数据完好', () async {
    final dir = await Directory.systemTemp.createTemp('wisemuse_mig_v23_');
    final dbPath = p.join(dir.path, DatabaseProvider.dbName);
    try {
      // 1) 用 v2 schema 手工建库并插一条 word_entries 数据
      final v2 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE books (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, source TEXT NOT NULL,
                original_file_path TEXT, page_count INTEGER,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE word_entries (
                id TEXT PRIMARY KEY, word TEXT NOT NULL, lang TEXT NOT NULL,
                from_book_id TEXT, mastery INTEGER NOT NULL DEFAULT 0,
                wrong_count INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL, last_review_at INTEGER
              )
            ''');
            await db.execute('''
              CREATE TABLE learning_records (
                id TEXT PRIMARY KEY, type TEXT NOT NULL, target TEXT NOT NULL,
                result REAL NOT NULL, detail TEXT, at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE sentences (
                id TEXT PRIMARY KEY, book_id TEXT NOT NULL,
                page INTEGER NOT NULL DEFAULT 0, chapter INTEGER NOT NULL DEFAULT 0,
                sentence_index INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL, geometry TEXT
              )
            ''');
          },
        ),
      );
      await v2.insert('word_entries', {
        'id': 'w_old',
        'word': '苹果',
        'lang': 'zh',
        'mastery': 0,
        'wrong_count': 0,
        'added_at': 1,
      });
      await v2.close();

      // 2) 以 DatabaseProvider.openFile（v3）重开同一文件
      final v3 = await DatabaseProvider.openFile(dbPath);

      // 3) 断言新表存在、索引存在、旧数据完好
      expect(await _tableExists(v3, 'knowledge_points'), true);
      expect(await _tableExists(v3, 'quiz_attempts'), true);
      final rows = await v3.query(
        'word_entries',
        where: 'id = ?',
        whereArgs: ['w_old'],
      );
      expect(rows.length, 1);
      expect(rows.first['word'], '苹果');

      final idx = await v3.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_kp_book'",
      );
      expect(idx, isNotEmpty);
      await v3.close();
    } finally {
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
