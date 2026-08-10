import 'model_ids.dart';

/// [v0.1.0] 生词条目（未掌握词语）。
///
/// [mastery] 掌握度 0-5，由复习/听写结果驱动；
/// [wrongCount] 累计答错次数，用于复习优先级。

class WordEntry {
  WordEntry({
    required this.id,
    required this.word,
    required this.lang,
    this.fromBookId,
    this.mastery = 0,
    this.wrongCount = 0,
    required this.addedAt,
    this.lastReviewAt,
  });

  /// 生成新生词条目（mastery 初始 0）。
  factory WordEntry.create({
    required String word,
    required String lang,
    String? fromBookId,
  }) {
    return WordEntry(
      id: newModelId('word'),
      word: word,
      lang: lang,
      fromBookId: fromBookId,
      addedAt: DateTime.now().microsecondsSinceEpoch,
    );
  }

  final String id;
  final String word;

  /// 语言代码（zh/en/...），用于听写/复习的语音与匹配。
  final String lang;

  /// 来源教材（可选）。
  final String? fromBookId;

  int mastery;
  int wrongCount;

  final int addedAt;
  int? lastReviewAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'word': word,
    'lang': lang,
    'from_book_id': fromBookId,
    'mastery': mastery,
    'wrong_count': wrongCount,
    'added_at': addedAt,
    'last_review_at': lastReviewAt,
  };

  factory WordEntry.fromMap(Map<String, dynamic> map) => WordEntry(
    id: map['id'] as String,
    word: (map['word'] as String?) ?? '',
    lang: (map['lang'] as String?) ?? 'zh',
    fromBookId: map['from_book_id'] as String?,
    mastery: (map['mastery'] as int?) ?? 0,
    wrongCount: (map['wrong_count'] as int?) ?? 0,
    addedAt: (map['added_at'] as int?) ?? 0,
    lastReviewAt: map['last_review_at'] as int?,
  );
}
