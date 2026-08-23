/// [v0.3.0] AI 智能助教：推荐复习 + 知识点讲解。
///
/// 根据错词/答题历史从知识库筛选未掌握知识点，对接 [AiService] 双引擎生成讲解。
library;

import '../core/debug/app_log.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import 'ai_service.dart';

/// AI 智能助教（单例）。
class AiTutorService {
  AiTutorService._();

  static final AiTutorService instance = AiTutorService._();

  static const _tag = 'ai_tutor';

  /// 获取今日推荐复习知识点。
  ///
  /// 策略（无 AI 回落）：
  /// 1. 从 [KnowledgePointDao.getUnmastered] 取所有未掌握知识点
  /// 2. 按掌握度升序（掌握度最低优先）+ 答错次数降序排序
  /// 3. 取前 [count] 条返回
  ///
  /// 若云端 AI 可用，额外用 [AiService] 对候选集做智能排序（选最需强化内容）。
  Future<List<String>> getRecommendation({int count = 5}) async {
    try {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      final points = await dao.getUnmastered();

      if (points.isEmpty) return [];

      // 基础排序：掌握度升序 → 答错降序
      points.sort((a, b) {
        final cmp = a.mastery.compareTo(b.mastery);
        if (cmp != 0) return cmp;
        return b.wrongCount.compareTo(a.wrongCount);
      });

      // 云端或本地任一引擎可用时，让 AI 从候选集中精排。
      final ai = AiService();
      if (await ai.isCloudReady() || await ai.isLocalReady()) {
        final candidateTexts = points
            .take(count * 2)
            .map((p) => p.text)
            .join('\n');
        final prompt =
            '你是学习助教，请从以下知识点中选出最需要复习的 $count 项，'
            '按重要性从高到低排列，只返回知识点文本，每行一个：\n\n$candidateTexts';
        final result = await ai.complete(prompt, predictLength: 200);
        if (result != null && result.text.isNotEmpty) {
          final lines =
              result.text
                  .split('\n')
                  .map((l) => l.trim())
                  .where((l) => l.isNotEmpty)
                  .toList();
          if (lines.length >= count) return lines.take(count).toList();
          // AI 返回不足，用候选填充
          final recommended = lines.toSet();
          return [
            ...lines,
            ...points
                .map((p) => p.text)
                .where((t) => !recommended.contains(t))
                .take(count - lines.length),
          ];
        }
      }

      // 纯本地排序
      return points.take(count).map((p) => p.text).toList();
    } catch (e, s) {
      AppLog.e(_tag, '获取推荐失败: $e\n$s');
      return [];
    }
  }

  /// 针对知识点展开讲解。
  ///
  /// [text] 知识点文本（词语/成语/诗句/单词）。
  /// 返回 AI 生成的讲解 Markdown，失败返回 null。
  Future<String?> explain(String text) async {
    try {
      final prompt =
          '你是一个小学生学习助教。请用生动易懂的方式讲解「$text」。\n\n'
          '要求：\n'
          '- 语言简洁活泼，适合 6-12 岁儿童\n'
          '- 包含释义、用法和一个生活化的例句\n'
          '- 用 Markdown 格式输出（标题、列表、加粗）\n'
          '- 总字数控制在 150 字以内\n'
          '- 返回纯文本 Markdown，不要包裹代码围栏';

      final ai = AiService();
      final result = await ai.complete(prompt, predictLength: 512);
      if (result != null && result.text.isNotEmpty) {
        // 去掉可能的围栏包裹
        var text = result.text.trim();
        if (text.startsWith('```') && text.endsWith('```')) {
          text = text.substring(text.indexOf('\n') + 1, text.length - 3).trim();
        }
        return text;
      }
      return null;
    } catch (e, s) {
      AppLog.e(_tag, '讲解生成失败: $e\n$s');
      return null;
    }
  }
}
