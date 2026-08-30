import '../storage/seed_data.dart';

/// [v0.1.63] 内置书拼音朗读预处理：句首孤立的拼音字母替换为中文谐音字，
/// 避免 Android TTS 读成英文字母名（如 `b` 读 /biː/）。
///
/// 复用 `SeedData.pinyinReadOf` 查表，并仅在调用方显式启用时才生效，
/// 防止误伤英语单词、用户发送的纯英文文本和其他书籍的正文。
class PinyinSpeech {
  PinyinSpeech._();

  /// 仅匹配「拉丁/拼音字母 + 全角或半角冒号」的句首模式；非句首不转换。
  static final _pinyinLeading = RegExp(r'^([a-zA-Zü]+)([：:])');

  /// 把 [text] 转为适合 TTS 朗读的版本。
  ///
  /// - [enabled] = false → 原样返回。
  /// - [enabled] = true 且匹配到句首拼音 → 用 `SeedData.pinyinReadOf` 替换为谐音字。
  /// - 其余情况 → 原样返回。
  static String transform(String text, {bool enabled = true}) {
    if (!enabled) return text;
    final m = _pinyinLeading.firstMatch(text);
    if (m == null) return text;
    final raw = m.group(1)!;
    final read = SeedData.pinyinReadOf(raw);
    if (read == null) return text;
    return '$read${text.substring(raw.length)}';
  }
}
