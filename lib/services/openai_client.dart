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

  /// 调用云端 Embedding API，返回向量列表。失败/未配置返回 null。
  ///
  /// [inputs] 文本列表；[model] 嵌入模型名（默认 text-embedding-3-small）；
  /// [baseUrl]/[apiKey] 可显式传入覆写 settings 值。
  /// [batchSize] 每批最大输入数（OpenAI 限制 2048，默认 16 保兼容）。
  Future<List<List<double>>?> embeddings(
    List<String> inputs, {
    String? baseUrl,
    String? apiKey,
    String model = 'text-embedding-3-small',
    int batchSize = 16,
  }) async {
    if (inputs.isEmpty) return const [];
    final settings = SettingsService.instance;
    final url = baseUrl ?? (await settings.getApiBaseUrl())?.trim() ?? '';
    final key = apiKey ?? (await settings.getApiKey())?.trim() ?? '';

    if (url.isEmpty || key.isEmpty) {
      AppLog.d(_tag, 'embedding: 云端未配置（url/key 不全），跳过');
      return null;
    }

    final fullUrl = '${url.endsWith('/') ? url : '$url/'}embeddings';
    final allEmbeddings = <List<double>>[];

    // 分批处理
    for (var i = 0; i < inputs.length; i += batchSize) {
      final batch = inputs.sublist(i, (i + batchSize).clamp(0, inputs.length));
      try {
        final resp = await _httpClient
            .post(
              Uri.parse(fullUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $key',
              },
              body: jsonEncode({'model': model, 'input': batch}),
            )
            .timeout(const Duration(seconds: 60));

        if (resp.statusCode != 200) {
          AppLog.e(_tag, 'embedding HTTP ${resp.statusCode}: ${resp.body}');
          return null;
        }

        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = json['data'] as List?;
        if (data == null || data.isEmpty) {
          AppLog.w(_tag, 'embedding 返回空 data');
          return null;
        }

        // 按 index 排序确保顺序一致
        data.sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
        for (final item in data) {
          final emb = (item['embedding'] as List).cast<double>();
          allEmbeddings.add(emb);
        }
      } catch (e) {
        AppLog.e(_tag, 'embedding 调用异常: $e');
        return null;
      }
    }

    return allEmbeddings;
  }

  /// 释放 HTTP 客户端资源。
  void dispose() {
    _httpClient.close();
  }
}

/// [v2.10.0] OpenAI 兼容 embedding API 的参数封装。
class EmbeddingRequest {
  const EmbeddingRequest({
    required this.model,
    required this.input,
    this.baseUrl,
    this.apiKey,
  });

  final String model;
  final List<String> input;
  final String? baseUrl;
  final String? apiKey;
}

/// OpenAI 兼容 embedding API 响应中的向量条目。
class EmbeddingData {
  const EmbeddingData({required this.index, required this.embedding});

  final int index;
  final List<double> embedding;
}
