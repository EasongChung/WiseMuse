import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wisemuse/services/llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const llmChannel = MethodChannel('com.zqpd.wisemuse/llm');
  late dynamic messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      await LlmService.instance.unload();
    } catch (_) {}
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

    test('ensureReady 自动加载默认模型', () async {
      var initCount = 0;
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'init') {
          initCount++;
          expect(call.arguments['modelPath'], '/models/default.gguf');
          return true;
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({
        'default_local_model': '/models/default.gguf',
        'auto_load_local_model': true,
      });

      expect(await LlmService.instance.ensureReady(), isTrue);
      expect(initCount, 1);
      expect(LlmService.instance.isLoaded, isTrue);
    });

    test('ensureReady 兼容旧 local_model_path', () async {
      var initPath = '';
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'init') {
          initPath = call.arguments['modelPath'] as String;
          return true;
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({
        'local_model_path': '/models/legacy.gguf',
      });

      expect(await LlmService.instance.ensureReady(), isTrue);
      expect(initPath, '/models/legacy.gguf');
    });

    test('ensureReady 关闭自动加载时不初始化', () async {
      var initCount = 0;
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'init') initCount++;
        return true;
      });
      SharedPreferences.setMockInitialValues({
        'default_local_model': '/models/default.gguf',
        'auto_load_local_model': false,
      });

      expect(await LlmService.instance.ensureReady(), isFalse);
      expect(initCount, 0);
    });

    test('并发 ensureReady 只初始化一次', () async {
      var initCount = 0;
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'init') {
          initCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({
        'default_local_model': '/models/default.gguf',
      });

      final results = await Future.wait([
        LlmService.instance.ensureReady(),
        LlmService.instance.ensureReady(),
        LlmService.instance.ensureReady(),
      ]);
      expect(results, [true, true, true]);
      expect(initCount, 1);
    });
  });
}
