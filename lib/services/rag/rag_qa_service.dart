import '../../core/debug/app_log.dart';
import '../ai_service.dart';
import '../profile_service.dart';
import 'rag_retrieval_service.dart';

/// [v0.1.37] RAG 问答服务：基于教材内容的儿童友好问答。
///
/// 流程：
/// 1. [RagRetrievalService.retrieveContext] 检索教材相关片段
/// 2. 组装含原文上下文的 Prompt
/// 3. [AiService.complete] 生成回答（双引擎回落：云端 → 本地 llama）
/// 4. 返回 Markdown 格式的儿童友好回答
class RagQaService {
  RagQaService._();
  static final RagQaService instance = RagQaService._();

  static const _tag = 'rag_qa';

  final RagRetrievalService _retrieval = RagRetrievalService.instance;

  /// 基于教材内容回答问题。
  ///
  /// [bookId] 教材 ID；[question] 儿童提问原文。
  /// 返回 Markdown 格式回答（带教材引用）。失败/无索引返回 null。
  Future<String?> ask(String bookId, String question) async {
    if (question.trim().isEmpty) return null;

    // 检查索引
    if (!await _retrieval.isIndexed(bookId)) {
      AppLog.d(_tag, 'book=$bookId 未构建索引');
      return null;
    }

    // 检索相关上下文
    final ctx = await _retrieval.retrieveContext(bookId, question, topK: 3);
    if (ctx == null) {
      AppLog.d(_tag, '未检索到相关内容 book=$bookId query=$question');
      return '在教材中没有找到与「$question」相关的内容。\n\n试试换个说法提问，或者看看其他部分的内容哦！📖';
    }

    final (context, sourceInfo) = ctx;

    // 获取儿童名称用于个性化称呼
    final childName = await _getChildName();

    // 组装 Prompt
    final prompt = _buildPrompt(question, context, sourceInfo, childName);

    // 调用 AI 双引擎
    final ai = AiService();
    final result = await ai.complete(prompt, predictLength: 1024);
    if (result != null && result.text.isNotEmpty) {
      var answer = result.text.trim();
      // 去掉可能的代码围栏
      if (answer.startsWith('```') && answer.endsWith('```')) {
        answer =
            answer
                .substring(answer.indexOf('\n') + 1, answer.length - 3)
                .trim();
      }
      return answer;
    }

    // AI 不可用时的兜底回答
    final fallback = _buildFallbackAnswer(question, context);
    return fallback;
  }

  /// 检测某书是否已就绪（已索引）。
  Future<bool> isReady(String bookId) async {
    return _retrieval.isIndexed(bookId);
  }

  /// 构建 AI Prompt。
  String _buildPrompt(
    String question,
    String context,
    String sourceInfo,
    String childName,
  ) {
    final greeting = childName.isNotEmpty ? childName : '小朋友';
    return '''你是 $greeting 的学习小助手，请根据下面的教材内容回答问题。

教材原文片段（按相关度排列）：
$context

$greeting 的问题：$question

要求：
- 用活泼亲切、通俗易懂的语言回答，适合 6-12 岁儿童理解
- 尽量引用教材原文来支撑答案
- 如果问题在教材中找不到答案，诚实说「教材中没有提到哦」
- 回答末尾可以加一个鼓励或好奇的小问题
- 用 Markdown 格式输出（加粗关键词、小标题、emoji）
- 总字数控制在 200 字以内
- 不要使用代码围栏

回答参考来源：
$sourceInfo''';
  }

  /// AI 不可用时的兜底回答：直接展示相关教材片段。
  String _buildFallbackAnswer(String question, String context) {
    return '''关于「$question」，教材中这样说：

$context

💡 **小提示**：当前 AI 引擎未配置或不可用，以上是教材原文片段。
配置 AI 后可以获得更详细的解释哦！''';
  }

  /// 获取当前孩子的名称（用于个性化称呼）。
  Future<String> _getChildName() async {
    try {
      final profile = ProfileService.instance.current;
      if (profile != null && profile.name.isNotEmpty) return profile.name;
    } catch (_) {}
    return '';
  }
}
