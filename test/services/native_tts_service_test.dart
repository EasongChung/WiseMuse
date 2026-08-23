import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/native_tts_service.dart';
import 'package:wisemuse/services/tts_voice_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zqpd.wisemuse/tts-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('TtsVoiceInfo 语言判定与展示标签', () {
    const zh = TtsVoiceInfo(
      name: 'cmn-cn-x-ccc-local',
      locale: 'zh-CN',
      language: 'zh',
      country: 'CN',
      displayLanguage: 'Chinese',
      displayName: 'Chinese (China)',
    );
    expect(zh.isChinese, isTrue);
    expect(zh.readableLabel, contains('中文'));

    const en = TtsVoiceInfo(
      name: 'en-us-x-sfg-local',
      locale: 'en-US',
      language: 'en',
      country: 'US',
      displayLanguage: 'English',
      displayName: 'English (United States)',
    );
    expect(en.isEnglish, isTrue);
    expect(en.readableLabel, contains('英文'));
  });

  test('getVoices 解析系统音色列表', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getVoices');
      return [
        {
          'name': 'cmn-cn-x-ccc-local',
          'locale': 'zh-CN',
          'language': 'zh',
          'country': 'CN',
          'displayLanguage': 'Chinese',
          'displayName': 'Chinese (China) (cmn-cn-x-ccc-local)',
          'isNetworkConnectionRequired': false,
          'quality': 400,
        },
        {
          'name': 'en-us-x-sfg-local',
          'locale': 'en-US',
          'language': 'en',
          'country': 'US',
          'displayLanguage': 'English',
          'displayName': 'English (United States) (en-us-x-sfg-local)',
          'isNetworkConnectionRequired': false,
          'quality': 300,
        },
      ];
    });

    final service = NativeTtsService(channel: channel);
    final voices = await service.getVoices();
    expect(voices, hasLength(2));
    expect(voices[0].isChinese, isTrue);
    expect(voices[0].readableLabel, contains('中文'));
    expect(voices[1].isEnglish, isTrue);
    expect(voices[1].readableLabel, contains('英文'));
  });

  test('playFile 成功调用原生', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'playFile');
      expect(call.arguments, {'path': '/test/audio.mp3'});
      return true;
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.playFile('/test/audio.mp3'), isTrue);
  });

  test('init 返回原生引擎真实状态', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'init');
      return true;
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.init(), isTrue);
  });

  test('speak 去除首尾空白并等待原生完成结果', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'speak');
      expect(call.arguments, {'text': '测试句子'});
      return true;
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.speak('  测试句子  '), isTrue);
  });

  test('空文本不下发 MethodChannel', () async {
    var invoked = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked = true;
      return true;
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.speak('  \n  '), isFalse);
    expect(invoked, isFalse);
  });

  test('被打断或原生异常时 speak 返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'tts_failed', message: '朗读被停止');
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.speak('测试'), isFalse);
  });

  test('stop 调用原生取消屏障并返回结果', () async {
    var stopped = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'stop');
      stopped = true;
      return true;
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.stop(), isTrue);
    expect(stopped, isTrue);
  });

  test('stop 原生返回 false 时取消屏障失败', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    final service = NativeTtsService(channel: channel);
    expect(await service.stop(), isFalse);
  });

  test('stop 通道异常时取消屏障失败', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'tts_stop_failed');
    });

    final service = NativeTtsService(channel: channel);
    expect(await service.stop(), isFalse);
  });
}
