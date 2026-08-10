import 'package:flutter/services.dart';

import 'asr_service.dart';

/// [v0.1.0] Vosk 离线语音识别实现（MethodChannel → VoskBridge.kt）。
class VoskAsrService implements AsrService {
  static const _channel = MethodChannel('com.zqpd.wisemuse/vosk');
  bool _loaded = false;

  @override
  Future<bool> init(String modelPath) async {
    final ok = await _channel.invokeMethod<bool>('init', {
      'modelPath': modelPath,
    });
    _loaded = ok ?? false;
    return _loaded;
  }

  @override
  bool get isLoaded => _loaded;

  @override
  Future<bool> start() async {
    final ok = await _channel.invokeMethod<bool>('start');
    return ok ?? false;
  }

  @override
  Future<String> stop() async {
    final text = await _channel.invokeMethod<String>('stop');
    return text ?? '';
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod('dispose');
    _loaded = false;
  }
}
