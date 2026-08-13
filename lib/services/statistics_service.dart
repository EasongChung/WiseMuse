import 'package:sqflite/sqflite.dart';

import '../core/models/learning_record.dart';
import '../core/models/word_entry.dart';
import '../core/storage/database.dart';
import '../core/storage/learning_record_dao.dart';
import '../core/storage/word_entry_dao.dart';

/// [v0.1.0] 学习统计：聚合生词掌握率、学习记录与错词分布。
///
/// 纯读取聚合，不修改数据。数据来源：
/// - 生词本（[WordEntryDao]）：总数/掌握度/错次数
/// - 学习记录（[LearningRecordDao]）：各类型次数与平均分、每日活动
class LearningStats {
  const LearningStats({
    required this.wordCount,
    required this.masteredCount,
    required this.unmasteredCount,
    required this.masteryRate,
    required this.followCount,
    required this.followAvg,
    required this.dictationCount,
    required this.dictationAvg,
    required this.quizCount,
    required this.quizAvg,
    required this.reviewCount,
    required this.reviewAvg,
    required this.topWrongWords,
    required this.dailyActivity,
  });

  /// 生词总数。
  final int wordCount;

  /// 已掌握数（mastery ≥ 3）。
  final int masteredCount;

  /// 未掌握数（mastery < 3）。
  final int unmasteredCount;

  /// 掌握率 0-1（无生词时为 0）。
  final double masteryRate;

  /// 跟读次数与平均分。
  final int followCount;
  final double followAvg;

  /// 听写次数与平均分。
  final int dictationCount;
  final double dictationAvg;

  /// 复习次数与平均分。
  final int reviewCount;
  final double reviewAvg;

  /// 测验次数与平均分。
  final int quizCount;
  final double quizAvg;

  /// 错词分布（按 wrongCount 降序 Top10，仅含错次>0）。
  final List<WordEntry> topWrongWords;

  /// 最近 7 天每日学习活动（key=当天 00:00，value=学习记录数）。
  /// 键始终包含最近 7 天，无记录的天为 0。
  final Map<DateTime, int> dailyActivity;
}

class StatisticsService {
  /// 掌握阈值（与生词本一致：mastery ≥ 3 视为已掌握）。
  static const int masteredThreshold = 3;

  /// 错词分布展示条数。
  static const int topWrongLimit = 10;

  /// 学习活动统计天数。
  static const int activityDays = 7;

  /// 聚合统计。
  ///
  /// 默认读取全局库 [DatabaseProvider.database]；测试可注入 [db]（内存库）隔离。
  Future<LearningStats> load({Database? db}) async {
    final database = db ?? await DatabaseProvider.database;
    final wordDao = WordEntryDao(database);
    final recordDao = LearningRecordDao(database);

    final words = await wordDao.getAll();
    final wordCount = words.length;
    final masteredCount =
        words.where((w) => w.mastery >= masteredThreshold).length;
    final unmasteredCount = wordCount - masteredCount;
    final masteryRate = wordCount == 0 ? 0.0 : masteredCount / wordCount;

    final followCount = await recordDao.countByType(LearningType.follow);
    final followAvg = await recordDao.avgResultByType(LearningType.follow);
    final dictationCount = await recordDao.countByType(LearningType.dictation);
    final dictationAvg = await recordDao.avgResultByType(
      LearningType.dictation,
    );
    final reviewCount = await recordDao.countByType(LearningType.review);
    final reviewAvg = await recordDao.avgResultByType(LearningType.review);
    final quizCount = await recordDao.countByType(LearningType.quiz);
    final quizAvg = await recordDao.avgResultByType(LearningType.quiz);

    final topWrongWords =
        words.where((w) => w.wrongCount > 0).toList()
          ..sort((a, b) => b.wrongCount.compareTo(a.wrongCount));
    final topWrong = topWrongWords.take(topWrongLimit).toList();

    final recent = await recordDao.getRecent(limit: 5000);
    final daily = _aggregateDaily(recent, activityDays);

    return LearningStats(
      wordCount: wordCount,
      masteredCount: masteredCount,
      unmasteredCount: unmasteredCount,
      masteryRate: masteryRate,
      followCount: followCount,
      followAvg: followAvg,
      dictationCount: dictationCount,
      dictationAvg: dictationAvg,
      reviewCount: reviewCount,
      reviewAvg: reviewAvg,
      quizCount: quizCount,
      quizAvg: quizAvg,
      topWrongWords: topWrong,
      dailyActivity: daily,
    );
  }

  /// 把学习记录按「天」聚合为最近 [days] 天的活动量。
  ///
  /// [at] 为微秒时间戳。返回的 Map 键为每天 00:00（当天 0 点），
  /// 始终包含最近 [days] 天，无记录的天计 0。
  static Map<DateTime, int> _aggregateDaily(
    List<LearningRecord> records,
    int days,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daily = <DateTime, int>{};
    for (var i = days - 1; i >= 0; i--) {
      final day = today.subtract(Duration(days: i));
      daily[DateTime(day.year, day.month, day.day)] = 0;
    }
    for (final r in records) {
      final at = DateTime.fromMicrosecondsSinceEpoch(r.at);
      final day = DateTime(at.year, at.month, at.day);
      if (daily.containsKey(day)) {
        daily[day] = daily[day]! + 1;
      }
    }
    return daily;
  }
}
