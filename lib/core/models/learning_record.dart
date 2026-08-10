import 'model_ids.dart';

/// [v0.1.0] 学习记录（一次跟读/听写/复习的结果）。

/// 学习类型。
enum LearningType {
  /// 跟读验证。
  follow('跟读'),

  /// 听写。
  dictation('听写'),

  /// 生词复习。
  review('复习');

  const LearningType(this.label);
  final String label;

  static LearningType fromName(String? name) {
    return LearningType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => LearningType.review,
    );
  }
}

/// 一次学习结果记录。
class LearningRecord {
  LearningRecord({
    required this.id,
    required this.type,
    required this.target,
    required this.result,
    this.detail,
    required this.at,
  });

  /// 新建记录。
  factory LearningRecord.create({
    required LearningType type,
    required String target,
    required double result,
    String? detail,
  }) {
    return LearningRecord(
      id: newModelId('record'),
      type: type,
      target: target,
      result: result,
      detail: detail,
      at: DateTime.now().microsecondsSinceEpoch,
    );
  }

  final String id;
  final LearningType type;

  /// 目标文本（跟读的句子 / 听写的词 / 复习的词）。
  final String target;

  /// 得分 0-100。
  final double result;

  /// 附加信息（如逐字对错 JSON），可为 null。
  final String? detail;

  final int at;

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'target': target,
    'result': result,
    'detail': detail,
    'at': at,
  };

  factory LearningRecord.fromMap(Map<String, dynamic> map) => LearningRecord(
    id: map['id'] as String,
    type: LearningType.fromName(map['type'] as String?),
    target: (map['target'] as String?) ?? '',
    result: ((map['result'] as num?) ?? 0).toDouble(),
    detail: map['detail'] as String?,
    at: (map['at'] as int?) ?? 0,
  );
}
