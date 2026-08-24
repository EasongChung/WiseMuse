import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/knowledge_point.dart';
import 'package:wisemuse/features/quiz/quiz_question_builder.dart';
import 'package:wisemuse/features/quiz/quiz_scorer.dart';

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
}
