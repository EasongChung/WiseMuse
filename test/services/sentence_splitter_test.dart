import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/sentence_splitter.dart';

/// [v0.2.0] 纯文本句子切分单测。
void main() {
  group('splitTextToSentences', () {
    test('按终止标点切句, 标点归入前句', () {
      final out = splitTextToSentences('今天天气真好。我们一起去公园吧！');
      expect(out, ['今天天气真好。', '我们一起去公园吧！']);
    });

    test('空行(段落边界)不产生空句', () {
      final out = splitTextToSentences('第一段话。\n\n第二段话。');
      expect(out, ['第一段话。', '第二段话。']);
    });

    test('CRLF 归一化', () {
      final out = splitTextToSentences('你好。\r\n世界！');
      expect(out, ['你好。', '世界！']);
    });

    test('无终止标点 → 整段一句', () {
      final out = splitTextToSentences('这是一段没有标点的长文');
      expect(out, ['这是一段没有标点的长文']);
    });

    test('超长句按逗号二次切分', () {
      final long = '${'甲' * 60}，${'乙' * 60}';
      final out = splitTextToSentences(long);
      // 二次切分后至少两段, 每段不超过上限
      expect(out.length, greaterThan(1));
      for (final s in out) {
        expect(s.length, lessThanOrEqualTo(125));
      }
    });

    test('空输入返回空列表', () {
      expect(splitTextToSentences(''), isEmpty);
      expect(splitTextToSentences('   \n\n '), isEmpty);
    });
  });
}
