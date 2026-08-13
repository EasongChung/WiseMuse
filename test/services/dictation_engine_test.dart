import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/services/dictation_engine.dart';

void main() {
  group('DictationMode', () {
    test('三种模式枚举', () {
      expect(DictationMode.values, hasLength(3));
      expect(DictationMode.charSelect.label, '听音选字');
      expect(DictationMode.spelling.label, '拼写');
      expect(DictationMode.voice.label, '语音跟读');
    });
  });

  group('DictationEngine 听音选字', () {
    test('生成 4 个选项且包含正确答案', () {
      final q = DictationEngine.makeCharSelectQuestion('大');
      expect(q.word, '大');
      expect(q.lang, 'zh');
      expect(q.options, isNotNull);
      expect(q.options!.length, 4);
      expect(q.options, contains('大'));
      // 选项不重复
      expect(q.options!.toSet().length, 4);
    });

    test('选项为同音/形近字（来自字库）', () {
      final q = DictationEngine.makeCharSelectQuestion('的');
      expect(q.options!.toSet(), containsAll(['的', '得', '地']));
    });

    test('字库无该字时从常用字补充到 4 个', () {
      final q = DictationEngine.makeCharSelectQuestion('我');
      expect(q.options!.length, 4);
      expect(q.options, contains('我'));
    });

    test('checkCharSelect 正确判断', () {
      expect(DictationEngine.checkCharSelect('大', '大'), isTrue);
      expect(DictationEngine.checkCharSelect('大', '达'), isFalse);
      expect(DictationEngine.checkCharSelect('大', ' 大 '), isTrue);
    });
  });

  group('DictationEngine 拼写', () {
    test('checkSpelling 忽略大小写与空白', () {
      expect(DictationEngine.checkSpelling('hello', 'hello'), isTrue);
      expect(DictationEngine.checkSpelling('Hello', 'hello'), isTrue);
      expect(DictationEngine.checkSpelling('hello', 'HELLO'), isTrue);
      expect(DictationEngine.checkSpelling('hello', '  hello  '), isTrue);
      expect(DictationEngine.checkSpelling('hello', 'hallo'), isFalse);
    });
  });

  group('DictationEngine makeQuestions', () {
    test('选字模式只取单字', () {
      final qs = DictationEngine.makeQuestions(
        ['大', '你好', '小', '山'],
        mode: DictationMode.charSelect,
        count: 10,
      );
      // 「你好」是双字，跳过；大/小/山各 1 题
      expect(qs, hasLength(3));
      expect(qs.every((q) => q.options != null), isTrue);
    });

    test('拼写模式为每个词生成题目', () {
      final qs = DictationEngine.makeQuestions(
        ['hello', 'world'],
        mode: DictationMode.spelling,
        count: 10,
      );
      expect(qs, hasLength(2));
      expect(qs[0].word, 'hello');
      expect(qs[0].options, isNull);
    });

    test('count 限制题目数', () {
      final qs = DictationEngine.makeQuestions(
        ['大', '小', '上', '下', '人'],
        mode: DictationMode.charSelect,
        count: 3,
      );
      expect(qs, hasLength(3));
    });

    test('空词列表返回空', () {
      expect(
        DictationEngine.makeQuestions([], mode: DictationMode.charSelect),
        isEmpty,
      );
    });
  });
}
