import 'dart:math' as math;

import '../../core/models/knowledge_point.dart';

/// [v0.3.0] 章节测验出题器（纯函数）。
///
/// 三种题型：
/// - [QuestionType.read]：朗读评分——从知识点中取出所有可朗读项，每项一题
/// - [QuestionType.charSelect]：听音选字——仅限中文单字知识点
/// - [QuestionType.choice]：AI 选择题——需 AiService 生成（无 AI 时跳过此题型）
///
/// 题型数量分配：
/// - read：全部候选，最多 [maxRead]

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
  static List<QuizQuestion> buildQuestions(
    List<KnowledgePoint> knowledgePoints, {
    bool hasAi = false,
  }) {
    if (knowledgePoints.isEmpty) return [];

    final questions = <QuizQuestion>[];
    final rng = math.Random();

    // 1) read 题型：所有知识点中选最多 maxRead 个
    final readPool = List<KnowledgePoint>.of(knowledgePoints);
    readPool.shuffle(rng);
    for (var i = 0; i < readPool.length && questions.length < maxRead; i++) {
      questions.add(
        QuizQuestion(
          type: QuestionType.read,
          target: readPool[i].text,
          knowledgePoint: readPool[i],
        ),
      );
    }

    // 2) charSelect 题型：仅中文单字知识点
    final charPool =
        knowledgePoints
            .where(
              (kp) =>
                  kp.type == KnowledgeType.word &&
                  kp.text.length == 1 &&
                  // 仅限中文字符（非英文/数字）
                  RegExp(r'[一-鿿]').hasMatch(kp.text),
            )
            .toList()
          ..shuffle(rng);
    for (
      var i = 0;
      i < charPool.length && questions.length < maxRead + maxCharSelect;
      i++
    ) {
      // 生成 4 个选项（正确答案 + 3 个干扰字）
      final correct = charPool[i].text;
      final distractors = _pickDistractors(charPool, correct, count: 3);
      final options = [correct, ...distractors]..shuffle(rng);
      questions.add(
        QuizQuestion(
          type: QuestionType.charSelect,
          target: correct,
          options: options,
          knowledgePoint: charPool[i],
        ),
      );
    }

    // 3) choice 题型：需要 AI 引擎
    if (hasAi) {
      final choicePool = List<KnowledgePoint>.of(knowledgePoints);
      choicePool.shuffle(rng);
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
