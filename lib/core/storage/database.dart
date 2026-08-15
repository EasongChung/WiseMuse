import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// [v0.1.0] sqflite 数据库提供者：打开库 + 建表 + 迁移。
///
/// 单例持有 [Database]；测试时通过 `databaseFactory = databaseFactoryFfi`
/// （sqflite_common_ffi）注入内存/临时文件库，再调用 [reset] 隔离用例。

class DatabaseProvider {
  DatabaseProvider._();

  static const String dbName = 'wisemuse.db';
  static const int dbVersion = 4;

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
      CREATE TABLE profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar_emoji TEXT NOT NULL DEFAULT '👦',
        is_parent INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''';

  // ===== sentences 表 SQL（_onCreate 与 _onUpgrade 共用，杜绝双份漂移）=====

  static const String _createSentencesSql = '''
      CREATE TABLE sentences (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        book_id TEXT NOT NULL,
        page INTEGER NOT NULL DEFAULT 0,
        chapter INTEGER NOT NULL DEFAULT 0,
        sentence_index INTEGER NOT NULL DEFAULT 0,
        text TEXT NOT NULL,
        geometry TEXT
      )
    ''';

  static const String _createSentenceIndexesSql = '''
      CREATE INDEX idx_sentences_book ON sentences(book_id);
      CREATE INDEX idx_sentences_book_page ON sentences(book_id, page);
    ''';

  // ===== knowledge_points / quiz_attempts 表 SQL（v3 新增，_onCreate/_onUpgrade 共用）=====

  static const String _createKnowledgePointsSql = '''
      CREATE TABLE knowledge_points (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        book_id TEXT,
        page INTEGER,
        chapter INTEGER,
        type TEXT NOT NULL,
        text TEXT NOT NULL,
        definition TEXT,
        extra TEXT,
        source TEXT NOT NULL DEFAULT 'ai',
        mastery INTEGER NOT NULL DEFAULT 0,
        wrong_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''';

  static const String _createKnowledgePointIndexesSql = '''
      CREATE INDEX idx_kp_book ON knowledge_points(book_id);
      CREATE INDEX idx_kp_book_page ON knowledge_points(book_id, page);
      CREATE INDEX idx_kp_book_chapter ON knowledge_points(book_id, chapter);
      CREATE INDEX idx_kp_type ON knowledge_points(type);
    ''';

  static const String _createQuizAttemptsSql = '''
      CREATE TABLE quiz_attempts (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        book_id TEXT NOT NULL,
        chapter INTEGER NOT NULL DEFAULT 0,
        page INTEGER,
        total_score REAL NOT NULL,
        question_count INTEGER NOT NULL DEFAULT 0,
        correct_count INTEGER NOT NULL DEFAULT 0,
        detail TEXT,
        at INTEGER NOT NULL
      )
    ''';

  static const String _createQuizAttemptIndexesSql = '''
      CREATE INDEX idx_quiz_book ON quiz_attempts(book_id);
      CREATE INDEX idx_quiz_book_chapter ON quiz_attempts(book_id, chapter);
    ''';

  /// 建表（版本 1）。
  static Future<void> _onCreate(Database db, int version) async {
    // 书籍
    await db.execute('''
      CREATE TABLE books (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        original_file_path TEXT,
        page_count INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    // 生词本
    await db.execute('''
      CREATE TABLE word_entries (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        word TEXT NOT NULL,
        lang TEXT NOT NULL,
        from_book_id TEXT,
        mastery INTEGER NOT NULL DEFAULT 0,
        wrong_count INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        last_review_at INTEGER
      )
    ''');
    // 学习记录
    await db.execute('''
      CREATE TABLE learning_records (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT 'default',
        type TEXT NOT NULL,
        target TEXT NOT NULL,
        result REAL NOT NULL,
        detail TEXT,
        at INTEGER NOT NULL
      )
    ''');
    // 常用查询索引
    await db.execute(
      'CREATE INDEX idx_words_from_book ON word_entries(from_book_id)',
    );
    await db.execute('CREATE INDEX idx_records_type ON learning_records(type)');
    await db.execute('CREATE INDEX idx_records_at ON learning_records(at)');
    // 书籍句（Phase 2：导入时按页/句切好的文本骨架 + 图片 OCR 几何）
    await db.execute(_createSentencesSql);
    await db.execute(_createSentenceIndexesSql);
    // 知识库与章节测验（v3）
    await db.execute(_createKnowledgePointsSql);
    await db.execute(_createKnowledgePointIndexesSql);
    await db.execute(_createQuizAttemptsSql);
    await db.execute(_createQuizAttemptIndexesSql);
    // v4：档案（多孩子模式）
    await db.execute(_createProfilesSql);
  }

  /// 数据库迁移（版本升级时）。只做增量，不删旧数据。
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // v1 → v2：新增 sentences 表（复用 _onCreate 的 SQL 常量）
      await db.execute(_createSentencesSql);
      await db.execute(_createSentenceIndexesSql);
    }
    if (oldVersion < 3) {
      // v2 → v3：新增 knowledge_points / quiz_attempts 表
      await db.execute(_createKnowledgePointsSql);
      await db.execute(_createKnowledgePointIndexesSql);
      await db.execute(_createQuizAttemptsSql);
      await db.execute(_createQuizAttemptIndexesSql);
    }
    if (oldVersion < 4) {
      // v3 → v4：档案表 + 各业务表增加 profile_id 列
      await db.execute(_createProfilesSql);
      // ALTER TABLE 可能因 shared CREATE TABLE 常量已含 profile_id 而失败，
      // try/catch 安全忽略「已存在」错误。
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
        } catch (_) {
          // column already exists — skip
        }
      }
      // profile_id 查询索引
      await db.execute('CREATE INDEX idx_books_profile ON books(profile_id)');
      await db.execute(
        'CREATE INDEX idx_words_profile ON word_entries(profile_id)',
      );
      await db.execute(
        'CREATE INDEX idx_records_profile ON learning_records(profile_id)',
      );
    }
  }

  /// 关闭并重置单例（测试用 / 应用退出）。
  static Future<void> reset() async {
    await _db?.close();
    _db = null;
  }

  /// 测试用：打开**独立内存库**（每次全新建表、不持久化）。
  ///
  /// 供 DAO 单测使用，避免持久化文件导致用例间数据累积；
  /// 需配合 `databaseFactory = databaseFactoryFfi`（sqflite_common_ffi）。
  static Future<Database> openTest() {
    return openDatabase(
      inMemoryDatabasePath,
      version: dbVersion,
      onCreate: _onCreate,
    );
  }

  /// 测试用：以指定文件路径打开数据库（含完整建表 + 迁移）。
  ///
  /// 供迁移测试使用：先用 v1 schema 建一个旧库，再以本方法（v2）重开，
  /// 验证 [onUpgrade] 增量建 sentences 表且旧数据完好。
  static Future<Database> openFile(String path) {
    return openDatabase(
      path,
      version: dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }
}
