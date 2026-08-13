import '../core/storage/database.dart';
import '../core/storage/quiz_attempt_dao.dart';

/// [v0.3.0] 测验深度统计（按章聚合）。
///
/// 用于统计页展示每本书每章的最佳分/次数/最新成绩。
class QuizDepthStat {
  const QuizDepthStat({
    required this.bookTitle,
    required this.chapter,
    required this.bestScore,
    required this.totalAttempts,
    required this.latestScore,
  });

  final String bookTitle;
  final int chapter;
  final double bestScore;
  final int totalAttempts;
  final double latestScore;

  String get chapterLabel => chapter == 0 ? '全书' : '第 $chapter 章';
}

/// 测验深度分析服务。
class QuizDepthService {
  /// 加载所有测验按（书,章）聚合的最佳分/次数。
  static Future<List<QuizDepthStat>> load() async {
    final db = await DatabaseProvider.database;
    final dao = QuizAttemptDao(db);

    // 先取所有 bookId+chapter 组合
    final rows = await db.rawQuery(
      'SELECT DISTINCT book_id, chapter FROM quiz_attempts ORDER BY book_id, chapter',
    );
    if (rows.isEmpty) return [];

    final stats = <QuizDepthStat>[];
    for (final row in rows) {
      final bookId = row['book_id'] as String;
      final chapter = (row['chapter'] as int?) ?? 0;

      final all = await dao.getByChapter(bookId, chapter);
      if (all.isEmpty) continue;

      final best = all.first.totalScore;
      final latest = all.last.totalScore;
      final attempts = all.length;

      // 取书名
      String bookTitle = bookId;
      try {
        final bookRow = await db.rawQuery(
          'SELECT title FROM books WHERE id = ?',
          [bookId],
        );
        if (bookRow.isNotEmpty) {
          bookTitle = bookRow.first['title'] as String? ?? bookId;
        }
      } catch (_) {}

      stats.add(
        QuizDepthStat(
          bookTitle: bookTitle,
          chapter: chapter,
          bestScore: best,
          totalAttempts: attempts,
          latestScore: latest,
        ),
      );
    }
    return stats;
  }
}
