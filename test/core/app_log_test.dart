import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/debug/app_log.dart';

void main() {
  setUp(() {
    // 测试期间禁止落盘，仅走内存缓冲
    AppLog.enabled = false;
    AppLog.entries.value = const [];
  });

  tearDown(() {
    AppLog.entries.value = const [];
  });

  group('AppLog.context', () {
    test('无 context 时 entries 的 context 为空串', () {
      AppLog.d('t', 'hello');
      expect(AppLog.entries.value.last.context, '');
      expect(AppLog.entries.value.last.message, 'hello');
    });

    test('有 context 时 entries 的 context 含格式化 KV', () {
      AppLog.d('t', 'chat 出参', {'model': 'qwen2.5', 'tokens': 128});
      final ctx = AppLog.entries.value.last.context;
      expect(ctx, contains('model=qwen2.5'));
      expect(ctx, contains('tokens=128'));
      expect(ctx, startsWith('['));
      expect(ctx, endsWith(']'));
    });

    test('context 值超长时截断到 200 字符并加省略号', () {
      final long = 'x' * 300;
      AppLog.d('t', 'm', {'big': long});
      final ctx = AppLog.entries.value.last.context;
      expect(ctx, contains('big=${'x' * 200}…'));
      expect(ctx, isNot(contains('x' * 300)));
    });

    test('context 为空 Map 时等同于 null', () {
      AppLog.d('t', 'm', <String, dynamic>{});
      expect(AppLog.entries.value.last.context, '');
    });

    test('toText 包含 context 字段', () {
      AppLog.d('t', 'hello', {'k': 'v'});
      final text = AppLog.toText();
      expect(text, contains('[k=v]'));
      expect(text, contains('hello'));
    });

    test('多条日志各自独立保留 context', () {
      AppLog.d('t', 'a', {'x': 1});
      AppLog.w('t', 'b');
      AppLog.e('t', 'c', {'y': 2});
      final es = AppLog.entries.value;
      expect(es[es.length - 3].context, contains('x=1'));
      expect(es[es.length - 2].context, '');
      expect(es[es.length - 1].context, contains('y=2'));
    });
  });
}
