import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const llmChannel = MethodChannel('com.zqpd.wisemuse/llm');
  late dynamic messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(llmChannel, null);
  });

  group('LlmService chat and token cleaning', () {
    test('默认 predictLength 为 512', () async {
      int? capturedPredictLength;
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'send') {
          capturedPredictLength = call.arguments['predictLength'] as int?;
          return '回答内容';
        }
        return null;
      });

      final result = await LlmService.instance.chat('测试问题');
      expect(capturedPredictLength, 512);
      expect(result, '回答内容');
    });

    test('清理 MiniCPM 特殊标记 (<用户>, <AI>, <s>, </s>, <reserved_*>)', () async {
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'send') {
          return '<s><用户>你好<AI><reserved_123>这是MiniCPM5的回答</s>';
        }
        return null;
      });

      final result = await LlmService.instance.chat('测试问题');
      expect(result, '你好这是MiniCPM5的回答');
    });

    test('清理 Qwen thinking 思考块与 ChatML 标记', () async {
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'send') {
          return '<think>思考中...</think><|im_start|>answer正式回答<|im_end|>';
        }
        return null;
      });

      final result = await LlmService.instance.chat('测试问题');
      expect(result, '正式回答');
    });

    test('短原文清洗为空时安全记录日志，不抛 RangeError', () async {
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'send') {
          return '<s>';
        }
        return null;
      });

      final result = await LlmService.instance.chat('测试问题');
      expect(result, isEmpty);
    });
  });
}
