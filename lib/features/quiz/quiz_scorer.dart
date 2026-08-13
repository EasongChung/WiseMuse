/// [v0.3.0] 章节测验评分器（纯函数）。
///
/// 权重：朗读×0.5 + 听音选字×0.25 + 选择题×0.25
/// 缺失题型时重新归一化（分母去掉缺失题型的权重）。
class QuizScorer {
  const QuizScorer._();

  /// 各题型权重。
  static const double weightRead = 0.5;
  static const double weightCharSelect = 0.25;
  static const double weightChoice = 0.25;

  /// 计算总分（0-100）。
  ///
  /// [readAvg] 朗读平均分（0-100），无朗读题传 null。
  /// [charScore] 选字正确率（0-100），无选字题传 null。
  /// [choiceScore] 选择题正确率（0-100），无选择题传 null。
  static double compute(
    double? readAvg,
    double? charScore,
    double? choiceScore,
  ) {
    var totalWeight = 0.0;
    var weightedSum = 0.0;

    if (readAvg != null) {
      weightedSum += readAvg * weightRead;
      totalWeight += weightRead;
    }
    if (charScore != null) {
      weightedSum += charScore * weightCharSelect;
      totalWeight += weightCharSelect;
    }
    if (choiceScore != null) {
      weightedSum += choiceScore * weightChoice;
      totalWeight += weightChoice;
    }

    if (totalWeight == 0) return 0.0;
    return (weightedSum / totalWeight).clamp(0.0, 100.0);
  }

  /// 从正确数/总数计算百分比（0-100）。
  static double percent(int correct, int total) {
    if (total <= 0) return 0.0;
    return (correct / total * 100).clamp(0.0, 100.0);
  }

  /// 根据分数返回星级（1-5 星）。
  static int starRating(double score) {
    if (score >= 95) return 5;
    if (score >= 80) return 4;
    if (score >= 60) return 3;
    if (score >= 40) return 2;
    return 1;
  }
}
