import '../core/models/knowledge_point.dart';
import '../core/models/learning_record.dart';
import '../core/models/word_entry.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/storage/learning_record_dao.dart';
import '../core/storage/word_entry_dao.dart';
import 'package:sqflite/sqflite.dart';

/// [v0.3.0] 掌握度服务：统一听写/跟读/复习结果落库规则。
///
/// 职责：
/// - 正确 → mastery+1（clamp 0-5），达阈自动清除知识点与生词
/// - 错误 → wrongCount+1（生词本中不存在自动插入）
/// - 复习 → mastery+1 + 写入 LearningRecord(review)
///
/// [v2.9.0] 新增双向同步：知识点与生词本的 mastery 达阈后自动清理。
class MasteryService {
  MasteryService._();

  /// 掌握度达此值时视为「已掌握」，自动从知识点与生词本中清除。
  static const int masteredThreshold = 3;

  /// 应用听写/跟读结果到生词本，达阈自动清除生词与对应知识点。
  ///
  /// [correct] 为 true 时 mastery+1 并检查阈值；false 时 wrongCount+1；
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
        existing.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
        await dao.update(existing);
        // 达阈 → 自动清理生词 + 对应知识点
        if (existing.mastery >= masteredThreshold) {
          await dao.delete(existing.id);
          _syncRemoveKnowledgePoint(db, word, bookId);
        }
      } else {
        existing.wrongCount++;
        existing.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
        await dao.update(existing);
      }
    } else if (!correct) {
      // 答错但不在生词本中 → 自动插入
      await dao.upsert(
        WordEntry.create(word: word, lang: lang, fromBookId: bookId),
      );
    }
  }

  /// 应用测验结果到知识点，达阈自动清除知识点与对应生词。
  static Future<void> applyKnowledgeResult(
    KnowledgePoint kp, {
    required bool correct,
  }) async {
    final db = await DatabaseProvider.database;
    final dao = KnowledgePointDao(db);
    if (correct) {
      kp.mastery = (kp.mastery + 1).clamp(0, 5);
      kp.updatedAt = DateTime.now().microsecondsSinceEpoch;
      await dao.update(kp);
      // 达阈 → 自动清理知识点 + 对应生词
      if (kp.mastery >= masteredThreshold) {
        await dao.delete(kp.id);
        _syncRemoveWordEntry(db, kp.text, kp.bookId);
      }
    } else {
      kp.wrongCount++;
      kp.updatedAt = DateTime.now().microsecondsSinceEpoch;
      await dao.update(kp);
    }
  }

  /// 复习记录，达阈自动清除生词。
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
    // 达阈 → 自动清理生词
    if (entry.mastery >= masteredThreshold) {
      await WordEntryDao(db).delete(entry.id);
      _syncRemoveKnowledgePoint(db, entry.word, entry.fromBookId);
    }
  }

  // ===== 双向同步辅助 =====

  /// 删除知识点表中文本匹配的记录。
  static Future<void> _syncRemoveKnowledgePoint(
    Database db,
    String text,
    String? bookId,
  ) async {
    final dao = KnowledgePointDao(db);
    final existing =
        bookId != null
            ? await dao.findByBookTypeText(bookId, KnowledgeType.word, text)
            : null;
    if (existing != null) {
      await dao.delete(existing.id);
    }
  }

  /// 删除生词本中匹配的记录。
  static Future<void> _syncRemoveWordEntry(
    Database db,
    String text,
    String? bookId,
  ) async {
    final dao = WordEntryDao(db);
    final existing = await dao.findByWord(text);
    if (existing != null) {
      await dao.delete(existing.id);
    }
  }
}
