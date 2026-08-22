import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/storage/book_dao.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/knowledge_point_dao.dart';
import 'package:wisemuse/core/storage/seed_data.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await DatabaseProvider.openTest();
  });

  tearDown(() async => db.close());

  group('SeedData 幼小衔接基础知识库', () {
    test('populate 写入 books 表且 ID/标题正确', () async {
      await SeedData.populate(db);
      final book = await BookDao(db).getById(SeedData.builtinBookId);
      expect(book, isNotNull);
      expect(book!.title, SeedData.builtinBookTitle);
      expect(book.source.name, 'txt');
    });

    test('知识点总数 113 条（23 声母 + 24 韵母 + 16 整体认读 + 26 字母 + 24 汉字）', () async {
      await SeedData.populate(db);
      final all = await KnowledgePointDao(db).getAll();
      expect(all, hasLength(113));
    });

    test('5 个单元（chapter 1-5）各条目数正确', () async {
      await SeedData.populate(db);
      final dao = KnowledgePointDao(db);
      final all = await dao.getAll();
      final byChapter = <int, int>{};
      for (final p in all) {
        final c = p.chapter ?? 0;
        byChapter[c] = (byChapter[c] ?? 0) + 1;
      }
      expect(byChapter[1], 23, reason: '第 1 单元 声母 23 个');
      expect(byChapter[2], 24, reason: '第 2 单元 韵母 24 个');
      expect(byChapter[3], 16, reason: '第 3 单元 整体认读 16 个');
      expect(byChapter[4], 26, reason: '第 4 单元 英文字母 26 个');
      expect(byChapter[5], 24, reason: '第 5 单元 基础汉字 24 个');
    });

    test('populate 幂等：二次调用不重复插入', () async {
      await SeedData.populate(db);
      await SeedData.populate(db);
      final books = await BookDao(db).getAll();
      // 仅内置书 1 条（无额外 insert）
      expect(books.where((b) => b.id == SeedData.builtinBookId), hasLength(1));
      final points = await KnowledgePointDao(db).getAll();
      expect(points, hasLength(113));
    });

    test('所有知识点均归属 builtinBookId', () async {
      await SeedData.populate(db);
      final all = await KnowledgePointDao(db).getAll();
      expect(all.every((p) => p.bookId == SeedData.builtinBookId), isTrue);
    });
  });
}
