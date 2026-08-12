import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/core/models/sentence.dart';
import 'package:wisemuse/core/storage/book_dao.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/sentence_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late BookDao bookDao;
  late SentenceDao sentenceDao;

  setUp(() async {
    db = await DatabaseProvider.openTest();
    bookDao = BookDao(db);
    sentenceDao = SentenceDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Sentence sent(String bookId, int page, int index, String text) =>
      Sentence.create(bookId: bookId, page: page, chapter: 0, index: index, text: text);

  test('insertAll 批量写入 + getByBook 按 page,index 排序', () async {
    await sentenceDao.insertAll([
      sent('b1', 0, 1, '第二句。'),
      sent('b1', 1, 0, '第二页句。'),
      sent('b1', 0, 0, '第一句。'),
    ]);
    final all = await sentenceDao.getByBook('b1');
    expect(all.length, 3);
    expect(all[0].text, '第一句。');
    expect(all[1].text, '第二句。');
    expect(all[2].text, '第二页句。');
    expect(await sentenceDao.countByBook('b1'), 3);
  });

  test('getByPage 只取指定页', () async {
    await sentenceDao.insertAll([
      sent('b1', 0, 0, '首页句。'),
      sent('b1', 2, 0, '第三页句。'),
    ]);
    final p0 = await sentenceDao.getByPage('b1', 0);
    expect(p0.length, 1);
    expect(p0.first.text, '首页句。');
    expect(await sentenceDao.getByPage('b1', 1), isEmpty);
  });

  test('deleteByBook 级联 + 不误删其他书', () async {
    await sentenceDao.insertAll([
      sent('b1', 0, 0, '甲句。'),
      sent('b2', 0, 0, '乙句。'),
    ]);
    await sentenceDao.deleteByBook('b1');
    expect(await sentenceDao.countByBook('b1'), 0);
    expect(await sentenceDao.countByBook('b2'), 1);
  });

  test('BookDao.delete 级联删句子', () async {
    final book = Book.create(title: '语文', source: BookSource.pdf);
    await bookDao.insert(book);
    await sentenceDao.insertAll([sent(book.id, 0, 0, '句一。')]);
    expect(await sentenceDao.countByBook(book.id), 1);

    await bookDao.delete(book.id);
    expect(await sentenceDao.countByBook(book.id), 0);
    expect(await bookDao.getById(book.id), isNull);
  });
}
