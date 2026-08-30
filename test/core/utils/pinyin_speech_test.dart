import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/utils/pinyin_speech.dart';

void main() {
  group('PinyinSpeech.transform', () {
    test('声母句首转为中文谐音字', () {
      expect(PinyinSpeech.transform('b：双唇不送气清塞音。'), '玻：双唇不送气清塞音。');
      expect(PinyinSpeech.transform('p：双唇送气清塞音。'), '泼：双唇送气清塞音。');
    });

    test('韵母句首转为中文谐音字', () {
      expect(PinyinSpeech.transform('ai：复韵母 a-i。'), '哀：复韵母 a-i。');
      expect(PinyinSpeech.transform('ang：后鼻韵母。'), '昂：后鼻韵母。');
    });

    test('整体认读音节转为中文谐音字', () {
      expect(PinyinSpeech.transform('zhi：整体认读音节。'), '知：整体认读音节。');
    });

    test('非拼音句首保持原样', () {
      expect(PinyinSpeech.transform('第 1 单元：声母。'), '第 1 单元：声母。');
      expect(PinyinSpeech.transform('目录。'), '目录。');
    });

    test('enabled=false 时不转换', () {
      expect(
        PinyinSpeech.transform('b：双唇不送气清塞音。', enabled: false),
        'b：双唇不送气清塞音。',
      );
    });

    test('英文单词不被误转换', () {
      // cat 不在拼音表，保持原样。
      expect(PinyinSpeech.transform('cat：猫。'), 'cat：猫。');
      expect(PinyinSpeech.transform('hello：你好。'), 'hello：你好。');
    });

    test('句中拼音不受影响', () {
      // 句首是「示范」不是拼音，整体不转换。
      expect(
        PinyinSpeech.transform('示范：玻 泼 摸 佛 / 广播 b b b。'),
        '示范：玻 泼 摸 佛 / 广播 b b b。',
      );
    });
  });
}
