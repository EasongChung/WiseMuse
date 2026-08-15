import 'dart:math' as math;

import '../../core/models/knowledge_point.dart';

/// [v0.3.0] 章节测验出题器（纯函数）。
///
/// 三种题型：
/// - [QuestionType.read]：朗读评分——从知识点中取出所有可朗读项，每项一题
/// - [QuestionType.charSelect]：听音选字——仅限中文单字知识点
/// - [QuestionType.choice]：AI 选择题——需 AiService 生成（无 AI 时跳过此题型）
///
/// [v0.1.28] 个性化：通过 [wrongWords] 传入错词权重，高频错词优先出题。
/// - >3 次错 → 必出（强制入池）
/// - 1-2 次错 → 高概率（pool 中 2x 权重）
/// - 0 次错 → 正常概率

/// 题型枚举。
enum QuestionType {
  /// 朗读评分（TTS→录音→ASR→跟读评分器）。
  read('朗读'),

  /// 听音选字（4 选 1）。
  charSelect('听音选字'),

  /// AI 生成选择题（知识提取 + json_object）。
  choice('选择题');

  const QuestionType(this.label);
  final String label;
}

/// 一道测验题目。
class QuizQuestion {
  const QuizQuestion({
    required this.type,
    required this.target,
    this.options,
    this.knowledgePoint,
  });

  /// 题型。
  final QuestionType type;

  /// 题目目标（朗读的句子、选字/选择题的正确项）。
  final String target;

  /// 选字/选择题的选项（已打乱）。
  final List<String>? options;

  /// 关联的知识点（用于答错写入掌握度）。
  final KnowledgePoint? knowledgePoint;
}

/// [v0.3.0] 出题器（纯函数，可注入 Mock AiService 测试）。
class QuizQuestionBuilder {
  const QuizQuestionBuilder._();

  /// 最多朗读题数。
  static const int maxRead = 12;

  /// 最多听音选字题数。
  static const int maxCharSelect = 8;

  /// 最多选择题数（由 AiService 实际可用数决定）。
  static const int maxChoice = 6;

  /// 从知识点列表生成测验题目。
  ///
  /// [knowledgePoints] 本页/本章的知识点列表。
  /// [hasAi] 是否有 AI 引擎（否则跳过 choice 题型）。
  /// [wrongWords] [v0.1.28] 错词权重表 {word: wrongCount}，高频错词优先出题。
  static List<QuizQuestion> buildQuestions(
    List<KnowledgePoint> knowledgePoints, {
    bool hasAi = false,
    Map<String, int> wrongWords = const {},
  }) {
    if (knowledgePoints.isEmpty) return [];

    final questions = <QuizQuestion>[];
    final rng = math.Random();

    // 1) read 题型：按错词权重加权排序
    final readPool = _weightedPool(knowledgePoints, wrongWords);
    for (var i = 0; i < readPool.length && questions.length < maxRead; i++) {
      questions.add(
        QuizQuestion(
          type: QuestionType.read,
          target: readPool[i].text,
          knowledgePoint: readPool[i],
        ),
      );
    }

    // 2) charSelect 题型：仅中文单字知识点，按错词权重加权
    final charPool =
        knowledgePoints
            .where(
              (kp) =>
                  kp.type == KnowledgeType.word &&
                  kp.text.length == 1 &&
                  RegExp(r'[一-鿿]').hasMatch(kp.text),
            )
            .toList();
    final weightedCharPool = _weightedPool(charPool, wrongWords);
    for (
      var i = 0;
      i < weightedCharPool.length && questions.length < maxRead + maxCharSelect;
      i++
    ) {
      final correct = weightedCharPool[i].text;
      final distractors = _pickDistractors(charPool, correct, count: 3);
      final options = [correct, ...distractors]..shuffle(rng);
      questions.add(
        QuizQuestion(
          type: QuestionType.charSelect,
          target: correct,
          options: options,
          knowledgePoint: weightedCharPool[i],
        ),
      );
    }

    // 3) choice 题型：需要 AI 引擎，按错词权重加权
    if (hasAi) {
      final choicePool = _weightedPool(knowledgePoints, wrongWords);
      for (
        var i = 0;
        i < choicePool.length &&
            questions.length < maxRead + maxCharSelect + maxChoice;
        i++
      ) {
        questions.add(
          QuizQuestion(
            type: QuestionType.choice,
            target: choicePool[i].text,
            knowledgePoint: choicePool[i],
          ),
        );
      }
    }

    return questions;
  }

  /// [v0.1.28] 按错词权重生成加权池：高频错词在池中出现多次，提高出题概率。
  ///
  /// - wrongCount > 3 → 必出（3x）
  /// - wrongCount 1-2 → 高概率（2x）
  /// - wrongCount == 0 → 正常（1x）
  static List<KnowledgePoint> _weightedPool(
    List<KnowledgePoint> pool,
    Map<String, int> wrongWords,
  ) {
    final result = <KnowledgePoint>[];
    final mandatory = <KnowledgePoint>[];
    final high = <KnowledgePoint>[];
    final normal = <KnowledgePoint>[];
    for (final kp in pool) {
      final wc = wrongWords[kp.text] ?? 0;
      if (wc > 3) {
        mandatory.add(kp);
      } else if (wc >= 1) {
        high.add(kp);
      } else {
        normal.add(kp);
      }
    }
    // 必出项先添加（+ shuffle 后取全部）
    mandatory.shuffle(math.Random());
    result.addAll(mandatory);
    // 高概率项加 2 次
    high.shuffle(math.Random());
    result.addAll(high);
    result.addAll(high);
    // 正常项加 1 次
    normal.shuffle(math.Random());
    result.addAll(normal);
    return result;
  }

  /// 从知识点列表中选取 [count] 个不与 [correct] 相同的字作为干扰项。
  static List<String> _pickDistractors(
    List<KnowledgePoint> pool,
    String correct, {
    int count = 3,
  }) {
    final candidates =
        pool
            .where(
              (kp) =>
                  kp.type == KnowledgeType.word &&
                  kp.text.length == 1 &&
                  kp.text != correct,
            )
            .map((kp) => kp.text)
            .toSet()
            .toList();
    candidates.shuffle(math.Random());
    return candidates.take(count).toList();
  }
}
