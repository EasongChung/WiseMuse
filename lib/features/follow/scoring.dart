import 'dart:math';

import 'package:pinyin/pinyin.dart';

/// [v0.1.0] 跟读评分引擎（纯函数，可单测）。
///
/// 逐字对齐算法（编辑距离 + 回溯）：
/// - 目标与识别文本先归一化（去标点/空白，仅保留中英文与数字）
/// - 逐字比较：相同→match；不同但拼音相同→homophone（音同容错，v1 不判声调）；
///   目标有识别无→missing（漏读）；识别有目标无→extra（多读）；其余→wrong（错字）
/// - 得分 = 正确（match + homophone）目标字数 ÷ 目标字数 × 100
///
/// 用法：`final s = scoreFollow('今天天气真好', '今天天气真好');`
class FollowScorer {
  FollowScorer._();

  /// 归一化：去掉标点与空白，仅保留中英文与数字（比较基准）。
  static String normalize(String text) =>
      text.replaceAll(RegExp(r'[^一-龥A-Za-z0-9]'), '');

  /// 单字转拼音（去声调）。非汉字返回原字符（防御性兜底）。
  static String pinyinOf(String ch) {
    final p = PinyinHelper.getPinyin(ch, format: PinyinFormat.WITHOUT_TONE);
    return p.isEmpty ? ch : p;
  }

  /// 单字比较：相同 0 分 / 同音 1 分 / 否则 2 分（代价，越小越接近）。
  static int alignCost(String a, String b) {
    if (a == b) return 0;
    if (pinyinOf(a) == pinyinOf(b)) return 1;
    return 2;
  }

  /// 逐字状态判定。
  static CharStatus statusOf(String target, String actual) {
    if (target == actual) return CharStatus.match;
    if (pinyinOf(target) == pinyinOf(actual)) return CharStatus.homophone;
    return CharStatus.wrong;
  }

  /// 计算一次跟读的评分结果。
  static FollowScore scoreFollow(String target, String recognized) {
    final t = normalize(target);
    final r = normalize(recognized);
    if (t.isEmpty) {
      return const FollowScore(
        score: 0,
        diffs: [],
        matchCount: 0,
        totalCount: 0,
      );
    }

    final n = t.length, m = r.length;
    // dp[i][j] = 前 i 个目标字与前 j 个识别字对齐的最小代价
    final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = 0; i <= n; i++) {
      dp[i][0] = i; // 目标全删
    }
    for (var j = 0; j <= m; j++) {
      dp[0][j] = j; // 识别全插
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final sub = dp[i - 1][j - 1] + alignCost(t[i - 1], r[j - 1]);
        final del = dp[i - 1][j] + 1;
        final ins = dp[i][j - 1] + 1;
        dp[i][j] = min(min(sub, del), ins);
      }
    }

    // 回溯生成逐字差异（目标方向，追加 extra 多读字）
    final diffs = <CharDiff>[];
    var i = n, j = m;
    while (i > 0 || j > 0) {
      if (i > 0 &&
          j > 0 &&
          dp[i][j] == dp[i - 1][j - 1] + alignCost(t[i - 1], r[j - 1])) {
        final st = statusOf(t[i - 1], r[j - 1]);
        diffs.add(CharDiff(status: st, target: t[i - 1], actual: r[j - 1]));
        i--;
        j--;
      } else if (i > 0 && dp[i][j] == dp[i - 1][j] + 1) {
        diffs.add(
          const CharDiff(
            status: CharStatus.missing,
            target: null,
            actual: null,
          ),
        );
        i--;
      } else {
        diffs.add(
          CharDiff(status: CharStatus.extra, target: null, actual: r[j - 1]),
        );
        j--;
      }
    }
    final aligned = diffs.reversed.toList();

    final good =
        aligned
            .where(
              (d) =>
                  d.status == CharStatus.match ||
                  d.status == CharStatus.homophone,
            )
            .length;
    final score = (good * 100 / n).clamp(0, 100).toDouble();

    return FollowScore(
      score: score,
      diffs: aligned,
      matchCount: good,
      totalCount: n,
    );
  }
}

/// 逐字状态。
enum CharStatus {
  /// 完全正确。
  match,

  /// 音同字不同（如 你/尼）——发音对，仅字形出入，计入得分。
  homophone,

  /// 错字。
  wrong,

  /// 漏读（目标有、识别无）。
  missing,

  /// 多读（识别有、目标无）。
  extra,
}

/// 单个字的位置与判定。
class CharDiff {
  const CharDiff({
    required this.status,
    required this.target,
    required this.actual,
  });

  final CharStatus status;

  /// 目标字（missing 时代表漏读的目标字，extra 时为 null）。
  final String? target;

  /// 识别出的字（extra 时代表多读的字，missing 时为 null）。
  final String? actual;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'target': target,
    'actual': actual,
  };
}

/// 一次跟读评分结果。
class FollowScore {
  const FollowScore({
    required this.score,
    required this.diffs,
    required this.matchCount,
    required this.totalCount,
  });

  /// 0-100。
  final double score;

  /// 逐字差异（按目标顺序，extra 多读字在末尾追加）。
  final List<CharDiff> diffs;

  /// 正确（match + homophone）的目标字数。
  final int matchCount;

  /// 目标总字数（归一化后）。
  final int totalCount;

  /// 是否达标（≥80 视为读得不错，不入生词本）。
  bool get passed => score >= 80;

  Map<String, dynamic> toJson() => {
    'score': score,
    'match_count': matchCount,
    'total_count': totalCount,
    'diffs': diffs.map((d) => d.toJson()).toList(),
  };
}
