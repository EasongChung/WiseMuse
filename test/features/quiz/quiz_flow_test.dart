import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/knowledge_point.dart';
import 'package:wisemuse/features/quiz/quiz_question_builder.dart';
import 'package:wisemuse/features/quiz/quiz_scorer.dart';
import 'package:wisemuse/features/follow/scoring.dart';

void main() {
  group('QuizQuestionBuilder and Stages', () {
    test('buildQuestions 生成三阶题目', () {
      final points = [
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '日',
          definition: '太阳',
        ),
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '月',
          definition: '月亮',
        ),
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.idiom,
          text: '日积月累',
          definition: '长时间的积累',
        ),
      ];

      final questions = QuizQuestionBuilder.buildQuestions(
        points,
        hasAi: true,
        wrongWords: {'日积月累': 4}, // 必出
      );

      expect(questions, isNotEmpty);
      expect(questions.any((q) => q.type == QuestionType.charSelect), isTrue);
      expect(questions.any((q) => q.type == QuestionType.read), isTrue);
      expect(
        questions.any((q) => q.type == QuestionType.meaningChoice),
        isTrue,
      );
      expect(questions.any((q) => q.type == QuestionType.choice), isTrue);
    });

    test('buildWrongWordQuestions 生成错词强化题目', () {
      final points = [
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '天',
          definition: '天空',
        ),
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '光明磊落',
          definition: '胸怀坦白',
        ),
      ];

      final wrongQuestions = QuizQuestionBuilder.buildWrongWordQuestions([
        '天',
        '光明磊落',
        '未知错词',
      ], points);

      expect(wrongQuestions, hasLength(3));
      expect(wrongQuestions[0].type, QuestionType.charSelect);
      expect(wrongQuestions[0].target, '天');
      expect(wrongQuestions[1].type, QuestionType.meaningChoice);
      expect(wrongQuestions[1].target, '光明磊落');
      expect(wrongQuestions[2].type, QuestionType.read);
      expect(wrongQuestions[2].target, '未知错词');
    });

    test('QuizScorer 评分与星级计算', () {
      final score = QuizScorer.compute(100.0, 100.0, 100.0);
      expect(score, 100.0);
      expect(QuizScorer.starRating(score), 5);

      final midScore = QuizScorer.compute(60.0, 60.0, 60.0);
      expect(midScore, 60.0);
      expect(QuizScorer.starRating(midScore), 3);
    });
  });

  group('测验朗读题语音识别评分（v0.1.59）', () {
    test('朗读题在 buildQuestions 中生成且 target 可被 FollowScorer 评分', () {
      final points = [
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '太阳',
        ),
      ];
      final questions = QuizQuestionBuilder.buildQuestions(points);
      final readQ =
          questions.where((q) => q.type == QuestionType.read).toList();
      expect(readQ, isNotEmpty);
      for (final q in readQ) {
        final s = FollowScorer.scoreFollow(q.target, q.target);
        expect(s.score, 100);
        expect(s.passed, isTrue);
      }
    });

    test('ASR 判定：识别一致 → passed（≥80 自动判对）', () {
      final s = FollowScorer.scoreFollow('春眠不觉晓', '春眠不觉晓');
      expect(s.passed, isTrue);
    });

    test('ASR 判定：同音容错 → passed', () {
      final s = FollowScorer.scoreFollow('你好', '尼好');
      expect(s.score, 100);
      expect(s.passed, isTrue);
    });

    test('ASR 判定：漏读/错字 → 不通过（<80）', () {
      final s = FollowScorer.scoreFollow('今天真好', '今天很好');
      expect(s.passed, isFalse);
    });

    test('ASR 判定：空识别文本 → 0 分不通过', () {
      final s = FollowScorer.scoreFollow('你好', '');
      expect(s.score, 0);
      expect(s.passed, isFalse);
    });

    test('ASR 判定：识别含标点空白归一化后仍可判对', () {
      final s = FollowScorer.scoreFollow('你好。', '你 好，');
      expect(s.score, 100);
      expect(s.passed, isTrue);
    });
  });
}
