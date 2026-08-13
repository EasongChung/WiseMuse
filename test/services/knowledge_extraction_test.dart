import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wisemuse/core/models/sentence.dart';
import 'package:wisemuse/services/ai_service.dart';
import 'package:wisemuse/services/knowledge_extraction_service.dart';
import 'package:wisemuse/services/openai_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'api_model': 'gpt-4o-mini',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, (call) async {
          if (call.method == 'getAll') return <String, dynamic>{};
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, null);
  });

  group('KnowledgeExtractionService', () {
    Sentence makeSent(String text, {int page = 0, int idx = 0, int ch = 0}) {
      return Sentence.create(
        bookId: 'b1',
        page: page,
        chapter: ch,
        index: idx,
        text: text,
      );
    }

    test('空句子列表返回 errors', () async {
      final service = KnowledgeExtractionService();
      final result = await service.extractForScope(
        bookId: 'b1',
        sentences: [],
        persist: false,
      );
      expect(result.points, isEmpty);
      expect(result.errors, isNotEmpty);
    });

    test('AI 成功时正确提取知识点', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"summary":"一段教材","knowledge_points":[{"text":"学习","type":"word","definition":"study"},{"text":"画蛇添足","type":"idiom","definition":"多余的举动"}]}',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final service = KnowledgeExtractionService(ai: ai);

      final result = await service.extractForScope(
        bookId: 'b1',
        sentences: [makeSent('今天我们学习新知识。')],
        persist: false,
      );

      expect(result.points, hasLength(2));
      expect(result.points[0].text, '学习');
      expect(result.points[0].type.name, 'word');
      expect(result.points[1].text, '画蛇添足');
      expect(result.points[1].type.name, 'idiom');
      expect(result.summary, '一段教材');
      expect(result.errors, isEmpty);
    });

    test('AI 无响应时返回 errors', () async {
      final mockHttp = MockClient((request) async {
        return http.Response('Error', 500);
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final service = KnowledgeExtractionService(ai: ai);

      final result = await service.extractForScope(
        bookId: 'b1',
        sentences: [makeSent('测试文本')],
        persist: false,
      );

      expect(result.errors, isNotEmpty);
      expect(result.points, isEmpty);
    });

    test('persist=true 返回结果正常', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"summary":"测试","knowledge_points":[{"text":"苹果","type":"word","definition":"水果"}]}',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final service = KnowledgeExtractionService(ai: ai);

      final result = await service.extractForScope(
        bookId: 'b1',
        sentences: [makeSent('苹果是水果。')],
        persist: true,
      );

      expect(result.points, hasLength(1));
      expect(result.points[0].text, '苹果');
      expect(result.points[0].definition, '水果');
      expect(result.errors, isEmpty);
    });
  });
}
