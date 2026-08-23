import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/debug/app_log.dart';
import '../core/settings/settings_service.dart';

/// [v0.1.61] 云端大模型 TTS API 客户端（支持 OpenAI 兼容 /audio/speech 端点）。
class CloudTtsClient {
  CloudTtsClient({http.Client? httpClient, Directory? tempDir})
    : _httpClient = httpClient ?? http.Client(),
      _tempDir = tempDir;

  final http.Client _httpClient;
  final Directory? _tempDir;
  static const _tag = 'cloud_tts';

  /// 调用云端 TTS API，将文字转为语音文件。成功返回本地临时文件路径，失败返回 null。
  Future<String?> synthesize({
    required String text,
    String? model,
    String? voice,
    double? speed,
    String? baseUrl,
    String? apiKey,
    String responseFormat = 'mp3',
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return null;

    final settings = SettingsService.instance;
    final url = baseUrl ?? (await settings.getTtsCloudBaseUrl());
    final key = apiKey ?? (await settings.getTtsCloudApiKey());
    final ttsModel = model ?? (await settings.getTtsCloudModel());
    final ttsVoice = voice ?? (await settings.getTtsCloudVoice());

    if (url.isEmpty || key.isEmpty || ttsModel.isEmpty) {
      AppLog.d(_tag, '云端 TTS 未配置完整 (url/key/model 不全)，跳过');
      return null;
    }

    final fullUrl = '${url.endsWith('/') ? url : '$url/'}audio/speech';
    final body = <String, dynamic>{
      'model': ttsModel,
      'input': normalized,
      'voice': ttsVoice.isNotEmpty ? ttsVoice : 'alloy',
      'response_format': responseFormat,
      if (speed != null) 'speed': speed,
    };

    try {
      final resp = await _httpClient
          .post(
            Uri.parse(fullUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        final dir = _tempDir ?? await getTemporaryDirectory();
        final tempFile = File(
          '${dir.path}${Platform.pathSeparator}wm_tts_cloud_${DateTime.now().microsecondsSinceEpoch}.$responseFormat',
        );
        await tempFile.writeAsBytes(resp.bodyBytes, flush: true);
        return tempFile.path;
      } else {
        AppLog.w(_tag, '云端 TTS HTTP ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      AppLog.e(_tag, '云端 TTS 调用异常: $e');
    }
    return null;
  }
}
