import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/native_tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zqpd.wisemuse/tts-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
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
