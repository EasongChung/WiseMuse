import 'dart:math' as math;

import '../../core/models/knowledge_point.dart';

/// 测验阶段。
enum QuizStage {
  recognition('基础认读'),
  understanding('词句理解'),
  expansion('拓展应用');

  const QuizStage(this.label);
  final String label;
}

/// 题型枚举。
enum QuestionType {
  /// 朗读评分（TTS→录音→ASR→跟读评分器）。
  read('朗读认读', stage: QuizStage.recognition),

  /// 听音选字（4 选 1）。
  charSelect('听音选字', stage: QuizStage.recognition),

  /// 词句释义选择题（根据释义选词或选释义）。
  meaningChoice('词句理解', stage: QuizStage.understanding),

  /// AI 生成情境拓展选择题。
  choice('拓展应用', stage: QuizStage.expansion);

  const QuestionType(this.label, {required this.stage});
  final String label;
  final QuizStage stage;
}

/// 一道测验题目。
class QuizQuestion {
  const QuizQuestion({
    required this.type,
    required this.target,
    this.prompt,
    this.options,
    this.correctAnswer,
    this.explanation,
    this.knowledgePoint,
  });

  /// 题型。
  final QuestionType type;

  /// 题目目标（朗读的句子、选字/选择题的正确项）。
  final String target;

  /// 题干引导语（如“请听读音选出正确的汉字”）。
  final String? prompt;

  /// 选字/选择题的选项（已打乱）。
  final List<String>? options;

  /// 标准正确答案内容（默认即 target）。
  final String? correctAnswer;

  /// 答案解析。
  final String? explanation;

  /// 关联的知识点（用于答错写入掌握度）。
  final KnowledgePoint? knowledgePoint;

  String get effectiveAnswer => correctAnswer ?? target;
}

/// [v0.3.0] [v0.1.62] 出题器（纯函数）：支持三阶分级题型构建与错题专项强化池。
class QuizQuestionBuilder {
  const QuizQuestionBuilder._();

  static const int maxRead = 6;
  static const int maxCharSelect = 4;
  static const int maxMeaning = 4;
  static const int maxChoice = 2;

  /// 从知识点列表生成三阶分级测验题目。
  static List<QuizQuestion> buildQuestions(
    List<KnowledgePoint> knowledgePoints, {
    bool hasAi = false,
    Map<String, int> wrongWords = const {},
  }) {
    if (knowledgePoints.isEmpty) return [];

    final questions = <QuizQuestion>[];
    final rng = math.Random();

    // 1. 第一阶：基础认读 (charSelect + read)
    // 听音选字（中文单字优先）
    final charPool =
        knowledgePoints
            .where(
              (kp) =>
                  kp.type == KnowledgeType.word &&
                  kp.text.length == 1 &&
                  RegExp(r'[一-龥]').hasMatch(kp.text),
            )
            .toList();
    final weightedCharPool = _weightedPool(charPool, wrongWords);
    for (
      var i = 0;
      i < weightedCharPool.length && questions.length < maxCharSelect;
      i++
    ) {
      final correct = weightedCharPool[i].text;
      final distractors = _pickDistractors(charPool, correct, count: 3);
      final options = [correct, ...distractors]..shuffle(rng);
      questions.add(
        QuizQuestion(
          type: QuestionType.charSelect,
          target: correct,
          prompt: '请听读音，选出正确的汉字：',
          options: options,
          knowledgePoint: weightedCharPool[i],
          explanation: '汉字「$correct」的正确读音与字形如上。',
        ),
      );
    }

    // 朗读评分
    final readPool = _weightedPool(knowledgePoints, wrongWords);
    for (
      var i = 0;
      i < readPool.length && questions.length < maxCharSelect + maxRead;
      i++
    ) {
      final kp = readPool[i];
      if (questions.any(
        (q) => q.type == QuestionType.read && q.target == kp.text,
      )) {
        continue;
      }
      questions.add(
        QuizQuestion(
          type: QuestionType.read,
          target: kp.text,
          prompt: '请点击播放聆听，并大声跟读出来：',
          knowledgePoint: kp,
          explanation:
              kp.definition != null && kp.definition!.isNotEmpty
                  ? '释义：${kp.definition}'
                  : '字词「${kp.text}」要读准声调哦。',
        ),
      );
    }

    // 2. 第二阶：词句理解 (meaningChoice)
    final meaningPool =
        knowledgePoints
            .where(
              (kp) => kp.definition != null && kp.definition!.trim().isNotEmpty,
            )
            .toList();
    final weightedMeaningPool = _weightedPool(meaningPool, wrongWords);
    for (
      var i = 0;
      i < weightedMeaningPool.length &&
          questions.length < maxCharSelect + maxRead + maxMeaning;
      i++
    ) {
      final kp = weightedMeaningPool[i];
      final correct = kp.text;
      final otherKps =
          meaningPool.where((other) => other.text != correct).toList();
      otherKps.shuffle(rng);
      final distractors = otherKps.take(3).map((e) => e.text).toList();
      while (distractors.length < 3) {
        distractors.add('干扰项${distractors.length + 1}');
      }
      final options = [correct, ...distractors]..shuffle(rng);
      questions.add(
        QuizQuestion(
          type: QuestionType.meaningChoice,
          target: correct,
          prompt: '根据释义「${kp.definition}」，选出对应的词语：',
          options: options,
          correctAnswer: correct,
          knowledgePoint: kp,
          explanation: '「$correct」的意思是：${kp.definition}',
        ),
      );
    }

    // 3. 第三阶：拓展应用 (choice)
    if (hasAi) {
      final choicePool = _weightedPool(knowledgePoints, wrongWords);
      for (
        var i = 0;
        i < choicePool.length &&
            questions.length < maxCharSelect + maxRead + maxMeaning + maxChoice;
        i++
      ) {
        final kp = choicePool[i];
        questions.add(
          QuizQuestion(
            type: QuestionType.choice,
            target: kp.text,
            prompt: '关于「${kp.text}」，请选出在下列句子中使用最恰当的一项：',
            knowledgePoint: kp,
            explanation: '结合课文上下文理解「${kp.text}」的使用场景。',
          ),
        );
      }
    }

    return questions;
  }

  /// 针对错词生成专项强化测验题目。
  static List<QuizQuestion> buildWrongWordQuestions(
    List<String> wrongWords,
    List<KnowledgePoint> allPoints,
  ) {
    if (wrongWords.isEmpty) return [];
    final questions = <QuizQuestion>[];
    final rng = math.Random();
    final pointMap = {for (final p in allPoints) p.text: p};

    for (final word in wrongWords.take(15)) {
      final kp = pointMap[word];
      // 单字听音选字
      if (word.length == 1 && RegExp(r'[一-龥]').hasMatch(word)) {
        final charPool =
            allPoints
                .where((p) => p.text.length == 1 && p.text != word)
                .map((p) => p.text)
                .toList();
        charPool.shuffle(rng);
        final distractors = charPool.take(3).toList();
        while (distractors.length < 3) {
          distractors.add('备选${distractors.length + 1}');
        }
        questions.add(
          QuizQuestion(
            type: QuestionType.charSelect,
            target: word,
            prompt: '【错词强化】请听读音选出汉字：',
            options: [word, ...distractors]..shuffle(rng),
            knowledgePoint: kp,
            explanation: '注意「$word」的字形与发音区别。',
          ),
        );
      } else if (kp?.definition != null && kp!.definition!.isNotEmpty) {
        // 词义选择
        final otherWords =
            allPoints
                .where((p) => p.text != word && p.text.isNotEmpty)
                .map((p) => p.text)
                .toList();
        otherWords.shuffle(rng);
        final distractors = otherWords.take(3).toList();
        while (distractors.length < 3) {
          distractors.add('词语${distractors.length + 1}');
        }
        questions.add(
          QuizQuestion(
            type: QuestionType.meaningChoice,
            target: word,
            prompt: '【错词强化】根据释义「${kp.definition}」选出词语：',
            options: [word, ...distractors]..shuffle(rng),
            correctAnswer: word,
            knowledgePoint: kp,
            explanation: '「$word」的释义：${kp.definition}',
          ),
        );
      } else {
        // 朗读强化
        questions.add(
          QuizQuestion(
            type: QuestionType.read,
            target: word,
            prompt: '【错词强化】请大声跟读发音：',
            knowledgePoint: kp,
            explanation: '多加朗读练习能帮助牢牢记住「$word」！',
          ),
        );
      }
    }

    return questions;
  }

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
    mandatory.shuffle(math.Random());
    result.addAll(mandatory);
    high.shuffle(math.Random());
    result.addAll(high);
    result.addAll(high);
    normal.shuffle(math.Random());
    result.addAll(normal);
    return result;
  }

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
    final result = candidates.take(count).toList();
    final defaultChars = ['天', '地', '人', '你', '我', '他', '山', '水', '日', '月'];
    defaultChars.shuffle(math.Random());
    for (final ch in defaultChars) {
      if (result.length >= count) break;
      if (ch != correct && !result.contains(ch)) {
        result.add(ch);
      }
    }
    return result;
  }
}
