import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/core/models/knowledge_point.dart';
import 'package:wisemuse/core/models/learning_record.dart';
import 'package:wisemuse/core/models/quiz_attempt.dart';
import 'package:wisemuse/core/models/word_entry.dart';
import 'package:wisemuse/core/storage/book_dao.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/knowledge_point_dao.dart';
import 'package:wisemuse/core/storage/learning_record_dao.dart';
import 'package:wisemuse/core/storage/quiz_attempt_dao.dart';
import 'package:wisemuse/core/storage/word_entry_dao.dart';

void main() {
  setUpAll(() {
    // 桌面/测试环境用 FFI 库替代 Android sqflite
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late BookDao bookDao;
  late WordEntryDao wordDao;
  late LearningRecordDao recordDao;

  // 每个测试独立内存库，互不累积
  setUp(() async {
    db = await DatabaseProvider.openTest();
    bookDao = BookDao(db);
    wordDao = WordEntryDao(db);
    recordDao = LearningRecordDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('BookDao', () {
    test('insert/getAll/getById/update/delete', () async {
      final book = Book.create(title: '语文', source: BookSource.pdf);
      await bookDao.insert(book);

      expect((await bookDao.getAll()).length, 1);
      expect((await bookDao.getById(book.id))!.title, '语文');

      book.title = '数学';
      await bookDao.update(book);
      final updated = await bookDao.getById(book.id);
      expect(updated!.title, '数学');
      expect(updated.updatedAt, greaterThanOrEqualTo(updated.createdAt));

      await bookDao.delete(book.id);
      expect(await bookDao.getById(book.id), isNull);
    });

    test('getAll 按 updated_at 倒序', () async {
      final a = Book.create(title: 'A', source: BookSource.txt);
      final b = Book.create(title: 'B', source: BookSource.txt);
      await bookDao.insert(a);
      await bookDao.insert(b);
      await bookDao.update(a); // a 更新后排前
      final all = await bookDao.getAll();
      expect(all.first.id, a.id);
      expect(all.length, 2);
    });
  });

  group('WordEntryDao', () {
    test('upsert 幂等去重', () async {
      final first = WordEntry.create(word: '苹果', lang: 'zh');
      final firstId = await wordDao.upsert(first);
      final dup = WordEntry.create(word: '苹果', lang: 'zh');
      final id2 = await wordDao.upsert(dup);
      expect(await wordDao.count(), 1);
      expect(id2, firstId); // 去重：返回已有 id，不新增
      final found = await wordDao.findByWord('苹果');
      expect(found!.id, firstId);
    });

    test('getUnmastered 掌握度排序', () async {
      final low = WordEntry.create(word: '难词', lang: 'zh'); // mastery 0
      final high = WordEntry.create(word: '熟词', lang: 'zh')..mastery = 5;
      await wordDao.upsert(low);
      await wordDao.upsert(high);
      final unmastered = await wordDao.getUnmastered();
      expect(unmastered.map((w) => w.word), contains('难词'));
      expect(unmastered.map((w) => w.word), isNot(contains('熟词')));
    });

    test('getByBook 与 delete', () async {
      final w = WordEntry.create(word: 'test', lang: 'en', fromBookId: 'b1');
      await wordDao.upsert(w);
      expect((await wordDao.getByBook('b1')).length, 1);
      await wordDao.delete(w.id);
      expect(await wordDao.count(), 0);
    });
  });

  group('LearningRecordDao', () {
    test('insert/getByType/countByType/avgResult', () async {
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.dictation,
          target: 'a',
          result: 60,
        ),
      );
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.dictation,
          target: 'b',
          result: 80,
        ),
      );
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.follow,
          target: 'c',
          result: 90,
        ),
      );

      expect(await recordDao.countByType(LearningType.dictation), 2);
      expect(await recordDao.avgResultByType(LearningType.dictation), 70);
      expect((await recordDao.getByType(LearningType.follow)).length, 1);
      expect((await recordDao.getRecent()).length, 3);
    });

    test('getRecent 时间倒序 + delete', () async {
      final r1 = LearningRecord.create(
        type: LearningType.review,
        target: 'x',
        result: 50,
      );
      await recordDao.insert(r1);
      final recent = await recordDao.getRecent();
      expect(recent.first.id, r1.id);
      await recordDao.delete(r1.id);
      expect(await recordDao.countByType(LearningType.review), 0);
    });
  });

  group('KnowledgePointDao', () {
    late KnowledgePointDao kpDao;

    setUp(() async {
      kpDao = KnowledgePointDao(db);
    });

    test('insert + getAll + type 筛选', () async {
      final a = KnowledgePoint.create(type: KnowledgeType.word, text: '学习');
      final b = KnowledgePoint.create(type: KnowledgeType.idiom, text: '画蛇添足');
      await kpDao.insert(a);
      await kpDao.insert(b);

      expect((await kpDao.getAll()).length, 115); // 2 条测试数据 + 113 条种子数据
      expect(
        (await kpDao.getAll(type: KnowledgeType.word)).length,
        88,
      ); // 1 条测试 + 87 条种子 word 型
    });

    test('upsertByText 幂等去重', () async {
      final id = await kpDao.upsertByText(
        'b1',
        KnowledgeType.word,
        '苹果',
        page: 1,
        definition: '一种水果',
      );
      final dup = await kpDao.upsertByText(
        'b1',
        KnowledgeType.word,
        '苹果',
        page: 2,
        definition: '水果之一',
      );
      expect(dup, id, reason: '幂等应返回原 id');
      final found = await kpDao.findByBookTypeText(
        'b1',
        KnowledgeType.word,
        '苹果',
      );
      expect(found!.page, 2, reason: '幂等应更新 page');
      expect(found.definition, '水果之一', reason: '幂等应更新 definition');
    });

    test('getByPage / getByChapter 过滤正确', () async {
      await kpDao.insert(
        KnowledgePoint.create(
          bookId: 'b1',
          page: 1,
          chapter: 0,
          type: KnowledgeType.word,
          text: '页1词',
        ),
      );
      await kpDao.insert(
        KnowledgePoint.create(
          bookId: 'b1',
          page: 2,
          chapter: 0,
          type: KnowledgeType.word,
          text: '页2词',
        ),
      );

      expect((await kpDao.getByPage('b1', 1)).length, 1);
      expect((await kpDao.getByPage('b1', 1)).first.text, '页1词');
      expect((await kpDao.getByChapter('b1', 0)).length, 2);
    });

    test('deleteByBook 级联清理', () async {
      await kpDao.insert(
        KnowledgePoint.create(
          bookId: 'b1',
          type: KnowledgeType.word,
          text: '测试',
        ),
      );
      await kpDao.insert(
        KnowledgePoint.create(
          bookId: 'b2',
          type: KnowledgeType.word,
          text: '其他书',
        ),
      );
      await kpDao.deleteByBook('b1');
      expect(await kpDao.countByBook('b1'), 0);
      expect(await kpDao.countByBook('b2'), 1);
    });
  });

  group('QuizAttemptDao', () {
    late QuizAttemptDao quizDao;

    setUp(() async {
      quizDao = QuizAttemptDao(db);
    });

    test('insert + getByChapter', () async {
      await quizDao.insert(
        QuizAttempt.create(
          bookId: 'b1',
          chapter: 1,
          totalScore: 85,
          questionCount: 10,
          correctCount: 7,
        ),
      );
      final list = await quizDao.getByChapter('b1', 1);
      expect(list.length, 1);
      expect(list.first.totalScore, 85);
    });

    test('bestByChapter 取最高分', () async {
      await quizDao.insert(
        QuizAttempt.create(
          bookId: 'b1',
          chapter: 1,
          totalScore: 60,
          questionCount: 5,
          correctCount: 3,
        ),
      );
      await quizDao.insert(
        QuizAttempt.create(
          bookId: 'b1',
          chapter: 1,
          totalScore: 95,
          questionCount: 10,
          correctCount: 9,
        ),
      );
      final best = await quizDao.bestByChapter('b1', 1);
      expect(best!.totalScore, 95);
    });

    test('deleteByBook 级联清理', () async {
      await quizDao.insert(
        QuizAttempt.create(
          bookId: 'b1',
          chapter: 1,
          totalScore: 80,
          questionCount: 5,
          correctCount: 4,
        ),
      );
      await quizDao.deleteByBook('b1');
      expect(await quizDao.getByBook('b1'), isEmpty);
    });
  });
}
