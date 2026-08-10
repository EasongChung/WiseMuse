import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/core/models/learning_record.dart';
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
      expect(LearningType.fromName('未知'), LearningType.review);
      expect(LearningType.fromName(null), LearningType.review);
    });
  });
}
