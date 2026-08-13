import 'dart:convert';

/// [v0.3.0] 容错解析：剥 ```json 围栏、找首个平衡大括号块、jsonDecode。
///
/// LLM 输出经常带 markdown ```json 围栏或前后多余文本，
/// 本函数智能提取 JSON 对象所在区域并解析，失败返回 null。
Map<String, dynamic>? parseLooseJsonObject(String text) {
  if (text.trim().isEmpty) return null;

  var cleaned = text.trim();

  // 剥 ```json ... ``` 围栏
  if (cleaned.startsWith('```')) {
    final end = cleaned.lastIndexOf('```');
    if (end > 3) {
      // 去掉开头的 ``` 及其可能的语言标记
      final firstNewline = cleaned.indexOf('\n');
      if (firstNewline > 0 && firstNewline < end) {
        cleaned = cleaned.substring(firstNewline + 1, end).trim();
      } else {
        cleaned = cleaned.substring(3, end).trim();
      }
    }
  }

  // 找首个 { 和匹配的 }
  var braceDepth = 0;
  var start = -1;
  for (var i = 0; i < cleaned.length; i++) {
    final ch = cleaned[i];
    if (ch == '{') {
      if (braceDepth == 0) start = i;
      braceDepth++;
    } else if (ch == '}') {
      braceDepth--;
      if (braceDepth == 0 && start >= 0) {
        final jsonStr = cleaned.substring(start, i + 1);
        try {
          final parsed = jsonDecode(jsonStr);
          if (parsed is Map<String, dynamic>) return parsed;
        } catch (_) {
          // 不解构：继续找（可能是嵌套不完整）
        }
      }
    }
  }

  return null;
}
