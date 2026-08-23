import '../core/debug/app_log.dart';
import '../core/models/chat_message.dart';
import '../core/settings/settings_service.dart';
import 'llm_service.dart';
import 'openai_client.dart';

/// [v0.3.0] AI 服务：云端 OpenAI 兼容 API 优先 + 本地 llama 回落双引擎。
///
/// 按 [SettingsService.preferOffline] 决定尝试顺序：
/// - false（默认）：cloud → local
/// - true：local → cloud
///
/// 失败静默回落（AppLog 记每级错误），全部失败返回 null。
/// 供 知识提取 / 测验生成 / 助教 三方复用。
class AiService {
  AiService({LlmService? llm, OpenAiClient? client})
    : _llm = llm ?? LlmService.instance,
      _client = client ?? OpenAiClient();

  final LlmService _llm;
  final OpenAiClient _client;
  static const _tag = 'ai';

  /// 获取 AI 引擎按策略尝试的顺序。
  Future<List<AiEngine>> _getEngineOrder() async {
    final preferOffline = await SettingsService.instance.getPreferOffline();
    return preferOffline
        ? [AiEngine.local, AiEngine.cloud]
        : [AiEngine.cloud, AiEngine.local];
  }

  /// 调用 AI 完成文本生成，返回首个成功结果或 null。
  ///
  /// [prompt] 用户 prompt；[predictLength] 最大生成 token（默认 512，
  /// 普通问答足够；若用于知识提取等需要长输出的场景，调用方请手动传入更大的值）；
  /// [jsonObject] 云端传 response_format，本地 llama 仅在 prompt 追加约束。
  Future<AiResult?> complete(
    String prompt, {
    int predictLength = 512,
    bool jsonObject = false,
    List<ChatMessage>? history,
  }) async {
    final order = await _getEngineOrder();
    for (final engine in order) {
      final result = await _tryEngine(
        engine,
        prompt,
        predictLength,
        jsonObject,
        history,
      );
      if (result != null) return result;
    }
    return null;
  }

  /// 尝试单个引擎。
  Future<AiResult?> _tryEngine(
    AiEngine engine,
    String prompt,
    int predictLength,
    bool jsonObject,
    List<ChatMessage>? history,
  ) async {
    AppLog.d(_tag, '尝试 ${engine.label}');
    try {
      switch (engine) {
        case AiEngine.cloud:
          final text = await _client.chat(
            user: prompt,
            jsonObject: jsonObject,
            maxTokens: predictLength,
            history: history,
          );
          if (text != null && text.isNotEmpty) {
            return AiResult(text: text, engine: engine);
          }
          break;
        case AiEngine.local:
          // 本地 llama 不支持 response_format，jsonObject 时 prompt 追加约束
          var localPrompt = buildLocalPrompt(prompt, history ?? const []);
          if (jsonObject) {
            localPrompt =
                '$localPrompt\n\nOutput ONLY valid JSON, no explanation.';
          }
          if (!await _llm.ensureReady()) {
            AppLog.d(_tag, '本地 llama 未就绪，回落下一引擎');
            break;
          }
          final text = await _llm.chat(
            localPrompt,
            predictLength: predictLength,
          );
          if (text.isNotEmpty) {
            return AiResult(text: text, engine: engine);
          }
          break;
      }
    } catch (e) {
      AppLog.e(_tag, '${engine.label} 异常: $e');
    }
    return null;
  }

  /// 将同一会话的历史拼入本地单 prompt，避免云端 messages 与本地 prompt 语义漂移。
  static String buildLocalPrompt(String prompt, List<ChatMessage> history) {
    final messages = OpenAiClient.buildTextHistory(history);
    if (messages.isEmpty) return prompt;
    final historyText = messages
        .map(
          (message) =>
              '${message['role'] == 'user' ? '用户' : '助手'}：${message['content']}',
        )
        .join('\n');
    return '以下是本次会话此前的对话，请结合上下文回答当前问题。\n\n$historyText\n\n当前问题：$prompt';
  }

  /// [v0.1.52] 多模态（视觉）对话：仅云端，本地引擎不支持。
  ///
  /// [imagePaths] 本地图片路径列表；[prompt] 可选文本。
  /// 模型不支持多模态时返回固定字符串 `__MODEL_NOT_VISION__`。
  Future<String?> completeVision(
    List<String> imagePaths, {
    String prompt = '',
    int predictLength = 1024,
    List<ChatMessage>? history,
  }) async {
    if (imagePaths.isEmpty) {
      final result = await complete(
        prompt,
        predictLength: predictLength,
        history: history,
      );
      return result?.text;
    }
    final result = await _client.chatVision(
      user: prompt.isNotEmpty ? prompt : null,
      imagePaths: imagePaths,
      maxTokens: predictLength,
      history: history,
    );
    return result; // null 或 __MODEL_NOT_VISION__ 或 回答文本
  }

  /// 云端是否已配置可用。
  Future<bool> isCloudReady() => SettingsService.instance.isApiConfigured();

  /// 本地引擎是否可用；按设置允许时会自动加载默认模型。
  Future<bool> isLocalReady() async {
    try {
      return await _llm.ensureReady();
    } catch (_) {
      return false;
    }
  }
}

/// AI 引擎类型。
enum AiEngine {
  /// 云端 OpenAI 兼容 API。
  cloud('云端'),

  /// 本地 llama。
  local('本地');

  const AiEngine(this.label);
  final String label;
}

/// AI 完成结果。
class AiResult {
  const AiResult({required this.text, required this.engine});

  /// 生成的文本。
  final String text;

  /// 实际使用的引擎。
  final AiEngine engine;
}
