import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wisemuse/services/cloud_tts_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test-key',
      'tts_cloud_model': 'tts-1',
      'tts_cloud_voice': 'alloy',
    });
  });

  group('CloudTtsClient', () {
    test('正确发送 /audio/speech 请求并保存临时文件', () async {
      String? capturedUrl;
      String? capturedAuth;
      Map<String, dynamic>? capturedBody;

      final mockHttp = MockClient((request) async {
        capturedUrl = request.url.toString();
        capturedAuth = request.headers['authorization'];
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          [1, 2, 3, 4],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      });

      final client = CloudTtsClient(
        httpClient: mockHttp,
        tempDir: Directory.systemTemp,
      );
      final resultPath = await client.synthesize(text: '测试文字', speed: 0.9);

      expect(capturedUrl, 'https://api.example.com/v1/audio/speech');
      expect(capturedAuth, 'Bearer sk-test-key');
      expect(capturedBody!['model'], 'tts-1');
      expect(capturedBody!['input'], '测试文字');
      expect(capturedBody!['voice'], 'alloy');
      expect(capturedBody!['speed'], 0.9);

      expect(resultPath, isNotNull);
      expect(File(resultPath!).existsSync(), isTrue);
      expect(File(resultPath).readAsBytesSync(), [1, 2, 3, 4]);

      // 清理临时文件
      try {
        File(resultPath).deleteSync();
      } catch (_) {}
    });

    test('未配置 API 时返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      final mockHttp = MockClient((request) async {
        throw Exception('不应被调用');
      });

      final client = CloudTtsClient(
        httpClient: mockHttp,
        tempDir: Directory.systemTemp,
      );
      final result = await client.synthesize(text: '你好');
      expect(result, isNull);
    });

    test('HTTP 错误状态码返回 null', () async {
      final mockHttp = MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final client = CloudTtsClient(
        httpClient: mockHttp,
        tempDir: Directory.systemTemp,
      );
      final result = await client.synthesize(text: '你好');
      expect(result, isNull);
    });
  });
}
