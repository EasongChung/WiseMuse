import '../core/models/knowledge_point.dart';
import '../core/models/word_entry.dart';

/// [v0.1.66] 统一的复习目标适配层。
///
/// 普通生词（[WordEntry]）与知识库知识点（[KnowledgePoint]）都能生成
/// [ReviewItem]，供 [ReviewCard] 以一致的方式展示语义内容、朗读，
/// 并把复习结果回写回各自的数据源。不持久化，不进数据库。
class ReviewItem {
  ReviewItem({
    required this.text,
    required this.lang,
    this.definition,
    this.extra,
    this.type,
    this.mastery = 0,
    this.wrongCount = 0,
    this.sourceId,
    this.sourceKind,
    this.wordEntry,
    this.knowledgePoint,
  });

  final String text;
  final String lang;
  final String? definition;
  final String? extra;
  final KnowledgeType? type;
  final int mastery;
  final int wrongCount;
  final String? sourceId;
  final String? sourceKind;

  /// 生词来源（普通生词复习时非空）。
  final WordEntry? wordEntry;

  /// 知识点来源（知识库复习时非空）。
  final KnowledgePoint? knowledgePoint;

  bool get isKnowledgePoint => knowledgePoint != null;

  /// 是否有可用的语义资料（释义/例句）。
  bool get hasSemantic =>
      (definition != null && definition!.isNotEmpty) ||
      (extra != null && extra!.isNotEmpty);

  /// 从生词条目适配。
  factory ReviewItem.fromWordEntry(WordEntry e) {
    return ReviewItem(
      text: e.word,
      lang: e.lang,
      mastery: e.mastery,
      wrongCount: e.wrongCount,
      sourceId: e.id,
      sourceKind: 'word',
      wordEntry: e,
    );
  }

  /// 从知识点适配。
  factory ReviewItem.fromKnowledgePoint(KnowledgePoint p) {
    final lang = p.type == KnowledgeType.english ? 'en' : 'zh';
    return ReviewItem(
      text: p.text,
      lang: lang,
      definition: p.definition,
      extra: p.extra,
      type: p.type,
      mastery: p.mastery,
      wrongCount: p.wrongCount,
      sourceId: p.id,
      sourceKind: 'knowledge',
      knowledgePoint: p,
    );
  }
}
