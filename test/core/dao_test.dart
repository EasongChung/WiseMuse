import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/core/models/learning_record.dart';
import 'package:wisemuse/core/models/word_entry.dart';
import 'package:wisemuse/core/storage/book_dao.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/learning_record_dao.dart';
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
}
