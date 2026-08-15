import '../core/debug/app_log.dart';
import '../core/settings/settings_service.dart';
import 'llm_service.dart';
import 'mlkit_translation_service.dart';
import 'openai_client.dart';

/// 翻译引擎类型。
///
/// 按优先级下降排列：cloud（最高质量，优先）→ llm（强，离线）→ mlkit（轻量，离线兜底）。
enum TranslationEngineType {
  /// 云端 OpenAI 兼容 API（需网络 + API 配置，质量最高）。
  cloud,

  /// llama 本地大模型（Qwen3 等，需加载 GGUF，强但慢）。
  llm,

  /// ML Kit 翻译（standalone SDK，CDN 直连，无 GMS 依赖，快但质量一般）。
  mlkit,

  /// 自动：cloud → llm → mlkit 逐级回落。
  auto,
}

/// [v0.3.0] 翻译引擎编排：三级回落（ML Kit → llama → 云端）。
///
/// 用法：
/// ```dart
/// final result = await TranslationEngine.translate('你好', 'zh', 'en');
/// ```
///
/// 失败倒序：engine 开头的降级，静默进行，AppLog 打点记录每级错误。
/// 三级全失败时返回 null（调用方自行决定是否展示错误）。
class TranslationResult {
  /// 翻译结果文本。
  final String text;

  /// 实际使用的源语种（BCP-47 代码）。
  final String source;

  /// 目标语种（BCP-47 代码）。
  final String target;

  const TranslationResult({
    required this.text,
    required this.source,
    required this.target,
  });
}

class TranslationEngine {
  static const _tag = 'translate';

  final MlKitTranslationService _mlkit = MlKitTranslationService();
  final LlmService _llm = LlmService.instance;
  final OpenAiClient _client = OpenAiClient();

  /// 根据 [engineType] 翻译 [text] 从 [source] 到 [target]。
  ///
  /// [source]/[target] 为 BCP-47 代码（如 `zh`/`en`/`ja`）。
  /// 返回翻译文本，全部失败返回 null。
  static Future<String?> translate(
    String text, {
    required String source,
    required String target,
    TranslationEngineType engineType = TranslationEngineType.auto,
  }) async {
    return TranslationEngine()._translate(text, source, target, engineType);
  }

  /// 按设置页配置翻译 [text]：源语种为 `auto` 时先用 ML Kit 自动识别，
  /// 识别失败（`und`）或未知时兜底 `zh`。
  ///
  /// 返回 [TranslationResult] 包含译文文本与实际使用的源/目标语种。
  /// 三级全部失败时返回 null。
  static Future<TranslationResult?> translateWithSettings(String text) async {
    return TranslationEngine()._translateWithSettings(text);
  }

  Future<TranslationResult?> _translateWithSettings(String text) async {
    if (text.trim().isEmpty) return null;

    final settings = SettingsService.instance;
    var source = await settings.getTranslationSource();
    final target = await settings.getTranslationTarget();

    // auto 源语种识别
    if (source == 'auto') {
      try {
        final detected = await _mlkit.identifyLanguage(text);
        if (detected != 'und' && detected.isNotEmpty) {
          source = detected;
        } else {
          source = 'zh';
        }
      } catch (e) {
        AppLog.w(_tag, '语种识别失败，兜底 zh: $e');
        source = 'zh';
      }
    }

    final result = await _translate(
      text,
      source,
      target,
      TranslationEngineType.auto,
    );
    if (result == null) return null;
    return TranslationResult(text: result, source: source, target: target);
  }

  Future<String?> _translate(
    String text,
    String source,
    String target,
    TranslationEngineType engineType,
  ) async {
    if (text.trim().isEmpty) return null;

    // 按引擎类型尝试
    switch (engineType) {
      case TranslationEngineType.mlkit:
        return _tryMlkit(text, source, target);
      case TranslationEngineType.llm:
        return _tryLlm(text, source, target);
      case TranslationEngineType.cloud:
        return _tryCloud(text, source, target);
      case TranslationEngineType.auto:
        return _tryAuto(text, source, target);
    }
  }

  /// 三级自动回落：云端 → llama → ML Kit。
  Future<String?> _tryAuto(String text, String source, String target) async {
    // 1) 云端（质量最高）
    final cloud = await _tryCloud(text, source, target);
    if (cloud != null) return cloud;

    // 2) llama 本地模型（离线强语义）
    final llm = await _tryLlm(text, source, target);
    if (llm != null) return llm;

    // 3) ML Kit（极轻量离线兜底）
    return _tryMlkit(text, source, target);
  }

  /// ML Kit 翻译（快，离线优先）。
  Future<String?> _tryMlkit(String text, String source, String target) async {
    AppLog.d(_tag, '尝试 ML Kit 翻译');
    try {
      final result = await _mlkit.translate(
        text: text,
        source: source,
        target: target,
      );
      if (result != null) {
        AppLog.d(_tag, 'ML Kit 翻译成功');
        return result;
      }
    } catch (e) {
      AppLog.e(_tag, 'ML Kit 翻译异常: $e');
    }
    return null;
  }

  /// llama 本地 LLM 翻译（需模型已加载；未加载时跳过）。
  Future<String?> _tryLlm(String text, String source, String target) async {
    AppLog.d(_tag, '尝试 llama 翻译');
    try {
      final available = await _llm.isAvailable();
      if (!available) {
        AppLog.d(_tag, 'llama 不可用（SDK 版本不足），跳过');
        return null;
      }
      if (!_llm.isLoaded) {
        AppLog.d(_tag, 'llama 未加载模型，跳过');
        return null;
      }
      final prompt = _buildLlmPrompt(text, source, target);
      final result = await _llm.chat(prompt, predictLength: 512);
      if (result.isNotEmpty) {
        AppLog.d(_tag, 'llama 翻译成功');
        return result;
      }
    } catch (e) {
      AppLog.e(_tag, 'llama 翻译异常: $e');
    }
    return null;
  }

  /// 构造 llama 翻译 prompt。
  String _buildLlmPrompt(String text, String source, String target) {
    final src = _langName(source);
    final tgt = _langName(target);
    return 'Translate the following $src text to $tgt. Output only the translation, no explanation.\n\n$text';
  }

  /// 云端 OpenAI 兼容 API 翻译（需在设置页配好 API 参数）。
  Future<String?> _tryCloud(String text, String source, String target) async {
    AppLog.d(_tag, '尝试云端翻译');
    final src = _langName(source);
    final tgt = _langName(target);
    final result = await _client.chat(
      system: 'You are a translation engine.',
      user:
          'Translate the following $src text to $tgt. Output only the translation, no explanation.\n\n$text',
    );
    if (result != null) {
      AppLog.d(_tag, '云端翻译成功');
    }
    return result;
  }

  /// BCP-47 语言代码 → 英文名称（供 LLM prompt 使用）。
  String _langName(String code) {
    switch (code) {
      case 'zh':
        return 'Chinese';
      case 'en':
        return 'English';
      case 'ja':
        return 'Japanese';
      case 'ko':
        return 'Korean';
      case 'fr':
        return 'French';
      case 'de':
        return 'German';
      case 'es':
        return 'Spanish';
      case 'ru':
        return 'Russian';
      default:
        return code;
    }
  }
}
