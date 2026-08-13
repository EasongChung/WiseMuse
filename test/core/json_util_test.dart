import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/core/utils/json_util.dart';

void main() {
  group('parseLooseJsonObject', () {
    test('纯 JSON 直接解析', () {
      final result = parseLooseJsonObject('{"a":1,"b":"hello"}');
      expect(result, isNotNull);
      expect(result!['a'], 1);
      expect(result['b'], 'hello');
    });

    test('含 ```json 围栏', () {
      final text = '```json\n{"key": "value"}\n```';
      final result = parseLooseJsonObject(text);
      expect(result, isNotNull);
      expect(result!['key'], 'value');
    });

    test('围栏含语言标记', () {
      final text = '```json\n{"n": 42}\n```';
      final result = parseLooseJsonObject(text);
      expect(result, isNotNull);
      expect(result!['n'], 42);
    });

    test('有多余前缀文本', () {
      final text = '这是一段说明\n{"a":1}\n后缀';
      final result = parseLooseJsonObject(text);
      expect(result, isNotNull);
      expect(result!['a'], 1);
    });

    test('空字符串返回 null', () {
      expect(parseLooseJsonObject(''), isNull);
      expect(parseLooseJsonObject('  '), isNull);
    });

    test('无有效 JSON 返回 null', () {
      expect(parseLooseJsonObject('纯文本无大括号'), isNull);
    });

    test('嵌套 JSON 正确解析', () {
      final text = '{"outer":{"inner":[1,2,3]}}';
      final result = parseLooseJsonObject(text);
      expect(result, isNotNull);
      expect((result!['outer'] as Map)['inner'], [1, 2, 3]);
    });
  });
}
