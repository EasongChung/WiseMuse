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

import '../core/utils/pinyin_filter_util.dart';
import 'line_merge_rules.dart';

/// 当前纯文本分句规则版本。规则变化后，文本书籍会从原文件重建句子。
const int currentSentenceSplitVersion = 2;

const String _columnMarker = '';
const String _lineBreakMarker = '';

/// 句子终止标点（与 `text_position_service._sentenceTerms` 对齐）。
const String sentenceTerms = '。！？!?；;';

/// 句子硬性最大长度；超过后按逗号/顿号/冒号二次切分（避免单句过长难跟读）。
const int maxSpeakLength = 120;

/// 按终止标点把 [text] 切成句子列表。
///
/// - 空行视为段落边界（保留为句间分隔，不产生空句）；
/// - 终止标点归入前句；
/// - 自动清洗行内与整行拼音注音杂质；
/// - 超过 [maxSpeakLength] 的句子按 `，,、：:` 二次切分兜底。
///
/// 结果按原顺序返回，无空串。
List<String> splitTextToSentences(String text) {
  // [v0.1.55] 在拼音清洗前，将 2+ 连续空白替换为标记字符，避免被后续拼音清洗吞噬
  final marked = text.replaceAllMapped(
    RegExp(r'(?<=\S)(?: {2,}|　)(?=\S)'),
    (_) => _columnMarker,
  );
  // 私用区列标记既保留分列边界，也隔开中文与合法英文列；整块清洗继续
  // 保留原有「拼音把汉字拆成一字一行」的自动合并能力。
  final cleanedText = PinyinFilterUtil.clean(marked);
  final normalized = cleanedText.replaceAll('\r\n', '\n');
  final result = <String>[];

  // 普通单换行可能只是版心自动折行，仍按原有逻辑合并；只有包含 2+ 空格的
  // 行才视为表格/多列边界。导入前不再 clean()，因此该信号能保留下来。
  for (final para in normalized.split(RegExp(r'\n\s*\n'))) {
    final lines = para.split('\n');
    final blockRight = lines
        .map((line) => line.trim().length)
        .fold<int>(0, math.max);
    final merged = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final current = lines[i];
      if (i > 0) {
        final previous = lines[i - 1];
        final prevTrimmed = previous.trim();
        final currentTrimmed = current.trim();
        final shouldMerge =
            !previous.contains(_columnMarker) &&
            !current.contains(_columnMarker) &&
            canMergeLines(
              prevRight: prevTrimmed.length.toDouble(),
              prevLeft:
                  (previous.length - previous.trimLeft().length).toDouble(),
              blockRight: blockRight.toDouble(),
              nextLeft: (current.length - current.trimLeft().length).toDouble(),
              blockLeft: 0,
              charW: 1,
              prevLastChar:
                  prevTrimmed.isEmpty
                      ? ''
                      : prevTrimmed.substring(prevTrimmed.length - 1),
              nextFirstChar:
                  currentTrimmed.isEmpty ? '' : currentTrimmed.substring(0, 1),
              prevLineText: previous,
              nextLineText: current,
            );
        if (!shouldMerge) {
          merged.write(_lineBreakMarker);
        } else if (needsSpaceBetween(
          prevTrimmed.substring(prevTrimmed.length - 1),
          currentTrimmed.substring(0, 1),
        )) {
          merged.write(' ');
        }
      }
      merged.write(current);
    }
    final trimmed = merged.toString().trim();
    if (trimmed.isEmpty) continue;
    // 终止标点、连续 2 空格标记、列/表格行边界均可切句。
    for (final part in trimmed.split(
      RegExp(
        '$_columnMarker|$_lineBreakMarker|'
        '(?<=[。！？!?；;])(?![$_columnMarker$_lineBreakMarker])',
      ),
    )) {
      final sentence = PinyinFilterUtil.cleanInlinePinyin(part.trim());
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
        result.add(s.substring(i, math.min(i + maxSpeakLength, s.length)));
      }
    }
  }
  return result;
}
