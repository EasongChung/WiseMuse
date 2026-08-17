import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// [v0.1.0] sqflite 数据库提供者：打开库 + 建表 + 迁移。
///
/// 单例持有 [Database]；测试时通过 `databaseFactory = databaseFactoryFfi`
/// （sqflite_common_ffi）注入内存/临时文件库，再调用 [reset] 隔离用例。

class DatabaseProvider {
  DatabaseProvider._();

  static const String dbName = 'wisemuse.db';
  static const int dbVersion = 5;

  static Database? _db;

  /// 获取打开的数据库（首次调用创建并建表；已有库按版本迁移）。
  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), dbName),
      version: dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  static const String _createProfilesSql = '''
      CREATE TABLE profiles (\n        id TEXT PRIMARY KEY,\n        name TEXT NOT NULL,\n        avatar_emoji TEXT NOT NULL DEFAULT '👦',\n        is_parent INTEGER NOT NULL DEFAULT 0,\n        created_at INTEGER NOT NULL\n      )\n    ''';

  // ===== sentences 表 SQL（_onCreate 与 _onUpgrade 共用，杜绝双份漂移）=====

  static const String _createSentencesSql = '''
      CREATE TABLE sentences (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        book_id TEXT NOT NULL,\n        page INTEGER NOT NULL DEFAULT 0,\n        chapter INTEGER NOT NULL DEFAULT 0,\n        sentence_index INTEGER NOT NULL DEFAULT 0,\n        text TEXT NOT NULL,\n        geometry TEXT\n      )\n    ''';

  static const String _createSentenceIndexesSql = '''
      CREATE INDEX idx_sentences_book ON sentences(book_id);\n      CREATE INDEX idx_sentences_book_page ON sentences(book_id, page);\n    ''';

  // ===== knowledge_points / quiz_attempts 表 SQL（v3 新增，_onCreate/_onUpgrade 共用）=====

  static const String _createKnowledgePointsSql = '''
      CREATE TABLE knowledge_points (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        book_id TEXT,\n        page INTEGER,\n        chapter INTEGER,\n        type TEXT NOT NULL,\n        text TEXT NOT NULL,\n        definition TEXT,\n        extra TEXT,\n        source TEXT NOT NULL DEFAULT 'ai',\n        mastery INTEGER NOT NULL DEFAULT 0,\n        wrong_count INTEGER NOT NULL DEFAULT 0,\n        created_at INTEGER NOT NULL,\n        updated_at INTEGER NOT NULL\n      )\n    ''';

  static const String _createKnowledgePointIndexesSql = '''
      CREATE INDEX idx_kp_book ON knowledge_points(book_id);\n      CREATE INDEX idx_kp_book_page ON knowledge_points(book_id, page);\n      CREATE INDEX idx_kp_book_chapter ON knowledge_points(book_id, chapter);\n      CREATE INDEX idx_kp_type ON knowledge_points(type);\n    ''';

  static const String _createQuizAttemptsSql = '''
      CREATE TABLE quiz_attempts (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        book_id TEXT NOT NULL,\n        chapter INTEGER NOT NULL DEFAULT 0,\n        page INTEGER,\n        total_score REAL NOT NULL,\n        question_count INTEGER NOT NULL DEFAULT 0,\n        correct_count INTEGER NOT NULL DEFAULT 0,\n        detail TEXT,\n        at INTEGER NOT NULL\n      )\n    ''';

  static const String _createQuizAttemptIndexesSql = '''
      CREATE INDEX idx_quiz_book ON quiz_attempts(book_id);\n      CREATE INDEX idx_quiz_book_chapter ON quiz_attempts(book_id, chapter);\n    ''';

  // ===== chat_messages 表 SQL（v5 新增）=====
  static const String _createChatMessagesSql = '''
      CREATE TABLE chat_messages (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        role TEXT NOT NULL,\n        content TEXT NOT NULL,\n        book_id TEXT,\n        book_title TEXT,\n        sources TEXT,\n        created_at INTEGER NOT NULL\n      )\n    ''';

  /// 建表（版本 1~5）。
  static Future<void> _onCreate(Database db, int version) async {
    // 书籍
    await db.execute(
      '''
      CREATE TABLE books (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        title TEXT NOT NULL,\n        source TEXT NOT NULL,\n        original_file_path TEXT,\n        page_count INTEGER,\n        last_read_page INTEGER NOT NULL DEFAULT 0,\n        import_status INTEGER NOT NULL DEFAULT 0,\n        import_progress TEXT,\n        created_at INTEGER NOT NULL,\n        updated_at INTEGER NOT NULL\n      )\n    ''',
    );
    // 生词本
    await db.execute(
      '''
      CREATE TABLE word_entries (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        word TEXT NOT NULL,\n        lang TEXT NOT NULL,\n        from_book_id TEXT,\n        mastery INTEGER NOT NULL DEFAULT 0,\n        wrong_count INTEGER NOT NULL DEFAULT 0,\n        added_at INTEGER NOT NULL,\n        last_review_at INTEGER\n      )\n    ''',
    );
    // 学习记录
    await db.execute(
      '''
      CREATE TABLE learning_records (\n        id TEXT PRIMARY KEY,\n        profile_id TEXT NOT NULL DEFAULT 'default',\n        type TEXT NOT NULL,\n        target TEXT NOT NULL,\n        result REAL NOT NULL,\n        detail TEXT,\n        at INTEGER NOT NULL\n      )\n    ''',
    );
    // 常用查询索引
    await db.execute(
      'CREATE INDEX idx_words_from_book ON word_entries(from_book_id)',
    );
    await db.execute('CREATE INDEX idx_records_type ON learning_records(type)');
    await db.execute('CREATE INDEX idx_records_at ON learning_records(at)');
    // 书籍句
    await db.execute(_createSentencesSql);
    await db.execute(_createSentenceIndexesSql);
    // 知识库与章节测验（v3）
    await db.execute(_createKnowledgePointsSql);
    await db.execute(_createKnowledgePointIndexesSql);
    await db.execute(_createQuizAttemptsSql);
    await db.execute(_createQuizAttemptIndexesSql);
    // v4：档案（多孩子模式）
    await db.execute(_createProfilesSql);
    // v5：会话记录
    await db.execute(_createChatMessagesSql);
    await db.execute(
      'CREATE INDEX idx_chat_profile ON chat_messages(profile_id)',
    );
  }

  /// 数据库迁移（版本升级时）。只做增量，不删旧数据。
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(_createSentencesSql);
      await db.execute(_createSentenceIndexesSql);
    }
    if (oldVersion < 3) {
      await db.execute(_createKnowledgePointsSql);
      await db.execute(_createKnowledgePointIndexesSql);
      await db.execute(_createQuizAttemptsSql);
      await db.execute(_createQuizAttemptIndexesSql);
    }
    if (oldVersion < 4) {
      await db.execute(_createProfilesSql);
      for (final table in [
        'books',
        'word_entries',
        'learning_records',
        'sentences',
        'knowledge_points',
        'quiz_attempts',
      ]) {
        try {
          await db.execute(
            "ALTER TABLE $table ADD COLUMN profile_id TEXT NOT NULL DEFAULT 'default'",
          );
        } catch (_) {}
      }
      await db.execute('CREATE INDEX idx_books_profile ON books(profile_id)');
      await db.execute(
        'CREATE INDEX idx_words_profile ON word_entries(profile_id)',
      );
      await db.execute(
        'CREATE INDEX idx_records_profile ON learning_records(profile_id)',
      );
    }
    if (oldVersion < 5) {
      // v4 → v5: books 增加 last_read_page / import_status / import_progress
      for (final col in [
        'ALTER TABLE books ADD COLUMN last_read_page INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE books ADD COLUMN import_status INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE books ADD COLUMN import_progress TEXT',
      ]) {
        try {
          await db.execute(col);
        } catch (_) {}
      }
      // 新建 chat_messages 表
      try {
        await db.execute(_createChatMessagesSql);
        await db.execute(
          'CREATE INDEX idx_chat_profile ON chat_messages(profile_id)',
        );
      } catch (_) {}
    }
  }

  /// 关闭并重置单例（测试用 / 应用退出）。
  static Future<void> reset() async {
    await _db?.close();
    _db = null;
  }

  /// 测试用：打开**独立内存库**。
  static Future<Database> openTest() {
    return openDatabase(
      inMemoryDatabasePath,
      version: dbVersion,
      onCreate: _onCreate,
    );
  }

  /// 测试用：以指定文件路径打开数据库。
  static Future<Database> openFile(String path) {
    return openDatabase(
      path,
      version: dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }
}
