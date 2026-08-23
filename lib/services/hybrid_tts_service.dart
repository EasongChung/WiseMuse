import 'dart:io';

import '../core/debug/app_log.dart';
import '../core/settings/settings_service.dart';
import 'cloud_tts_client.dart';
import 'native_tts_service.dart';
import 'tts_service.dart';
import 'tts_voice_info.dart';

/// [v0.1.61] 混合双引擎 TTS 服务：云端大模型 API 优先 + 系统原生 TextToSpeech 回退。
class HybridTtsService implements TtsService {
  HybridTtsService({NativeTtsService? native, CloudTtsClient? cloud})
    : _native = native ?? NativeTtsService(),
      _cloud = cloud ?? CloudTtsClient();

  static final HybridTtsService instance = HybridTtsService();

  final NativeTtsService _native;
  final CloudTtsClient _cloud;
  static const _tag = 'hybrid_tts';

  @override
  Future<bool> init() => _native.init();

  @override
  Future<bool> speak(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return false;

    final settings = SettingsService.instance;
    final engine = await settings.getTtsEngine();
    final rate = await settings.getTtsRate();

    if (engine == 'cloud' || engine == 'auto') {
      try {
        final audioPath = await _cloud.synthesize(
          text: normalized,
          speed: rate,
        );
        if (audioPath != null && await File(audioPath).exists()) {
          AppLog.d(_tag, '播放云端大模型 TTS: $audioPath');
          final ok = await _native.playFile(audioPath);
          try {
            await File(audioPath).delete();
          } catch (_) {}
          if (ok) return true;
          AppLog.w(_tag, '云端音频播放失败，回落系统原生 TTS');
        }
      } catch (e) {
        AppLog.w(_tag, '云端 TTS 异常: $e，回落系统原生 TTS');
      }
    }

    // 回落系统原生 TTS
    return _native.speak(normalized);
  }

  @override
  Future<bool> stop() => _native.stop();

  @override
  Future<void> setVoice(String name) => _native.setVoice(name);

  @override
  Future<void> setRate(double rate) => _native.setRate(rate);

  /// 获取系统真实音色列表。
  Future<List<TtsVoiceInfo>> getVoices() => _native.getVoices();

  /// 试听系统音色。
  Future<bool> previewSystemVoice(String voiceName, String sampleText) async {
    await _native.stop();
    await _native.setVoice(voiceName);
    return _native.speak(sampleText);
  }

  /// 试听云端大模型音色。
  Future<bool> previewCloudVoice({
    required String sampleText,
    String? model,
    String? voice,
    String? baseUrl,
    String? apiKey,
  }) async {
    await _native.stop();
    final audioPath = await _cloud.synthesize(
      text: sampleText,
      model: model,
      voice: voice,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
    if (audioPath == null) return false;
    final ok = await _native.playFile(audioPath);
    try {
      await File(audioPath).delete();
    } catch (_) {}
    return ok;
  }
}
