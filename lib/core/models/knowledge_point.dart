import 'model_ids.dart';

/// [v0.3.0] 知识库知识点（AI 提取或手动录入的词语/成语/英语单词/古诗词）。
///
/// 关联书籍双粒度：[bookId] + [page]/[chapter]（page=0 表示整本/无页）。
/// [mastery] 掌握度 0-5，由测验/复习结果驱动；[wrongCount] 累计答错次数。
///
/// 与 word_entries（生词本=未掌握流动仓）职责分离：测验答错词除回写本表外
/// 单向 upsert 进生词本。
class KnowledgePoint {
  KnowledgePoint({
    required this.id,
    this.bookId,
    this.page,
    this.chapter,
    required this.type,
    required this.text,
    this.definition,
    this.extra,
    this.source = 'ai',
    this.mastery = 0,
    this.wrongCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 生成新知识点（mastery 初始 0，source 默认 ai）。
  factory KnowledgePoint.create({
    String? bookId,
    int? page,
    int? chapter,
    required KnowledgeType type,
    required String text,
    String? definition,
    String? extra,
    String source = 'ai',
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return KnowledgePoint(
      id: newModelId('kp'),
      bookId: bookId,
      page: page,
      chapter: chapter,
      type: type,
      text: text,
      definition: definition,
      extra: extra,
      source: source,
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;
  String? bookId;

  /// 页码（TXT/Word 全书当单页时可为 null）。
  int? page;

  /// 章节号（chapter=0 表示整本即一章）。
  int? chapter;

  final KnowledgeType type;

  /// 词语/成语/英语单词/诗句正文。
  final String text;

  /// 释义。
  String? definition;

  /// 附加信息：拼音/出处/例句（JSON 或纯文本）。
  String? extra;

  /// 来源：ai / manual。
  String source;

  int mastery;
  int wrongCount;

  final int createdAt;
  int updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'book_id': bookId,
    'page': page,
    'chapter': chapter,
    'type': type.name,
    'text': text,
    'definition': definition,
    'extra': extra,
    'source': source,
    'mastery': mastery,
    'wrong_count': wrongCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory KnowledgePoint.fromMap(Map<String, dynamic> map) => KnowledgePoint(
    id: map['id'] as String,
    bookId: map['book_id'] as String?,
    page: map['page'] as int?,
    chapter: map['chapter'] as int?,
    type: KnowledgeType.fromName(map['type'] as String?),
    text: (map['text'] as String?) ?? '',
    definition: map['definition'] as String?,
    extra: map['extra'] as String?,
    source: (map['source'] as String?) ?? 'ai',
    mastery: (map['mastery'] as int?) ?? 0,
    wrongCount: (map['wrong_count'] as int?) ?? 0,
    createdAt: (map['created_at'] as int?) ?? 0,
    updatedAt: (map['updated_at'] as int?) ?? 0,
  );
}

/// 知识点类型。
enum KnowledgeType {
  /// 词语（生词）。
  word('词语'),

  /// 成语（四字）。
  idiom('成语'),

  /// 英语单词。
  english('英语单词'),

  /// 古诗词句。
  poem('古诗词');

  const KnowledgeType(this.label);
  final String label;

  static KnowledgeType fromName(String? name) {
    return KnowledgeType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => KnowledgeType.word,
    );
  }
}
