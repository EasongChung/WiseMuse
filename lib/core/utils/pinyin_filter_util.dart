/// [v0.1.48] 拼音与杂乱音节清洗工具。
///
/// 针对小学教材/教辅扫描件中汉字上方或夹杂的拼音注音（如帶调字符 `āáǎà` 或
/// OCR 错识为无规律英文字母行如 `zhōng`、`háo`、`shù`），进行智能过滤，
/// 避免排版割裂、乱码插入以及 TTS 误发音。
class PinyinFilterUtil {
  PinyinFilterUtil._();

  /// 常见带声调拼音字符集正则。
  static final RegExp _toneLettersRegex = RegExp(
    r'[āáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜüĀÁǍÀŌÓǑÒĒÉĚÈĪÍǏÌŪÚǓÙǕǗǙǛÜ]',
  );

  /// 常见汉语拼音音节特征模式（声母+韵母）。
  static final RegExp _pinyinSyllableRegex = RegExp(
    r'\b(b|p|m|f|d|t|n|l|g|k|h|j|q|x|zh|ch|sh|r|z|c|s|y|w)?(a|o|e|i|u|v|ai|ei|ui|ao|ou|iu|ie|ve|er|an|en|in|un|vn|ang|eng|ing|ong)\b',
    caseSensitive: false,
  );

  /// 汉字匹配正则。
  static final RegExp _chineseCharRegex = RegExp(r'[一-龥]');

  /// 清洗整段文本：按行过滤纯拼音行/杂乱注音行，清理行内括号注音。
  static String clean(String text) {
    if (text.isEmpty) return text;

    final lines = text.split('\n');
    final cleanedLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        cleanedLines.add('');
        continue;
      }

      // 1. 判断是否为整行拼音/注音行：若整行拼音/字母占比极高且汉字极少，整行丢弃
      if (isPinyinLine(trimmed)) {
        continue;
      }

      // 2. 清洗行内括号拼音或行内零散拼音注音
      final cleanedLine = cleanInlinePinyin(trimmed);
      if (cleanedLine.isNotEmpty) {
        cleanedLines.add(cleanedLine);
      }
    }

    return cleanedLines.join('\n');
  }

  /// 判断一行是否主要为拼音注音或杂乱字母行。
  static bool isPinyinLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;

    final totalChars = trimmed.replaceAll(RegExp(r'\s+'), '').length;
    if (totalChars == 0) return false;

    final chineseMatches = _chineseCharRegex.allMatches(trimmed).length;
    final toneMatches = _toneLettersRegex.allMatches(trimmed).length;

    // 若包含声调字符，且汉字少于 2 个
    if (toneMatches > 0 && chineseMatches <= 1) {
      return true;
    }

    // 若包含拼音音节特征，且几乎无汉字（纯拉丁字母行但在中文语境中）
    final latinMatches =
        RegExp(r'[a-zA-Z]').allMatches(trimmed).length + toneMatches;
    final ratio = latinMatches / totalChars;

    if (ratio > 0.75 && chineseMatches == 0) {
      // 检查是否全为短拼音词
      final words = trimmed.split(RegExp(r'\s+'));
      var pinyinWordCount = 0;
      for (final w in words) {
        if (_toneLettersRegex.hasMatch(w) || _pinyinSyllableRegex.hasMatch(w)) {
          pinyinWordCount++;
        }
      }
      if (pinyinWordCount >= (words.length * 0.6)) {
        return true;
      }
    }

    return false;
  }

  /// 清洗行内括号注音，如 `汉(hàn)字` -> `汉字`，或 `天地人 tiān dì rén` 后缀拼音。
  static String cleanInlinePinyin(String line) {
    var result = line;

    // 去除括号内的拼音，如 (zhōng) （háo） (bǎ) [mǎ]
    result = result.replaceAll(
      RegExp(r'[\(（\[][a-zA-Zāáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü\s\d]+[\)）\]]'),
      '',
    );

    // 去除紧随汉字后的孤立声调拼音片段
    result = result.replaceAll(
      RegExp(
        r'(?<=[一-龥])\s*[āáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü][a-zA-Zāáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü]*',
      ),
      '',
    );

    return result.trimRight();
  }
}
