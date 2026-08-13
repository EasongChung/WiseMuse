import 'model_ids.dart';

/// [v0.3.0] 章节/页测验结果（一次测验的聚合记录）。
///
/// [totalScore] 0-100 总评分；[detail] 存每题结果 JSON（题型/对错/得分）。
/// 逐题流水放 learning_records（type=quiz），本表是测验的聚合载体
/// （每章最佳分/历史）。
class QuizAttempt {
  QuizAttempt({
    required this.id,
    required this.bookId,
    required this.chapter,
    this.page,
    required this.totalScore,
    required this.questionCount,
    required this.correctCount,
    this.detail,
    required this.at,
  });

  /// 新建测验记录。
  factory QuizAttempt.create({
    required String bookId,
    required int chapter,
    int? page,
    required double totalScore,
    required int questionCount,
    required int correctCount,
    String? detail,
  }) {
    return QuizAttempt(
      id: newModelId('quiz'),
      bookId: bookId,
      chapter: chapter,
      page: page,
      totalScore: totalScore,
      questionCount: questionCount,
      correctCount: correctCount,
      detail: detail,
      at: DateTime.now().microsecondsSinceEpoch,
    );
  }

  final String id;
  final String bookId;

  /// 章节号（chapter=0 表示整本）。
  final int chapter;

  /// 页级测验的页码（章节测验为 null）。
  final int? page;

  /// 总评分 0-100。
  final double totalScore;

  final int questionCount;
  final int correctCount;

  /// 每题结果 JSON（题型/对错/得分）。
  final String? detail;

  final int at;

  Map<String, dynamic> toMap() => {
    'id': id,
    'book_id': bookId,
    'chapter': chapter,
    'page': page,
    'total_score': totalScore,
    'question_count': questionCount,
    'correct_count': correctCount,
    'detail': detail,
    'at': at,
  };

  factory QuizAttempt.fromMap(Map<String, dynamic> map) => QuizAttempt(
    id: map['id'] as String,
    bookId: (map['book_id'] as String?) ?? '',
    chapter: (map['chapter'] as int?) ?? 0,
    page: map['page'] as int?,
    totalScore: ((map['total_score'] as num?) ?? 0).toDouble(),
    questionCount: (map['question_count'] as int?) ?? 0,
    correctCount: (map['correct_count'] as int?) ?? 0,
    detail: map['detail'] as String?,
    at: (map['at'] as int?) ?? 0,
  );
}
