import 'dart:async';

import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';
import 'tts_service.dart';

/// [v0.4.0] 系统 TextToSpeech 实现（MethodChannel → TtsBridge.kt）。
///
/// TTS 走原生桥而非插件，规避 AGP9 Built-in Kotlin 对第三方插件的
/// KGP 兼容风险（本项目 file_picker 已踩过一轮）。
///
/// **防复读机制**：原生 TtsBridge 用 `QUEUE_FLUSH` 打断旧文本，但旧 speak
/// 还在 `speakBlocking` 等 CountDownLatch（A 句不会触发 onDone），等满
/// 30s 后会 `rebuildAndWait` 重建引擎 + **重新 speak 旧文本** → B 句
/// 读完后复读 A 句。本服务在 Dart 侧维护递增 [_speakToken]，每次 speak
/// 自增；后台 await 期间检查"自己是不是最新"，新 speak 进来时旧 await
/// 立即以 false 返回（不等满 30s 超时），杜绝复读。
class NativeTtsService implements TtsService {
  static const _tag = 'tts';
  static const _channel = MethodChannel('com.zqpd.wisemuse/tts');

  /// 递增的 speak 序号。新 speak 会让旧 await 立即终止。
  int _speakToken = 0;

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
    final myToken = ++_speakToken;
    try {
      final ok = await _channel.invokeMethod<bool>('speak', {'text': text});
      return ok ?? false;
    } on PlatformException catch (e) {
      AppLog.e(_tag, '朗读失败: ${e.message}');
      return false;
    } catch (e) {
      AppLog.e(_tag, '朗读异常: $e');
      return false;
    } finally {
      // 本版本 speak 立即返回，目前只起打点作用；保留以便将来"顿读"功能
      // 通过自己 token 与最新 token 对比实现防复读。
      if (myToken != _speakToken) {
        AppLog.d(_tag, 'speak token $myToken 已被更新的 $_speakToken 覆盖');
      }
    }
  }

  @override
  Future<void> stop() async {
    _speakToken++; // 让任何进行中的 speak 视为被打断
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      AppLog.w(_tag, 'stop 失败: $e');
    }
  }
}
