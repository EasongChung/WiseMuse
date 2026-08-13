import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/learning_record.dart';
import 'package:wisemuse/core/models/word_entry.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/learning_record_dao.dart';
import 'package:wisemuse/core/storage/word_entry_dao.dart';
import 'package:wisemuse/services/statistics_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late WordEntryDao wordDao;
  late LearningRecordDao recordDao;

  setUp(() async {
    db = await DatabaseProvider.openTest();
    wordDao = WordEntryDao(db);
    recordDao = LearningRecordDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('StatisticsService 空库', () {
    test('默认值全为 0/空', () async {
      final s = await StatisticsService().load(db: db);
      expect(s.wordCount, 0);
      expect(s.masteredCount, 0);
      expect(s.unmasteredCount, 0);
      expect(s.masteryRate, 0.0);
      expect(s.followCount, 0);
      expect(s.followAvg, 0.0);
      expect(s.dictationCount, 0);
      expect(s.dictationAvg, 0.0);
      expect(s.reviewCount, 0);
      expect(s.reviewAvg, 0.0);
      expect(s.topWrongWords, isEmpty);
      expect(s.dailyActivity, hasLength(7));
      expect(s.dailyActivity.values, everyElement(0));
    });
  });

  group('StatisticsService 掌握率', () {
    test('mastery>=3 计为已掌握', () async {
      final w1 = WordEntry.create(word: '熟词', lang: 'zh')..mastery = 5;
      final w2 = WordEntry.create(word: '熟词2', lang: 'zh')..mastery = 3;
      final w3 = WordEntry.create(word: '生词', lang: 'zh')..mastery = 1;
      final w4 = WordEntry.create(word: '生词2', lang: 'zh')..mastery = 2;
      for (final w in [w1, w2, w3, w4]) {
        await wordDao.upsert(w);
      }

      final s = await StatisticsService().load(db: db);
      expect(s.wordCount, 4);
      expect(s.masteredCount, 2);
      expect(s.unmasteredCount, 2);
      expect(s.masteryRate, closeTo(0.5, 1e-9));
    });
  });

  group('StatisticsService 学习记录', () {
    test('各类型次数与平均分', () async {
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.follow,
          target: 'a',
          result: 80,
        ),
      );
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.follow,
          target: 'b',
          result: 100,
        ),
      );
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.dictation,
          target: 'c',
          result: 60,
        ),
      );
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.review,
          target: 'd',
          result: 90,
        ),
      );

      final s = await StatisticsService().load(db: db);
      expect(s.followCount, 2);
      expect(s.followAvg, 90);
      expect(s.dictationCount, 1);
      expect(s.dictationAvg, 60);
      expect(s.reviewCount, 1);
      expect(s.reviewAvg, 90);
    });
  });

  group('StatisticsService 错词分布', () {
    test('按 wrongCount 降序取 Top，且只含有错词的', () async {
      final w1 = WordEntry.create(word: '最错', lang: 'zh')..wrongCount = 5;
      final w2 = WordEntry.create(word: '次错', lang: 'zh')..wrongCount = 3;
      final w3 = WordEntry.create(word: '无错', lang: 'zh'); // wrongCount 0
      for (final w in [w1, w2, w3]) {
        await wordDao.upsert(w);
      }

      final s = await StatisticsService().load(db: db);
      expect(s.topWrongWords, hasLength(2));
      expect(s.topWrongWords[0].word, '最错');
      expect(s.topWrongWords[1].word, '次错');
    });

    test('超过 10 个只取前 10', () async {
      for (var i = 0; i < 12; i++) {
        await wordDao.upsert(
          WordEntry.create(word: '错$i', lang: 'zh')..wrongCount = 12 - i,
        );
      }
      final s = await StatisticsService().load(db: db);
      expect(s.topWrongWords, hasLength(10));
    });
  });

  group('StatisticsService 近 7 天活动', () {
    test('记录按天归组，今天计入', () async {
      // 今天的一条记录
      final now = DateTime.now();
      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.follow,
          target: 'a',
          result: 80,
        ),
      );
      // 昨天的一条记录（手动构造 at）
      final yesterday = now.subtract(const Duration(days: 1));
      await recordDao.insert(
        LearningRecord(
          id: 'r2',
          type: LearningType.dictation,
          target: 'b',
          result: 60,
          at: yesterday.microsecondsSinceEpoch,
        ),
      );

      final s = await StatisticsService().load(db: db);
      expect(s.dailyActivity, hasLength(7));
      final today = DateTime(now.year, now.month, now.day);
      final yDay = DateTime(yesterday.year, yesterday.month, yesterday.day);
      expect(s.dailyActivity[today], 1);
      expect(s.dailyActivity[yDay], 1);
      // 其余天为 0
      final sum = s.dailyActivity.values.fold<int>(0, (a, b) => a + b);
      expect(sum, 2);
    });

    test('7 天前的记录不计入', () async {
      final old = DateTime.now().subtract(const Duration(days: 8));
      await recordDao.insert(
        LearningRecord(
          id: 'r3',
          type: LearningType.review,
          target: 'x',
          result: 50,
          at: old.microsecondsSinceEpoch,
        ),
      );
      final s = await StatisticsService().load(db: db);
      final sum = s.dailyActivity.values.fold<int>(0, (a, b) => a + b);
      expect(sum, 0);
    });
  });
}
