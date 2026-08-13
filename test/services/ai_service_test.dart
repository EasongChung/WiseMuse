import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisemuse/services/ai_service.dart';
import 'package:wisemuse/services/llm_service.dart';
import 'package:wisemuse/services/openai_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const llmChannel = MethodChannel('com.zqpd.wisemuse/llm');
  const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

  late dynamic messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'api_model': 'gpt-4o-mini',
      'prefer_offline': false,
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(llmChannel, null);
    messenger.setMockMethodCallHandler(prefsChannel, null);
  });

  group('AiService 云端优先', () {
    test('云端成功时返回 cloud 结果，不触本地', () async {
      var touchedLocal = false;

      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        touchedLocal = true;
        return null;
      });

      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '云端回答'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final result = await ai.complete('Hello');

      expect(result, isNotNull);
      expect(result!.engine, AiEngine.cloud);
      expect(result.text, '云端回答');
      expect(touchedLocal, isFalse);
    });

    test('云端失败时回落本地', () async {
      final mockHttp = MockClient((request) async {
        return http.Response('Error', 500);
      });

      // 预初始化本地 llama 引擎（_loaded=true）
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'init') return true;
        if (call.method == 'isAvailable') return true;
        if (call.method == 'send') return '本地回答';
        return null;
      });
      final llm = LlmService();
      await llm.init('dummy'); // 设 _loaded = true

      final ai = AiService(
        llm: llm,
        client: OpenAiClient(httpClient: mockHttp),
      );
      final result = await ai.complete('Hello');

      expect(result, isNotNull);
      expect(result!.engine, AiEngine.local);
      expect(result.text, '本地回答');
    });

    test('全部失败返回 null', () async {
      final mockHttp = MockClient((request) async {
        return http.Response('Error', 500);
      });

      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'isAvailable') return false;
        return null;
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final result = await ai.complete('Hello');

      expect(result, isNull);
    });
  });

  group('AiService preferOffline=true', () {
    test('本地优先，本地成功不触云端', () async {
      SharedPreferences.setMockInitialValues({
        'prefer_offline': true,
        'api_base_url': 'https://api.example.com/v1',
        'api_key': 'sk-test',
        'api_model': 'gpt-4o-mini',
      });

      var touchedCloud = false;

      // 预初始化本地 llama 引擎
      messenger.setMockMethodCallHandler(llmChannel, (call) async {
        if (call.method == 'init') return true;
        if (call.method == 'isAvailable') return true;
        if (call.method == 'send') return '本地回答';
        return null;
      });
      final llm = LlmService();
      await llm.init('dummy');

      final mockHttp = MockClient((request) async {
        touchedCloud = true;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '云端回答'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(
        llm: llm,
        client: OpenAiClient(httpClient: mockHttp),
      );
      final result = await ai.complete('Hello');

      expect(result, isNotNull);
      expect(result!.engine, AiEngine.local);
      expect(touchedCloud, isFalse);
    });
  });

  group('AiService isCloudReady / isLocalReady', () {
    test('云端已配置时 isCloudReady 为 true', () async {
      final ai = AiService();
      expect(await ai.isCloudReady(), isTrue);
    });

    test('云端未配置时 isCloudReady 为 false', () async {
      SharedPreferences.setMockInitialValues({});
      final ai = AiService();
      expect(await ai.isCloudReady(), isFalse);
    });
  });
}
