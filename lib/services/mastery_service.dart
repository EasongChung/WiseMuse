import '../core/models/knowledge_point.dart';
import '../core/models/learning_record.dart';
import '../core/models/word_entry.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/storage/learning_record_dao.dart';
import '../core/storage/word_entry_dao.dart';

/// [v0.3.0] 掌握度服务：统一听写/跟读/复习结果落库规则。
///
/// 职责：
/// - 正确 → mastery+1（clamp 0-5）
/// - 错误 → wrongCount+1（生词本中不存在自动插入）
/// - 复习 → mastery+1 + 写入 LearningRecord(review)
class MasteryService {
  MasteryService._();

  /// 应用听写/跟读结果到生词本。
  ///
  /// [correct] 为 true 时 mastery+1，false 时 wrongCount+1；
  /// 错误且生词本中不存在时自动插入。
  static Future<void> applyWordResult(
    String word, {
    String lang = 'zh',
    required bool correct,
    String? bookId,
  }) async {
    final db = await DatabaseProvider.database;
    final dao = WordEntryDao(db);
    final existing = await dao.findByWord(word, lang: lang);
    if (existing != null) {
      if (correct) {
        existing.mastery = (existing.mastery + 1).clamp(0, 5);
      } else {
        existing.wrongCount++;
      }
      existing.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
      await dao.update(existing);
    } else if (!correct) {
      // 答错但不在生词本中 → 自动插入
      await dao.upsert(
        WordEntry.create(word: word, lang: lang, fromBookId: bookId),
      );
    }
  }

  /// 应用测验结果到知识点。
  static Future<void> applyKnowledgeResult(
    KnowledgePoint kp, {
    required bool correct,
  }) async {
    final db = await DatabaseProvider.database;
    final dao = KnowledgePointDao(db);
    if (correct) {
      kp.mastery = (kp.mastery + 1).clamp(0, 5);
    } else {
      kp.wrongCount++;
    }
    kp.updatedAt = DateTime.now().microsecondsSinceEpoch;
    await dao.update(kp);
  }

  /// 记录复习结果。
  ///
  /// mastery+1（clamp 0-5）+ 更新复习时间 + 写入 LearningRecord(review)。
  static Future<void> recordReview(WordEntry entry) async {
    final db = await DatabaseProvider.database;
    entry.mastery = (entry.mastery + 1).clamp(0, 5);
    entry.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
    await WordEntryDao(db).update(entry);
    await LearningRecordDao(db).insert(
      LearningRecord.create(
        type: LearningType.review,
        target: entry.word,
        result: 100.0,
      ),
    );
  }
}
