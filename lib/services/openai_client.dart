import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/debug/app_log.dart';
import '../core/settings/settings_service.dart';

/// [v0.3.0] OpenAI 兼容 API 客户端（通用云端 LLM 调用）。
///
/// 封装 [response_format: {type: "json_object"}] 支持；单轮（system+user）接口；
/// 多轮消息支持放 S7 扩展。
///
/// 可注入 [httpClient] 测试；连接参数默认从 [SettingsService] 读取，
/// 也支持显式传入（覆写设置页配置）。
class OpenAiClient {
  OpenAiClient({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  static const _tag = 'openai';

  /// 调用云端 LLM，返回回答文本（trim）。失败/未配置/超时返回 null。
  ///
  /// [system] 系统 prompt（可选）；[user] 用户 prompt（必填）。
  /// [jsonObject] 为 true 时传 response_format。
  /// [baseUrl]/[apiKey]/[model] 可显式传入覆写 settings 值。
  Future<String?> chat({
    String? system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 1024,
    bool jsonObject = false,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    // 从 SettingsService 读取未显式传入的参数
    final settings = SettingsService.instance;
    final url = baseUrl ?? (await settings.getApiBaseUrl())?.trim() ?? '';
    final key = apiKey ?? (await settings.getApiKey())?.trim() ?? '';
    final mdl = model ?? (await settings.getApiModel())?.trim() ?? '';

    if (url.isEmpty || key.isEmpty || mdl.isEmpty) {
      AppLog.d(_tag, '云端未配置（url/key/model 不全），跳过');
      return null;
    }

    final fullUrl = '${url.endsWith('/') ? url : '$url/'}chat/completions';

    // 构建 messages
    final messages = <Map<String, String>>[];
    if (system != null && system.isNotEmpty) {
      messages.add({'role': 'system', 'content': system});
    }
    messages.add({'role': 'user', 'content': user});

    // 构建请求体
    final body = <String, dynamic>{
      'model': mdl,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
    };
    if (jsonObject) {
      body['response_format'] = {'type': 'json_object'};
    }

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
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final msg = choices[0] as Map<String, dynamic>;
          final content = msg['message']?['content'] as String?;
          if (content != null && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
        AppLog.w(_tag, '云端返回空 content');
      } else {
        AppLog.e(_tag, '云端 HTTP ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      AppLog.e(_tag, '云端调用异常: $e');
    }
    return null;
  }

  /// 释放 HTTP 客户端资源。
  void dispose() {
    _httpClient.close();
  }
}
