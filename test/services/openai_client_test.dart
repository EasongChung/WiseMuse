import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisemuse/core/models/chat_message.dart';
import 'package:wisemuse/services/openai_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test-key',
      'api_model': 'gpt-4o-mini',
    });
  });

  group('OpenAiClient', () {
    test('请求的 URL 和 Headers 正确', () async {
      String? capturedUrl;
      String? capturedAuth;
      final mock = MockClient((request) async {
        capturedUrl = request.url.toString();
        capturedAuth = request.headers['authorization'];
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Hello'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = OpenAiClient(httpClient: mock);
      final result = await client.chat(user: 'Hi');

      expect(capturedUrl, 'https://api.example.com/v1/chat/completions');
      expect(capturedAuth, 'Bearer sk-test-key');
      expect(result, 'Hello');
    });

    test('jsonObject=true 时请求体含 response_format', () async {
      Map<String, dynamic>? capturedBody;
      final mock = MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"ok":true}'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = OpenAiClient(httpClient: mock);
      await client.chat(user: 'test', jsonObject: true);

      expect(capturedBody!['response_format'], {'type': 'json_object'});
    });

    test('API 未配置时返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      final mock = MockClient((request) async {
        throw Exception('不应被调用');
      });
      final client = OpenAiClient(httpClient: mock);
      final result = await client.chat(user: 'Hi');
      expect(result, isNull);
    });

    test('HTTP 非 200 返回 null', () async {
      final mock = MockClient((_) async => http.Response('Error', 500));
      final client = OpenAiClient(httpClient: mock);
      final result = await client.chat(user: 'Hi');
      expect(result, isNull);
    });

    test('空 content 返回 null', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': ''},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final client = OpenAiClient(httpClient: mock);
      final result = await client.chat(user: 'Hi');
      expect(result, isNull);
    });

    test('历史消息按顺序插入当前问题之前', () async {
      List<dynamic>? capturedMessages;
      final history = [
        ChatMessage.create(role: 'user', content: '第一问'),
        ChatMessage.create(role: 'assistant', content: '第一答'),
      ];
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        capturedMessages = body['messages'] as List?;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });

      await OpenAiClient(
        httpClient: mock,
      ).chat(system: '系统', user: '第二问', history: history);

      expect(capturedMessages!.map((m) => m['content']), [
        '系统',
        '第一问',
        '第一答',
        '第二问',
      ]);
    });

    test('历史消息按字符预算从最新消息保留', () {
      final history = [
        ChatMessage.create(role: 'user', content: '旧问题'),
        ChatMessage.create(role: 'assistant', content: '旧回答'),
        ChatMessage.create(role: 'user', content: '新问题'),
      ];
      final messages = OpenAiClient.buildTextHistory(history, maxChars: 5);
      expect(messages.map((m) => m['content']), ['新问题']);
    });

    test('system prompt 出现在 messages 中', () async {
      List<dynamic>? capturedMessages;
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        capturedMessages = body['messages'] as List?;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = OpenAiClient(httpClient: mock);
      await client.chat(system: '你是一名助手', user: '你好');

      expect(capturedMessages, hasLength(2));
      expect(capturedMessages![0]['role'], 'system');
      expect(capturedMessages![0]['content'], '你是一名助手');
      expect(capturedMessages![1]['role'], 'user');
    });
  });
}
