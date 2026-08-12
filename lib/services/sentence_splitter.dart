/// 纯文本句子切分。
///
/// 供两处使用：
/// 1. **导入入库**：把每页文本切成句子写入 [Sentence] 表（文本骨架）；
/// 2. **朗读侧**：TtsService 播放前的句子切分。
///
/// 与几何侧 `text_position_service` 的终止标点**同源**（`。！？!?；;`），
/// 避免「朗读单元」与「高亮单元」异源（G2.5.1「只改一侧」教训）。
library;

import 'dart:math' as math;

/// 句子终止标点（与 `text_position_service._sentenceTerms` 对齐）。
const String sentenceTerms = '。！？!?；;';

/// 句子硬性最大长度；超过后按逗号/顿号/冒号二次切分（避免单句过长难跟读）。
const int maxSpeakLength = 120;

/// 按终止标点把 [text] 切成句子列表。
///
/// - 空行视为段落边界（保留为句间分隔，不产生空句）；
/// - 终止标点归入前句；
/// - 超过 [maxSpeakLength] 的句子按 `，,、：:` 二次切分兜底。
///
/// 结果按原顺序返回，无空串。
List<String> splitTextToSentences(String text) {
  final normalized = text.replaceAll('\r\n', '\n');
  final result = <String>[];

  // 空行 = 段落边界，段内连续文本直接按标点切
  for (final para in normalized.split(RegExp(r'\n\s*\n'))) {
    final trimmed = para.trim();
    if (trimmed.isEmpty) continue;
    for (final part in trimmed.split(RegExp(r'(?<=[。！？!?；;])'))) {
      final sentence = part.trim();
      if (sentence.isEmpty) continue;
      result.addAll(_splitLong(sentence));
    }
  }
  return result;
}

/// 超长句按逗号/顿号/冒号二次切分（不吞标点，标点归前段）。
List<String> _splitLong(String text) {
  if (text.length <= maxSpeakLength) return [text];
  final result = <String>[];
  for (final segment in text.split(RegExp(r'(?<=[，,、：:])'))) {
    final s = segment.trim();
    if (s.isEmpty) continue;
    if (s.length <= maxSpeakLength) {
      result.add(s);
    } else {
      // 极长且无逗号可断：按固定窗口硬切（宁可断词不吞整段）
      for (var i = 0; i < s.length; i += maxSpeakLength) {
        result.add(
          s.substring(i, math.min(i + maxSpeakLength, s.length)),
        );
      }
    }
  }
  return result;
}
