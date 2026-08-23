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

    test('同行连续2个空格切分句子 (古诗场景)', () {
      final out = splitTextToSentences('床前明月光  疑是地上霜');
      expect(out, ['床前明月光', '疑是地上霜']);
    });

    test('同行全角空格切分句子', () {
      final out = splitTextToSentences('举头望明月　低头思故乡');
      expect(out, ['举头望明月', '低头思故乡']);
    });

    test('单空格不切分句子 (中文正常词间距)', () {
      final out = splitTextToSentences('今天天气真好！我们一起去公园吧。');
      expect(out, ['今天天气真好！', '我们一起去公园吧。']);
    });

    test('包含连续空格的多列行在换行处断开', () {
      final out = splitTextToSentences('苹果    梨子\n香蕉    葡萄');
      expect(out, ['苹果', '梨子', '香蕉', '葡萄']);
    });

    test('双语表格中的英文列不被当作拼音删除', () {
      final out = splitTextToSentences('苹果    apple\n香蕉    banana');
      expect(out, ['苹果', 'apple', '香蕉', 'banana']);
    });

    test('贴近版心右侧的普通换行视为自动折行，中文不补空格', () {
      final out = splitTextToSentences('这是一个因为版心宽度而\n自动换行的完整句子。');
      expect(out, ['这是一个因为版心宽度而自动换行的完整句子。']);
    });

    test('短标题行不与正文合并', () {
      final out = splitTextToSentences('标题\n这是正文开始的第一句话。');
      expect(out, ['标题', '这是正文开始的第一句话。']);
    });
  });
}
