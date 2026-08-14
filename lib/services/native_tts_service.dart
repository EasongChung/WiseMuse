import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';
import 'tts_service.dart';

/// [v0.4.1] 系统 TextToSpeech 实现（MethodChannel → TtsBridge.kt）。
///
/// TTS 走原生桥而非插件，规避 AGP9 Built-in Kotlin 对第三方插件的
/// KGP 兼容风险。请求取消、latest-wins 与引擎重建均由原生单线程状态机保证：
///
/// - 新 [speak] 会停止旧文本，并让旧 Future 返回 false；
/// - [stop] 返回后，旧请求不会再次发起播放；
/// - [speak] 仅在原生收到 onDone 时返回 true，被打断或失败返回 false。
class NativeTtsService implements TtsService {
  static const _tag = 'tts';
  static const _defaultChannel = MethodChannel('com.zqpd.wisemuse/tts');

  NativeTtsService({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  final MethodChannel _channel;

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
    final normalized = text.trim();
    if (normalized.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('speak', {
        'text': normalized,
      });
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
  Future<bool> stop() async {
    try {
      final ok = await _channel.invokeMethod<bool>('stop');
      if (ok != true) AppLog.w(_tag, 'stop 未建立取消屏障');
      return ok ?? false;
    } catch (e) {
      AppLog.w(_tag, 'stop 失败: $e');
      return false;
    }
  }

  /// [v2.8.0] 设置音色（名称按系统 TTS 服务返回。空串=系统默认）。
  @override
  Future<void> setVoice(String name) async {
    try {
      await _channel.invokeMethod<void>('setVoice', {'name': name});
    } catch (e) {
      AppLog.e(_tag, 'setVoice 失败: $e');
    }
  }
}
