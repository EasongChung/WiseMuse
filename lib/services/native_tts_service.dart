import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';
import 'tts_service.dart';
import 'tts_voice_info.dart';

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

  /// [v0.1.28] 设置音色（名称按系统 TTS 服务返回。空串=系统默认）。
  @override
  Future<void> setVoice(String name) async {
    try {
      await _channel.invokeMethod<void>('setVoice', {'name': name});
    } catch (e) {
      AppLog.e(_tag, 'setVoice 失败: $e');
    }
  }

  /// [v0.1.44] 设置语速（0.5~2.0）。
  @override
  Future<void> setRate(double rate) async {
    try {
      await _channel.invokeMethod<void>('setRate', {'rate': rate});
    } catch (e) {
      AppLog.e(_tag, 'setRate 失败: $e');
    }
  }

  /// [v0.1.61] 获取系统已安装的全部真实 TTS 音色。
  Future<List<TtsVoiceInfo>> getVoices() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getVoices');
      if (raw == null || raw.isEmpty) return const [];
      return raw
          .map((item) => TtsVoiceInfo.fromMap(item as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      AppLog.e(_tag, 'getVoices 失败: $e');
      return const [];
    }
  }

  /// [v0.1.61] 播放本地音频文件（用于播放云端大模型生成的语音）。
  Future<bool> playFile(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('playFile', {'path': path});
      return ok ?? false;
    } on PlatformException catch (e) {
      AppLog.e(_tag, 'playFile 失败: ${e.message}');
      return false;
    } catch (e) {
      AppLog.e(_tag, 'playFile 异常: $e');
      return false;
    }
  }
}
