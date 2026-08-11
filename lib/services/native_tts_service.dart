import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';
import 'tts_service.dart';

/// [v0.1.0] 系统 TextToSpeech 实现（MethodChannel → TtsBridge.kt）。
///
/// TTS 走原生桥而非插件，规避 AGP9 Built-in Kotlin 对第三方插件的
/// KGP 兼容风险（本项目 file_picker 已踩过一轮）。
class NativeTtsService implements TtsService {
  static const _tag = 'tts';
  static const _channel = MethodChannel('com.zqpd.wisemuse/tts');

  @override
  Future<bool> init() async {
    try {
      final ok = await _channel.invokeMethod<bool>('init');
      return ok ?? false;
    } catch (e) {
      AppLog.e(_tag, 'init 失败: $e');
      return false;
    }
  }

  @override
  Future<bool> speak(String text) async {
    try {
      final ok = await _channel.invokeMethod<bool>('speak', {'text': text});
      return ok ?? false;
    } on PlatformException catch (e) {
      AppLog.e(_tag, '朗读失败: ${e.message}');
      return false;
    } catch (e) {
      AppLog.e(_tag, '朗读异常: $e');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      AppLog.w(_tag, 'stop 失败: $e');
    }
  }
}
