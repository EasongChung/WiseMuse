import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/features/follow/scoring.dart';

void main() {
  group('FollowScorer.starCount', () {
    test('>=80 → 5 星', () {
      expect(FollowScorer.starCount(80), 5);
      expect(FollowScorer.starCount(100), 5);
      expect(FollowScorer.starCount(95), 5);
    });
    test('>=60 → 4 星', () {
      expect(FollowScorer.starCount(60), 4);
      expect(FollowScorer.starCount(79), 4);
    });
    test('>=40 → 3 星', () {
      expect(FollowScorer.starCount(40), 3);
      expect(FollowScorer.starCount(59), 3);
    });
    test('>=20 → 2 星', () {
      expect(FollowScorer.starCount(20), 2);
      expect(FollowScorer.starCount(39), 2);
    });
    test('<20 → 1 星', () {
      expect(FollowScorer.starCount(0), 1);
      expect(FollowScorer.starCount(19), 1);
    });
  });

  group('FollowScorer.comment', () {
    test('>=95 → 太棒了', () {
      expect(FollowScorer.comment(95), contains('太棒了'));
    });
    test('>=80 → 读得很好', () {
      expect(FollowScorer.comment(80), contains('读得很好'));
    });
    test('>=60 → 还不错', () {
      expect(FollowScorer.comment(60), contains('还不错'));
    });
    test('>=40 → 再听一遍', () {
      expect(FollowScorer.comment(40), contains('再听一遍'));
    });
    test('<40 → 别着急', () {
      expect(FollowScorer.comment(0), contains('别着急'));
      expect(FollowScorer.comment(39), contains('别着急'));
    });
  });

  group('FollowScorer.syllableSimilarity', () {
    test('完全一致 → 1.0', () {
      final sim = FollowScorer.syllableSimilarity('今天天气真好', '今天天气真好');
      expect(sim, greaterThanOrEqualTo(0.95));
    });
    test('完全不同 → 接近 0', () {
      // 拼音串 ni-hao-shi-jie vs zai-jian-tian-kong 完全不同
      final sim = FollowScorer.syllableSimilarity('你好世界', '再见天空');
      expect(sim, lessThanOrEqualTo(0.4));
    });
    test('空输入 → 0', () {
      expect(FollowScorer.syllableSimilarity('', '你好'), 0.0);
      expect(FollowScorer.syllableSimilarity('你好', ''), 0.0);
    });
  });

  group('FollowScore computed properties', () {
    test('starCount 映射正确', () {
      final s1 = FollowScorer.scoreFollow('你好', '你好');
      expect(s1.starCount, 5);

      // 6字目标 - 1字漏读 = 5/6 = 83.3分 → 5星
      final s2 = FollowScorer.scoreFollow('今天天气真好', '今天天气好');
      expect(s2.starCount, 5);

      // 全错 → 0分 → 1星
      final s3 = FollowScorer.scoreFollow('你好', '再见');
      expect(s3.starCount, 1);
    });
    test('comment 非空', () {
      final s = FollowScorer.scoreFollow('你好', '你坏');
      expect(s.comment, isNotEmpty);
    });
    test('syllableSim 返回值范围', () {
      final s = FollowScorer.scoreFollow('今天天气真好', '今天天气真好');
      expect(s.syllableSim, greaterThanOrEqualTo(0.0));
      expect(s.syllableSim, lessThanOrEqualTo(1.0));
    });
  });
}
