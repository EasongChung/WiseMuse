import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/core/models/knowledge_point.dart';
import 'package:wisemuse/core/models/learning_record.dart';
import 'package:wisemuse/core/models/quiz_attempt.dart';
import 'package:wisemuse/core/models/word_entry.dart';

void main() {
  group('Book', () {
    test('create 生成唯一 id 与默认时间戳', () {
      final a = Book.create(title: '语文', source: BookSource.pdf);
      final b = Book.create(title: '语文', source: BookSource.pdf);
      expect(a.id, isNot(b.id));
      expect(a.createdAt, greaterThan(0));
      expect(a.updatedAt, a.createdAt);
    });

    test('toMap/fromMap round-trip', () {
      final book = Book.create(
        title: '语文一年级',
        source: BookSource.pdf,
        originalFilePath: '/data/originals/a.pdf',
      )..pageCount = 10;
      final restored = Book.fromMap(book.toMap());
      expect(restored.id, book.id);
      expect(restored.title, book.title);
      expect(restored.source, BookSource.pdf);
      expect(restored.originalFilePath, book.originalFilePath);
      expect(restored.pageCount, 10);
      expect(restored.createdAt, book.createdAt);
    });

    test('BookSource.fromName 兜底', () {
      expect(BookSource.fromName('pdf'), BookSource.pdf);
      expect(BookSource.fromName('camera'), BookSource.camera);
      expect(BookSource.fromName('未知'), BookSource.txt);
      expect(BookSource.fromName(null), BookSource.txt);
    });
  });

  group('WordEntry', () {
    test('create 初始 mastery=0', () {
      final w = WordEntry.create(word: '苹果', lang: 'zh');
      expect(w.mastery, 0);
      expect(w.wrongCount, 0);
      expect(w.addedAt, greaterThan(0));
    });

    test('toMap/fromMap round-trip', () {
      final w =
          WordEntry.create(word: 'apple', lang: 'en', fromBookId: 'b1')
            ..mastery = 3
            ..wrongCount = 2
            ..lastReviewAt = 12345;
      final r = WordEntry.fromMap(w.toMap());
      expect(r.id, w.id);
      expect(r.word, 'apple');
      expect(r.lang, 'en');
      expect(r.fromBookId, 'b1');
      expect(r.mastery, 3);
      expect(r.wrongCount, 2);
      expect(r.lastReviewAt, 12345);
    });
  });

  group('KnowledgePoint', () {
    test('create 生成唯一 id 与默认值', () {
      final kp = KnowledgePoint.create(type: KnowledgeType.word, text: '学习');
      expect(kp.id, startsWith('kp_'));
      expect(kp.mastery, 0);
      expect(kp.wrongCount, 0);
      expect(kp.source, 'ai');
      expect(kp.type, KnowledgeType.word);
      expect(kp.text, '学习');
      expect(kp.bookId, isNull);
    });

    test('toMap/fromMap round-trip', () {
      final kp =
          KnowledgePoint.create(
              bookId: 'b1',
              page: 3,
              chapter: 1,
              type: KnowledgeType.idiom,
              text: '画蛇添足',
              definition: '比喻做了多余的事',
              extra: '{"pinyin":"huà shé tiān zú"}',
              source: 'manual',
            )
            ..mastery = 2
            ..wrongCount = 1;
      final restored = KnowledgePoint.fromMap(kp.toMap());
      expect(restored.id, kp.id);
      expect(restored.bookId, 'b1');
      expect(restored.page, 3);
      expect(restored.chapter, 1);
      expect(restored.type, KnowledgeType.idiom);
      expect(restored.text, '画蛇添足');
      expect(restored.definition, '比喻做了多余的事');
      expect(restored.extra, contains('pinyin'));
      expect(restored.source, 'manual');
      expect(restored.mastery, 2);
      expect(restored.wrongCount, 1);
      expect(restored.createdAt, greaterThan(0));
      expect(restored.updatedAt, kp.updatedAt);
    });

    test('KnowledgeType.fromName 兜底', () {
      expect(KnowledgeType.fromName('word'), KnowledgeType.word);
      expect(KnowledgeType.fromName('idiom'), KnowledgeType.idiom);
      expect(KnowledgeType.fromName('english'), KnowledgeType.english);
      expect(KnowledgeType.fromName('poem'), KnowledgeType.poem);
      expect(KnowledgeType.fromName('未知'), KnowledgeType.word);
      expect(KnowledgeType.fromName(null), KnowledgeType.word);
    });
  });

  group('QuizAttempt', () {
    test('create 生成唯一 id 与默认字段', () {
      final q = QuizAttempt.create(
        bookId: 'b1',
        chapter: 0,
        totalScore: 85,
        questionCount: 10,
        correctCount: 7,
      );
      expect(q.id, startsWith('quiz_'));
      expect(q.bookId, 'b1');
      expect(q.totalScore, 85);
      expect(q.questionCount, 10);
      expect(q.correctCount, 7);
      expect(q.page, isNull);
      expect(q.detail, isNull);
    });

    test('toMap/fromMap round-trip', () {
      final q = QuizAttempt.create(
        bookId: 'b1',
        chapter: 1,
        page: 5,
        totalScore: 90.5,
        questionCount: 8,
        correctCount: 6,
        detail: '[{"type":"read","correct":true}]',
      );
      final restored = QuizAttempt.fromMap(q.toMap());
      expect(restored.id, q.id);
      expect(restored.bookId, 'b1');
      expect(restored.chapter, 1);
      expect(restored.page, 5);
      expect(restored.totalScore, 90.5);
      expect(restored.questionCount, 8);
      expect(restored.correctCount, 6);
      expect(restored.detail, contains('type'));
      expect(restored.at, greaterThan(0));
    });
  });

  group('LearningRecord', () {
    test('toMap/fromMap round-trip', () {
      final r = LearningRecord.create(
        type: LearningType.dictation,
        target: '苹果',
        result: 80,
        detail: '{"w":"苹果","ok":true}',
      );
      final restored = LearningRecord.fromMap(r.toMap());
      expect(restored.id, r.id);
      expect(restored.type, LearningType.dictation);
      expect(restored.target, '苹果');
      expect(restored.result, 80);
      expect(restored.detail, contains('ok'));
      expect(restored.at, r.at);
    });

    test('LearningType.fromName 兜底', () {
      expect(LearningType.fromName('follow'), LearningType.follow);
      expect(LearningType.fromName('quiz'), LearningType.quiz);
      expect(LearningType.fromName('未知'), LearningType.review);
      expect(LearningType.fromName(null), LearningType.review);
    });
  });
}
