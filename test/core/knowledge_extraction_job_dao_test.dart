import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/knowledge_extraction_job.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/knowledge_extraction_job_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('任务页状态完成/失败与重提只影响目标书', () async {
    final db = await DatabaseProvider.openTest();
    try {
      final dao = KnowledgeExtractionJobDao(db);
      final first = await dao.createJob(
        bookId: 'book-a',
        pageChapters: {0: 0, 1: 1, 2: 1},
      );
      final second = await dao.createJob(
        bookId: 'book-b',
        pageChapters: {0: 0},
      );

      final token = await dao.claim(first.id);
      expect(token, isNotNull);
      final firstPage = (await dao.getPage(first.id, 0))!;
      expect(await dao.markPageRunning(first.id, token!, firstPage), isTrue);
      await db.transaction((txn) async {
        expect(
          await dao.completePage(
            txn,
            jobId: first.id,
            token: token,
            page: 0,
            pointCount: 2,
            isLastPage: false,
          ),
          isTrue,
        );
      });
      final afterFirst = await dao.getByBook('book-a');
      expect(afterFirst!.completedPages, 1);
      expect(afterFirst.status, KnowledgeJobStatus.running);

      final secondPage = (await dao.getPage(first.id, 1))!;
      expect(await dao.markPageRunning(first.id, token, secondPage), isTrue);
      expect(await dao.markPageFailed(first.id, token, 1, '网络不可用'), isTrue);
      final failed = await dao.getByBook('book-a');
      // [v0.1.60] markPageFailed 只改页状态、保持任务 running，便于续跑。
      expect(failed!.status, KnowledgeJobStatus.running);
      expect(failed.completedPages, 1);
      expect(
        (await dao.getPage(first.id, 1))!.status,
        KnowledgePageStatus.failed,
      );
      // 续跑：resetFailedPages 把失败页重置为 pending，下一轮可重新 markPageRunning
      expect(await dao.resetFailedPages(first.id, token), isTrue);
      final retriedPage = (await dao.getPage(first.id, 1))!;
      expect(retriedPage.status, KnowledgePageStatus.pending);
      expect(await dao.markPageRunning(first.id, token, retriedPage), isTrue);
      expect(await dao.getByBook('book-b'), isNotNull);

      final restarted = await dao.createJob(
        bookId: 'book-a',
        pageChapters: {0: 0, 1: 1},
      );
      expect(restarted.id, isNot(first.id));
      expect(await dao.getPages(first.id), isEmpty);
      expect((await dao.getPages(restarted.id)), hasLength(2));
      expect(await dao.getByBook('book-b'), isNotNull);
      expect(
        (await dao.getRecoverable()).map((job) => job.id),
        containsAll([restarted.id, second.id]),
      );
      expect(second.id, isNot(restarted.id));
    } finally {
      await db.close();
    }
  });
}
