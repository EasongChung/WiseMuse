import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/features/follow/scoring.dart';

void main() {
  group('FollowScorer.normalize', () {
    test('去标点与空白，仅保留中英文数字', () {
      expect(FollowScorer.normalize('今天，天气不错。'), '今天天气不错');
      expect(FollowScorer.normalize('我 爱 你！'), '我爱你');
      expect(FollowScorer.normalize('abc 123'), 'abc123');
    });
  });

  group('FollowScorer.scoreFollow', () {
    test('完全一致 → 100 分全对', () {
      final s = FollowScorer.scoreFollow('今天天气真好', '今天天气真好');
      expect(s.score, 100);
      expect(s.matchCount, s.totalCount);
      expect(s.diffs.every((d) => d.status == CharStatus.match), isTrue);
      expect(s.passed, isTrue);
    });

    test('同音字容错（你/尼）→ 100 分 homophone', () {
      final s = FollowScorer.scoreFollow('你好', '尼好');
      expect(s.score, 100);
      expect(s.diffs.first.status, CharStatus.homophone);
    });

    test('错字 → 相应扣分', () {
      final s = FollowScorer.scoreFollow('你好', '吃饭');
      expect(s.score, 0);
      expect(s.diffs.every((d) => d.status == CharStatus.wrong), isTrue);
      expect(s.passed, isFalse);
    });

    test('部分错字按比例计分', () {
      // 目标「今天真好」4 字，识别「今天很好」对 3 错 1 → 75 分（<80 不通过）
      final s = FollowScorer.scoreFollow('今天真好', '今天很好');
      expect(s.matchCount, 3);
      expect(s.score, 75);
      expect(s.passed, isFalse);
    });

    test('漏读（识别少字）→ missing', () {
      final s = FollowScorer.scoreFollow('你好吗', '你好');
      final statuses = s.diffs.map((d) => d.status).toList();
      expect(statuses.contains(CharStatus.missing), isTrue);
      // 2/3 对 → 约 67 分
      expect(s.score, closeTo(100 * 2 / 3, 0.5));
    });

    test('多读（识别多字）→ extra，不扣目标分', () {
      final s = FollowScorer.scoreFollow('你好', '你好啊');
      final statuses = s.diffs.map((d) => d.status).toList();
      expect(statuses.contains(CharStatus.extra), isTrue);
      expect(s.score, 100);
    });

    test('识别为空 → 0 分全漏读', () {
      final s = FollowScorer.scoreFollow('今天天气真好', '');
      expect(s.score, 0);
      expect(s.totalCount, 6);
      expect(s.passed, isFalse);
    });

    test('目标为空 → 0 分空结果', () {
      final s = FollowScorer.scoreFollow('', '随便说说');
      expect(s.score, 0);
      expect(s.diffs, isEmpty);
    });

    test('标点不影响判定（归一化后一致 → 100 分）', () {
      final s = FollowScorer.scoreFollow('今天，天气不错。', '今天天气不错');
      expect(s.score, 100);
    });
  });

  group('FollowScore.toJson', () {
    test('可序列化（detail 落库用）', () {
      final s = FollowScorer.scoreFollow('你好', '尼好');
      final json = s.toJson();
      expect(json['score'], 100);
      expect(json['diffs'], hasLength(2));
      expect((json['diffs'] as List).first['status'], 'homophone');
    });
  });
}
