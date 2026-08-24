import '../core/debug/app_log.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/storage/word_entry_dao.dart';
import '../core/utils/json_util.dart';
import 'ai_service.dart';

/// 结构化 AI 助教启发式讲解模型。
class TutorExplanation {
  const TutorExplanation({
    required this.target,
    required this.meaning,
    required this.example,
    required this.question,
  });

  final String target;
  final String meaning;
  final String example;
  final String question;

  /// 转为 Markdown 展示。
  String toMarkdown() {
    return '''### 📖 词句释义
$meaning

### 💡 生活小场景
$example

### 🤔 想一想
$question''';
  }
}

/// 助教变式小挑战题目模型。
class TutorChallenge {
  const TutorChallenge({
    required this.question,
    required this.options,
    required this.correctAnswer,
    required this.explanation,
  });

  final String question;
  final List<String> options;
  final String correctAnswer;
  final String explanation;
}

/// [v0.3.0] [v0.1.62] AI 智能助教服务：启发式多维讲解 + 变式练习挑战 + 错题与薄弱点综合推荐。
class AiTutorService {
  AiTutorService._internal({AiService? ai}) : _ai = ai ?? AiService();

  static final AiTutorService instance = AiTutorService._internal();

  final AiService _ai;
  static const _tag = 'ai_tutor';

  /// 测试用构造器。
  factory AiTutorService({AiService? ai}) => AiTutorService._internal(ai: ai);

  /// 获取今日推荐复习知识点（融合知识库掌握度与错题本频次）。
  Future<List<String>> getRecommendation({int count = 5}) async {
    try {
      final db = await DatabaseProvider.database;
      final kpDao = KnowledgePointDao(db);
      final wordDao = WordEntryDao(db);

      final points = await kpDao.getUnmastered(threshold: 3);
      final wrongWords = await wordDao.getUnmastered(threshold: 3);

      final candidateList = <String>[];
      final seen = <String>{};

      // 1. 优先放入生词本错词
      for (final w in wrongWords) {
        final t = w.word.trim();
        if (t.isNotEmpty && seen.add(t)) candidateList.add(t);
      }

      // 2. 放入含汉字的多字重点词语
      for (final p in points) {
        final t = p.text.trim();
        if (RegExp(r'[一-龥]').hasMatch(t) && seen.add(t)) {
          candidateList.add(t);
        }
      }

      // 3. 放入其余知识点（如单字/字母/拼音）
      for (final p in points) {
        final t = p.text.trim();
        if (t.isNotEmpty && seen.add(t)) candidateList.add(t);
      }

      if (candidateList.isEmpty) {
        return const ['春天', '温暖', '学习', '认真', '快乐'];
      }

      // 若 AI 可用，进行智能重点精排
      if (await _ai.isCloudReady() || await _ai.isLocalReady()) {
        final candidateTexts = candidateList.take(count * 3).join('\n');
        final prompt =
            '你是少儿智能学习助教。请从以下字词中挑选出最适合小学生优先复习掌握的 $count 个词语，'
            '按重要性和基础程度从高到低排列，每行只输出一个词语，严禁输出编号和多余符号：\n\n$candidateTexts';

        final result = await _ai.complete(prompt, predictLength: 200);
        if (result != null && result.text.isNotEmpty) {
          final lines =
              result.text
                  .split('\n')
                  .map((l) => l.replaceAll(RegExp(r'^\d+[\.、\s]+'), '').trim())
                  .where((l) => l.isNotEmpty)
                  .toList();
          if (lines.length >= count) return lines.take(count).toList();
          final seen = lines.toSet();
          return [
            ...lines,
            ...candidateList
                .where((t) => !seen.contains(t))
                .take(count - lines.length),
          ];
        }
      }

      return candidateList.take(count).toList();
    } catch (e, s) {
      AppLog.e(_tag, '获取推荐失败: $e\n$s');
      return const [];
    }
  }

  /// 获取结构化启发式助教讲解。
  Future<TutorExplanation?> explainStructured(
    String text, {
    String? context,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return null;

    try {
      final prompt =
          '''你是一个亲切耐心的少儿智能学习助教。请针对「$cleanText」为小学 6-12 岁儿童生成生动、启发式的讲解。
${context != null && context.isNotEmpty ? '所属课文语境：$context\n' : ''}
要求：
1. 语言亲切通俗、富有趣味，严禁说教式大话。
2. 给出 1 个贴近小学生日常校园或家庭生活的小场景或趣味小例句。
3. 提出 1 个启发性的小问题引发思考，不直给答案。
请严格输出符合以下结构的 JSON 对象：
{
  "meaning": "通俗生动的释义（60字以内）",
  "example": "生活小场景或趣味例句（60字以内）",
  "question": "启发思考的小提问（40字以内）"
}''';

      final result = await _ai.complete(
        prompt,
        jsonObject: true,
        predictLength: 512,
      );
      if (result != null && result.text.isNotEmpty) {
        final parsed = parseLooseJsonObject(result.text);
        if (parsed != null) {
          final meaning = (parsed['meaning'] as String?)?.trim() ?? '暂无释义';
          final example = (parsed['example'] as String?)?.trim() ?? '暂无例句';
          final question =
              (parsed['question'] as String?)?.trim() ?? '你在日常生活中见过它吗？';
          return TutorExplanation(
            target: cleanText,
            meaning: meaning,
            example: example,
            question: question,
          );
        }
      }
    } catch (e, s) {
      AppLog.e(_tag, '结构化讲解失败: $e\n$s');
    }

    // AI 失败时的规则兜底
    return TutorExplanation(
      target: cleanText,
      meaning: '「$cleanText」是值得重点掌握的词语，多读多写能帮你更好理解它的含义。',
      example: '小明在作文里用到了「$cleanText」，老师夸他用词生动准确！',
      question: '试着用「$cleanText」说一句话，分享给爸爸妈妈听听吧！',
    );
  }

  /// 针对知识点展开讲解（Markdown 格式，兼容旧调用）。
  Future<String?> explain(String text) async {
    final structured = await explainStructured(text);
    return structured?.toMarkdown();
  }

  /// 针对薄弱词生成 1 道变式巩固选择题。
  Future<TutorChallenge?> generateSimilarChallenge(String text) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return null;

    try {
      final prompt =
          '''你是一个少儿教师。请围绕「$cleanText」生成 1 道适合小学生的单项选择题（4选1），考查词义理解或近反义词或句子填空。
请严格输出 JSON 对象：
{
  "question": "题目题干（如：下列句子中，哪个词使用最恰当？）",
  "options": ["选项A", "选项B", "选项C", "选项D"],
  "correct_answer": "正确选项内容（必须完全匹配 options 中的一项）",
  "explanation": "简要儿童化解析（40字以内）"
}''';

      final result = await _ai.complete(
        prompt,
        jsonObject: true,
        predictLength: 512,
      );
      if (result != null && result.text.isNotEmpty) {
        final parsed = parseLooseJsonObject(result.text);
        if (parsed != null) {
          final question =
              (parsed['question'] as String?)?.trim() ?? '请选出正确的选项：';
          final options = (parsed['options'] as List?)?.cast<String>() ?? [];
          final correct = (parsed['correct_answer'] as String?)?.trim() ?? '';
          final exp =
              (parsed['explanation'] as String?)?.trim() ?? '认真读题就能找到答案！';

          if (options.length >= 2 && correct.isNotEmpty) {
            return TutorChallenge(
              question: question,
              options: options,
              correctAnswer: correct,
              explanation: exp,
            );
          }
        }
      }
    } catch (e) {
      AppLog.w(_tag, '生成变式题失败: $e');
    }

    // 规则兜底变式题
    return TutorChallenge(
      question: '关于「$cleanText」，下列哪种说法最正确？',
      options: ['它是我们课文里学过的重要词语', '它的意思与书本毫无关系', '这个词从来不需要复习', '它是拼音不是汉字'],
      correctAnswer: '它是我们课文里学过的重要词语',
      explanation: '掌握好课文重点词语能让阅读和写作更轻松！',
    );
  }
}
