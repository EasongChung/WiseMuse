import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// [v0.1.0] sqflite 数据库提供者：打开库 + 建表 + 迁移。
///
/// 单例持有 [Database]；测试时通过 `databaseFactory = databaseFactoryFfi`
/// （sqflite_common_ffi）注入内存/临时文件库，再调用 [reset] 隔离用例。

class DatabaseProvider {
  DatabaseProvider._();

  static const String dbName = 'wisemuse.db';
  static const int dbVersion = 2;

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

  // ===== sentences 表 SQL（_onCreate 与 _onUpgrade 共用，杜绝双份漂移）=====

  static const String _createSentencesSql = '''
      CREATE TABLE sentences (
        id TEXT PRIMARY KEY,
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

  /// 建表（版本 1）。
  static Future<void> _onCreate(Database db, int version) async {
    // 教材
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
    // 生词本
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
    // 学习记录
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
    // 常用查询索引
    await db.execute(
      'CREATE INDEX idx_words_from_book ON word_entries(from_book_id)',
    );
    await db.execute('CREATE INDEX idx_records_type ON learning_records(type)');
    await db.execute('CREATE INDEX idx_records_at ON learning_records(at)');
    // 教材句（Phase 2：导入时按页/句切好的文本骨架 + 图片 OCR 几何）
    await db.execute(_createSentencesSql);
    await db.execute(_createSentenceIndexesSql);
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
