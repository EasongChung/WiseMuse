import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wisemuse/services/cloud_tts_client.dart';
import 'package:wisemuse/services/hybrid_tts_service.dart';
import 'package:wisemuse/services/native_tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zqpd.wisemuse/tts-test-hybrid');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('HybridTtsService', () {
    test('engine=system 直接调用系统 speak', () async {
      SharedPreferences.setMockInitialValues({'tts_engine': 'system'});

      var speakInvoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          speakInvoked = true;
          return true;
        }
        return false;
      });

      final native = NativeTtsService(channel: channel);
      final hybrid = HybridTtsService(native: native);

      final ok = await hybrid.speak('系统朗读');
      expect(ok, isTrue);
      expect(speakInvoked, isTrue);
    });

    test('engine=cloud 优先调用云端 API 并由原生 playFile 播放', () async {
      SharedPreferences.setMockInitialValues({
        'tts_engine': 'cloud',
        'api_base_url': 'https://api.example.com/v1',
        'api_key': 'sk-test',
        'tts_cloud_model': 'tts-1',
      });

      var playFileInvoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'playFile') {
          playFileInvoked = true;
          return true;
        }
        return false;
      });

      final mockHttp = MockClient((request) async {
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      });

      final native = NativeTtsService(channel: channel);
      final cloud = CloudTtsClient(
        httpClient: mockHttp,
        tempDir: Directory.systemTemp,
      );
      final hybrid = HybridTtsService(native: native, cloud: cloud);

      final ok = await hybrid.speak('云端朗读');
      expect(ok, isTrue);
      expect(playFileInvoked, isTrue);
    });

    test('engine=cloud 云端失败时回退系统原生 speak', () async {
      SharedPreferences.setMockInitialValues({
        'tts_engine': 'cloud',
        'api_base_url': 'https://api.example.com/v1',
        'api_key': 'sk-test',
        'tts_cloud_model': 'tts-1',
      });

      var fallbackSpeakInvoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          fallbackSpeakInvoked = true;
          return true;
        }
        return false;
      });

      final mockHttp = MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final native = NativeTtsService(channel: channel);
      final cloud = CloudTtsClient(
        httpClient: mockHttp,
        tempDir: Directory.systemTemp,
      );
      final hybrid = HybridTtsService(native: native, cloud: cloud);

      final ok = await hybrid.speak('回退朗读');
      expect(ok, isTrue);
      expect(fallbackSpeakInvoked, isTrue);
    });
  });
}
