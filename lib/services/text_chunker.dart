/// 超长文本分块（章节识别优先，字数分断兜底）。
///
/// 用于避免把超长单页纯文本（DOCX 提取 / TXT / 无分页信息的长文）一次性灌入
/// TTS 与渲染，导致加载卡顿。分块结果作为「虚拟多页」复用阅读页翻页/目录/朗读。
///
/// 分块策略：
/// 1. 优先按章节标题行识别（第X章/节 / 一、二、 / (一) / (二) / 1. 2. 等）
/// 2. 识别不出章节时，按固定 [maxLenPerChunk] 长度在句/段边界切断兜底
/// 3. 返回每块的正文，目录标题另由 [chapterTitlesOf] 提供。
library;

/// 把 [text] 切成若干块。返回空列表表示无需分块（长度未超过 [minChunkChars]）。
///
/// [minChunkChars] 超过后才启用分块（避免短文本无谓切分）；
/// [maxLenPerChunk] 单块目标上限（章节标题段优先占新块起点）。
List<String> chunkText(
  String text, {
  int minChunkChars = 15000,
  int maxLenPerChunk = 10000,
}) {
  final trimmed = text.trim();
  if (trimmed.length <= minChunkChars) return const [];

  final lines = trimmed.split('\n');
  final chunks = <String>[];
  final buf = StringBuffer();
  var bufLen = 0;

  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) chunks.add(s);
    buf.clear();
    bufLen = 0;
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isChapter = _isChapterLine(line);
    // 章节标题 → 新块边界（若当前缓冲非空则先行 flush）
    if (isChapter) {
      if (bufLen > 0) flush();
      buf
        ..write(line)
        ..write('\n');
      bufLen += line.length;
      continue;
    }
    // 非章节：累积，超长则按句/段边界切断
    buf
      ..write(line)
      ..write('\n');
    bufLen += line.length + 1;
    if (bufLen >= maxLenPerChunk) {
      // 在最后一个句号/空行后切断（尽量保持句子完整）
      final s = buf.toString();
      final cut = _lastBoundary(s, maxLenPerChunk);
      if (cut > 0) {
        chunks.add(s.substring(0, cut).trim());
        buf.clear();
        buf.write(s.substring(cut).trim());
        bufLen = buf.length;
      } else {
        flush();
      }
    }
  }
  flush();
  return chunks;
}

/// 返回各块的目录标题（与 `chunkText` 顺序一致）。
///
/// 每个块取 `[章节标题行 或 块首行]` 作为目录项；无法识别章节时用「第 N 章」占位。
List<String> chapterTitlesOf(List<String> chunks) {
  return List.generate(chunks.length, (i) {
    final c = chunks[i];
    // 取块内首个章节标题行
    for (final line in c.split('\n')) {
      if (_isChapterLine(line)) {
        final t = line.trim();
        return t.length > 30 ? '${t.substring(0, 30)}…' : t;
      }
    }
    return '第 ${i + 1} 章';
  });
}

/// 识别章节标题行（中文常见章节编号 / 数字标题）。
bool _isChapterLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  // 中文：第X章 / 第X节 / 第X部分
  if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*[章节部回部分]').hasMatch(t)) {
    return true;
  }
  // 中文序号：一、 二、 (一) (二) 1. 1) (1)
  if (RegExp(r'^[一二三四五六七八九十]+、').hasMatch(t)) return true;
  if (RegExp(r'^[（(]?[一二三四五六七八九十]+[）)]\s*$').hasMatch(t)) return true;
  if (RegExp(r'^\d+\.\s*\S{1,40}').hasMatch(t)) return true;
  if (RegExp(r'^[（(]\d+[）)]\s*\S').hasMatch(t)) return true;
  // 较短标题（≤20字且无句尾标点，可能为标题）
  if (t.length <= 20 &&
      !t.endsWith('。') &&
      !t.endsWith('！') &&
      !t.endsWith('？') &&
      !t.endsWith(':') &&
      !t.endsWith('：')) {
    return true;
  }
  return false;
}

/// 在 [s] 的 [maxClick] 位置附近找最后一个句号/换行/分号作为切断点；
/// 找不到返回 <=0（由上层整体 flush）。
int _lastBoundary(String s, int maxClick) {
  final upto = s.length < maxClick ? s.length : maxClick;
  var found = -1;
  void look(String ch) {
    final idx = s.lastIndexOf(ch, upto);
    if (idx > found) found = idx;
  }

  look('。');
  look('\n');
  look('；');
  look(';');
  look('！');
  look('?');
  look('？');
  if (found <= 0) return -1;
  return found + 1;
}
