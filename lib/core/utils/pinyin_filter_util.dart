/// [v0.1.48] [v0.1.50] 拼音与杂乱音节清洗工具。
///
/// 针对小学教材/教辅扫描件与电子版 PDF 中汉字上方或夹杂的拼音注音（包含：
/// 1. 标准带调拼音字符 `āáǎà`；
/// 2. 教材拼音字库映射字符：声调被映射为大写字母如 `xiAo`、`kE`、`dGu`、`zhAo`、`mQ`、`tWng`、`qPn`、`lJ`；
/// 3. OCR 错识为无规律英文字母串如 `jiMyIngshSng...`、`hHutuJtQmen...`；
/// 4. 汉字与拼音交错单字换行），进行全方位智能过滤与清洗，避免排版割裂、乱码插入以及 TTS 误发音。
class PinyinFilterUtil {
  PinyinFilterUtil._();

  /// 常见带声调拼音字符集正则（包含标准 Unicode 音调字符与常见变体）。
  static final RegExp _toneLettersRegex = RegExp(
    r'[āáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜüĀÁǍÀŌÓǑÒĒÉĚÈĪÍǏÌŪÚǓÙǕǗǙǛÜ]',
  );

  /// 常见汉语拼音音节特征模式（声母+韵母，忽略大小写）。
  static final RegExp _pinyinSyllableRegex = RegExp(
    r'\b(b|p|m|f|d|t|n|l|g|k|h|j|q|x|zh|ch|sh|r|z|c|s|y|w)?(a|o|e|i|u|v|ai|ei|ui|ao|ou|iu|ie|ve|er|an|en|in|un|vn|ang|eng|ing|ong)\b',
    caseSensitive: false,
  );

  /// 教材拼音字库声调大写字母映射特征（如 xiAo, kE, dGu, mQ, chI, tWng, yGu, yK, qPn, sK, tuJ）。
  static final RegExp _pinyinFontMappingRegex = RegExp(
    r'^[a-z]{1,4}[A-Z][a-z]{0,4}$',
  );

  /// 汉字匹配正则。
  static final RegExp _chineseCharRegex = RegExp(r'[一-龥]');

  /// 清洗整段文本：按行过滤纯拼音行/杂乱注音行，清理行内注音，并将被拼音拆碎的汉字行重新合并。
  static String clean(String text) {
    if (text.isEmpty) return text;

    final rawLines = text.split('\n');
    final validLines = <String>[];

    for (final line in rawLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        validLines.add('');
        continue;
      }

      // 1. 判断是否为整行拼音/注音行：若是直接丢弃
      if (isPinyinLine(trimmed)) {
        continue;
      }

      // 2. 清洗行内括号拼音或行内连缀拼音注音
      final cleanedLine = cleanInlinePinyin(trimmed);
      if (cleanedLine.isNotEmpty) {
        validLines.add(cleanedLine);
      }
    }

    // 3. 处理单字+拼音交错导致的“一字一行”问题：将连续的单汉字/短词行合并为完整句子
    final mergedLines = _mergeFragmentedLines(validLines);

    return mergedLines.join('\n');
  }

  /// 判断一行是否主要为拼音注音、字母音节行或字库映射拼音。
  static bool isPinyinLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;

    // 剔除标点与空白后的字符数
    final cleanStr = trimmed.replaceAll(
      RegExp(r'[\s\p{P}]+', unicode: true),
      '',
    );
    if (cleanStr.isEmpty) return false;

    final chineseMatches = _chineseCharRegex.allMatches(cleanStr).length;
    final toneMatches = _toneLettersRegex.allMatches(cleanStr).length;
    final latinMatches = RegExp(r'[a-zA-Z]').allMatches(cleanStr).length;

    // 1) 含有标准声调字符，且汉字 <= 1
    if (toneMatches > 0 && chineseMatches <= 1) {
      return true;
    }

    // 2) 纯字母/音节行（或字母+少数符号）：
    if (chineseMatches == 0 && latinMatches > 0) {
      // 检查词法是否匹配拼音音节或教材字库映射拼音
      final words = trimmed.split(RegExp(r'\s+'));
      var pinyinCount = 0;
      var totalWordCount = 0;
      for (final w in words) {
        final wClean = w.replaceAll(RegExp(r'[\p{P}]+', unicode: true), '');
        if (wClean.isEmpty) continue;
        totalWordCount++;
        if (_toneLettersRegex.hasMatch(wClean) ||
            _pinyinFontMappingRegex.hasMatch(wClean) ||
            _pinyinSyllableRegex.hasMatch(wClean)) {
          pinyinCount++;
        }
      }
      if (totalWordCount > 0 && pinyinCount >= (totalWordCount * 0.6)) {
        return true;
      }
      // 如果整行是连续的大小写交错拼音字符串（如 jiMyIngshSngqMwFnlJyPQyIwGmendemQmazSinA）
      if (_isPinyinCharStream(cleanStr)) {
        return true;
      }
    }

    return false;
  }

  /// 检测是否为教材字库连续拼音字符流（如 xiAokEdGuyYuwayYuguHlejJtiQnzhAngchOleliAngtiWo）。
  static bool _isPinyinCharStream(String str) {
    if (str.length < 3) return false;
    final hasUpper = RegExp(r'[A-Z]').hasMatch(str);
    final hasLower = RegExp(r'[a-z]').hasMatch(str);
    final hasChinese = _chineseCharRegex.hasMatch(str);
    if (hasChinese) return false;
    // 包含大写声调映射与小写音节，且无汉字
    if (hasUpper && hasLower) {
      final upperCount = RegExp(r'[A-Z]').allMatches(str).length;
      final lowerCount = RegExp(r'[a-z]').allMatches(str).length;
      if (upperCount >= 1 && lowerCount >= 2) {
        return true;
      }
    }
    return false;
  }

  /// 清洗行内夹杂的拼音注音、括号拼音与前后缀拼音乱码。
  static String cleanInlinePinyin(String line) {
    var result = line;

    // 1. 去除括号内的拼音注音，如 (zhōng) （háo） (bǎ) [mǎ] (xiAo)
    result = result.replaceAll(
      RegExp(r'[\(（\[][a-zA-Zāáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü\s\d]+[\)）\]]'),
      '',
    );

    // 2. 去除汉字前后夹杂的长串大小写拼音字符流（如 `jiMyIng...就迎上去` -> `就迎上去`）
    result = result.replaceAll(RegExp(r'[a-zA-Z]{4,}(?=[一-龥])'), '');
    result = result.replaceAll(RegExp(r'(?<=[一-龥])[a-zA-Z]{4,}'), '');

    // 3. 去除紧随汉字后的孤立声调拼音片段（如 `天地人 tiān dì rén`）
    result = result.replaceAll(
      RegExp(
        r'(?<=[一-龥])\s*[āáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü][a-zA-Zāáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜü]*',
      ),
      '',
    );

    // 4. 去除行首或行末残留的孤立拼音词
    final parts = result.split(RegExp(r'\s+'));
    final filteredParts =
        parts.where((p) {
          final pClean = p.replaceAll(RegExp(r'[\p{P}]+', unicode: true), '');
          if (pClean.isEmpty) return true;
          if (_chineseCharRegex.hasMatch(pClean)) return true;
          if (_pinyinFontMappingRegex.hasMatch(pClean) ||
              _isPinyinCharStream(pClean)) {
            return false;
          }
          return true;
        }).toList();

    return filteredParts.join(' ').trim();
  }

  /// 将因拼音注音拆碎的单汉字行（如 小\n蝌\n蚪）智能合并为完整句子。
  static List<String> _mergeFragmentedLines(List<String> lines) {
    final result = <String>[];
    final buf = StringBuffer();

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
        result.add('');
        continue;
      }

      // 如果当前行是单汉字（或含单汉字+标点）
      final clean = line.replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
      final isSingleChar =
          clean.length == 1 && _chineseCharRegex.hasMatch(clean);

      if (isSingleChar) {
        buf.write(line);
      } else {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
        result.add(line);
      }
    }

    if (buf.isNotEmpty) {
      result.add(buf.toString());
    }

    return result;
  }
}
