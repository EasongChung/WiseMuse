import 'model_ids.dart';

/// [v0.1.0] 书籍/导入文档模型。
///
/// 一次导入 = 一本书籍（Book），含来源类型与原文件引用。
/// 章节/页/句结构由 Phase 2 分章分句模块补充（Sentence 表）。

/// 书籍来源类型。
enum BookSource {
  camera('拍照'),
  gallery('相册'),
  pdf('PDF'),
  word('Word'),
  txt('文本');

  const BookSource(this.label);
  final String label;

  static BookSource fromName(String? name) {
    return BookSource.values.firstWhere(
      (e) => e.name == name,
      orElse: () => BookSource.txt,
    );
  }
}

/// 一篇导入的书籍。
class Book {
  Book({
    required this.id,
    required this.title,
    required this.source,
    this.originalFilePath,
    this.pageCount,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 生成带时间戳与随机后缀的新书籍。
  factory Book.create({
    required String title,
    required BookSource source,
    String? originalFilePath,
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return Book(
      id: newModelId('book'),
      title: title,
      source: source,
      originalFilePath: originalFilePath,
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;
  String title;
  final BookSource source;

  /// 原文件路径（图片/PDF/docx，存于 app 私有目录）。
  final String? originalFilePath;

  /// 文本模式页数（真实分页或运行时虚拟分页）。
  int? pageCount;

  final int createdAt;
  int updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'source': source.name,
    'original_file_path': originalFilePath,
    'page_count': pageCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory Book.fromMap(Map<String, dynamic> map) => Book(
    id: map['id'] as String,
    title: (map['title'] as String?) ?? '未命名',
    source: BookSource.fromName(map['source'] as String?),
    originalFilePath: map['original_file_path'] as String?,
    pageCount: map['page_count'] as int?,
    createdAt: (map['created_at'] as int?) ?? 0,
    updatedAt: (map['updated_at'] as int?) ?? 0,
  );
}
