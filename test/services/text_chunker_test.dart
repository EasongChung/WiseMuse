import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/text_chunker.dart';

/// [v0.2.0] 超长文本分块器单测：章节识别优先、字数兜底、目录标题。
void main() {
  // 以换行分隔段落, 模拟真实 docx/txt 的多段排版。
  String para(String prefix, int n) =>
      List.generate(n, (_) => '$prefix 内容句。\n').join();

  group('TextChunker', () {
    test('短文本不触发分块', () {
      final chunks = chunkText('这是一段不长的话。', minChunkChars: 500);
      expect(chunks, isEmpty);
    });

    test('超长但无章节标题时按字数分块(每块不超过上限)', () {
      final text = para('A', 2000); // ~16000 字, 触发分块
      final chunks =
          chunkText(text, minChunkChars: 10000, maxLenPerChunk: 5000);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(5500), reason: '单块不应远超上限');
        expect(c.trim().isNotEmpty, isTrue);
      }
    });

    test('识别中文章节标题并按章节切块 + 生成目录标题', () {
      final body = List.generate(150, (_) => '正文内容在这里描述细节。').join();
      final text = '第一章 绪论\n$body\n第二章 方法\n$body\n第三章 结论\n$body';
      final chunks = chunkText(text, minChunkChars: 50, maxLenPerChunk: 2000);
      expect(chunks.length, greaterThanOrEqualTo(3), reason: '三章至少三块');
      final titles = chapterTitlesOf(chunks);
      expect(titles.any((t) => t.contains('第一章')), isTrue);
      expect(titles.any((t) => t.contains('第二章')), isTrue);
      expect(titles.any((t) => t.contains('第三章')), isTrue);
    });

    test('章节标题行单独成块起点', () {
      final text = '前置说明这句在前。\n一、背景\n${para('X', 300)}';
      final chunks = chunkText(text, minChunkChars: 30, maxLenPerChunk: 600);
      // 章节「一、背景」应成为某块的首行
      final titles = chapterTitlesOf(chunks);
      expect(titles, contains('一、背景'));
    });
  });
}
