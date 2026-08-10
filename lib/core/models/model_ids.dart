import 'dart:math';

/// [v0.1.0] 生成带时间戳与随机后缀的唯一模型 id。
///
/// 单用户单设备场景足够唯一；格式 `{prefix}_{micros}_{rand}`。
String newModelId(String prefix) {
  final r = Random().nextInt(9999).toString().padLeft(4, '0');
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$r';
}
