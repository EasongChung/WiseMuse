import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisemuse/services/translation_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const translateChannel = MethodChannel('com.zqpd.wisemuse/translate');
  const llmChannel = MethodChannel('com.zqpd.wisemuse/llm');
  const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

  dynamic messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // Mock SharedPreferences: in-memory store + channel fallback
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(prefsChannel, (call) async {
      if (call.method == 'getAll') return <String, dynamic>{};
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(translateChannel, null);
    messenger.setMockMethodCallHandler(llmChannel, null);
    messenger.setMockMethodCallHandler(prefsChannel, null);
  });

  group('TranslationEngine', () {
    test('空文本直接返回 null', () async {
      expect(await TranslationEngine.translateWithSettings(''), isNull);
      expect(await TranslationEngine.translateWithSettings('  \n  '), isNull);
    });

    test('读取 settings 中配置的源/目标语种并传递给 ML Kit', () async {
      // 预设语种配置
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('translation_source', 'zh');
      await prefs.setString('translation_target', 'en');

      String? passedSource;
      String? passedTarget;
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'translate') {
          passedSource = call.arguments['source'] as String?;
          passedTarget = call.arguments['target'] as String?;
          expect(call.arguments['text'], '你好');
          return 'Hello';
        }
        return null;
      });

      final result = await TranslationEngine.translateWithSettings('你好');

      expect(passedSource, 'zh');
      expect(passedTarget, 'en');
      expect(result, isNotNull);
      expect(result!.text, 'Hello');
      expect(result.source, 'zh');
      expect(result.target, 'en');
    });

    test('source=auto 时先调用 identifyLanguage 再翻译', () async {
      // source 默认 auto，不预设
      bool identified = false;
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'identifyLanguage') {
          identified = true;
          expect(call.arguments['text'], 'Hello world');
          return 'en';
        }
        if (call.method == 'translate') {
          expect(
            call.arguments['source'],
            'en',
            reason: 'auto 识别后应使用识别结果作为源语种',
          );
          return '你好世界';
        }
        return null;
      });

      final result = await TranslationEngine.translateWithSettings(
        'Hello world',
      );

      expect(identified, isTrue, reason: 'source=auto 时必须调用 identifyLanguage');
      expect(result, isNotNull);
      expect(result!.source, 'en');
      expect(result.text, '你好世界');
    });

    test('identifyLanguage 返回 und 时兜底 zh', () async {
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'identifyLanguage') return 'und';
        if (call.method == 'translate') {
          expect(call.arguments['source'], 'zh', reason: 'und 时应兜底 zh 作为源语种');
          return '翻译结果';
        }
        return null;
      });

      final result = await TranslationEngine.translateWithSettings('一些中文');

      expect(result, isNotNull);
      expect(result!.source, 'zh');
    });

    test('identifyLanguage 抛异常时兜底 zh', () async {
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'identifyLanguage') {
          throw PlatformException(code: 'identify_failed', message: '语种识别异常');
        }
        if (call.method == 'translate') {
          expect(call.arguments['source'], 'zh', reason: '异常时应兜底 zh');
          return '翻译结果';
        }
        return null;
      });

      final result = await TranslationEngine.translateWithSettings('一些中文');

      expect(result, isNotNull);
      expect(result!.source, 'zh');
    });

    test('ML Kit 失败后尝试 LLM，LLM 未加载则跳过，最终 null', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('translation_source', 'zh');
      await prefs.setString('translation_target', 'en');

      // ML Kit translate 返回 null（失败），不走 identifyLanguage
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'translate') return null;
        return null;
      });

      // LLM 可用（isAvailable=true）但未加载（isLoaded=false）
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return true;
        return null;
      });

      // 引擎看到 isLoaded=false 跳过 LLM；云端无 API 配置 → 最终 null
      final result = await TranslationEngine.translateWithSettings('你好');
      expect(result, isNull, reason: 'ML Kit 失败 + LLM 未加载 + 云端无 API → 全部失败');
    });

    test('LLM 不可用时跳过 LLM 回落', () async {
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        if (call.method == 'translate') return null;
        return null;
      });

      // LLM 不可用
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return false;
        return null;
      });

      // 云端 HTTP 会抛异常，但被引擎的 catch 捕获
      final result = await TranslationEngine.translateWithSettings('你好');

      // ML Kit 失败 + LLM 跳过 + 云端 HTTP 异常 → 全部失败 → null
      expect(result, isNull);
    });

    test('全部引擎失败时返回 null（合并回落验证）', () async {
      // ML Kit 全失败，LLM 不可用，云端无 API → 全部失败
      messenger.setMockMethodCallHandler(translateChannel, (call) async {
        return null;
      });
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return false;
        return null;
      });
      final result = await TranslationEngine.translateWithSettings('你好');
      expect(result, isNull);
    });
  });

  group('TranslationResult', () {
    test('构造与字段读取', () {
      final r = TranslationResult(text: 'hello', source: 'zh', target: 'en');
      expect(r.text, 'hello');
      expect(r.source, 'zh');
      expect(r.target, 'en');
    });
  });

  group('TranslationEngineType', () {
    test('4 种引擎类型枚举值', () {
      expect(TranslationEngineType.values, hasLength(4));
      expect(TranslationEngineType.mlkit.name, 'mlkit');
      expect(TranslationEngineType.llm.name, 'llm');
      expect(TranslationEngineType.cloud.name, 'cloud');
      expect(TranslationEngineType.auto.name, 'auto');
    });
  });
}
