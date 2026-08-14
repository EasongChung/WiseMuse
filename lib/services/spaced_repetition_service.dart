import '../core/models/word_entry.dart';
import '../core/storage/database.dart';
import '../core/storage/word_entry_dao.dart';

/// [v2.9.0] 艾宾浩斯遗忘曲线调度引擎。
///
/// 基于掌握度（mastery 0-5）与上次复习时间，计算下次复习间隔，
/// 生成「今日待复习」任务列表。
///
/// 间隔表（艾宾浩斯遗忘曲线简化版）：
/// - mastery 0 → 当天/1 天后
/// - mastery 1 → 2 天后
/// - mastery 2 → 4 天后
/// - mastery 3 → 7 天后
/// - mastery 4 → 15 天后
/// - mastery 5 → 已牢固掌握（归档，不再出现）
class SpacedRepetitionService {
  SpacedRepetitionService._();

  /// mastery → 复习间隔（天）。
  static const Map<int, int> _intervals = {0: 1, 1: 2, 2: 4, 3: 7, 4: 15};

  /// 已达成的掌握度视为牢固，归档。
  static const int masteredThreshold = 5;

  /// 计算指定掌握度下的下次复习间隔（天）。
  static int intervalFor(int mastery) {
    final clamped = mastery.clamp(0, 4);
    return _intervals[clamped] ?? 1;
  }

  /// 判断某词是否今天到期复习。
  ///
  /// [nowMicros] 当前时间（微秒）；[lastReviewAt] 上次复习时间戳（微秒）。
  static bool isDue({
    required int mastery,
    int? lastReviewAt,
    required int nowMicros,
  }) {
    if (mastery >= masteredThreshold) return false; // 已归档
    if (lastReviewAt == null) return true; // 从未复习 → 立即复习
    final intervalDays = intervalFor(mastery);
    final dueAt = lastReviewAt + intervalDays * Duration.microsecondsPerDay;
    return nowMicros >= dueAt;
  }

  /// 查询「今日待复习」生词列表（到期或从未复习，按紧迫度排序）。
  static Future<List<WordEntry>> getDueWords({String? profileId}) async {
    final db = await DatabaseProvider.database;
    final dao = WordEntryDao(db, profileId: profileId);
    final all = await dao.getAll();
    final now = DateTime.now().microsecondsSinceEpoch;
    final due =
        all
            .where(
              (w) => isDue(
                mastery: w.mastery,
                lastReviewAt: w.lastReviewAt,
                nowMicros: now,
              ),
            )
            .toList();
    // 未复习优先、掌握度低优先、错误多优先
    due.sort((a, b) {
      if ((a.lastReviewAt == null) != (b.lastReviewAt == null)) {
        return a.lastReviewAt == null ? -1 : 1;
      }
      if (a.mastery != b.mastery) return a.mastery.compareTo(b.mastery);
      return b.wrongCount.compareTo(a.wrongCount);
    });
    return due;
  }

  /// 复习反馈后更新掌握度。
  ///
  /// 答对 → mastery+1（clamp 0-5）并更新 lastReviewAt；
  /// 答错 → wrongCount+1，mastery 回退 1（不低于 0），并更新 lastReviewAt。
  static Future<void> applyReviewResult(
    WordEntry entry, {
    required bool correct,
    String? profileId,
  }) async {
    final db = await DatabaseProvider.database;
    final dao = WordEntryDao(db, profileId: profileId);
    if (correct) {
      entry.mastery = (entry.mastery + 1).clamp(0, 5);
    } else {
      entry.mastery = (entry.mastery - 1).clamp(0, 5);
      entry.wrongCount++;
    }
    entry.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
    await dao.update(entry);
  }
}
