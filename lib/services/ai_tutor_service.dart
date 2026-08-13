/// [v0.3.0] AI 智能助教（S7 预留骨架）。
///
/// 远期规划：
/// - 根据当前阅读页/错词/答题历史，自动推荐复习内容
/// - 基于知识点上下文展开讲解（成语故事、诗词赏析、单词构词）
/// - 与 AiService 双引擎对接（云端 + 本地回落）
///
/// 当前只有骨架，`getRecommendation()` 和 `explain()` 为占位方法。
class AiTutorService {
  AiTutorService._();

  static final AiTutorService instance = AiTutorService._();

  /// 获取今日推荐复习知识点。
  ///
  /// 从 KnowledgePointDao.getUnmastered() 中取掌握度最低的 [count] 条。
  Future<List<String>> getRecommendation({int count = 5}) async {
    // TODO(S7): 接入 AiService 根据错词/答题历史动态生成推荐
    return [];
  }

  /// 针对知识点展开讲解。
  ///
  /// [text] 知识点文本（词语/成语/诗句/单词）。
  /// 返回 AI 生成的讲解 Markdown，失败返回 null。
  Future<String?> explain(String text) async {
    // TODO(S7): 调用 AiService.complete(prompt) 生成讲解
    return null;
  }
}