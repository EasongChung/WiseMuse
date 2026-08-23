import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';

/// [v0.1.0] llama.android 本地 LLM 服务（MethodChannel → LlamaBridge.kt）。
///
/// 封装本地大模型推理（AiChat/InferenceEngine 官方桥）：
/// - [isAvailable] 当前设备是否可用（SDK_INT>=30，判定在 Kotlin 侧）
/// - [init] 加载 GGUF 模型
/// - [chat] 发送用户 prompt，返回完整生成文本
/// - [bench] 基准测试（pp/tg t/s）
/// - [unload] / [destroy] 释放
///
/// [v0.1.35] 改为单例，各调用方共享同一实例的加载状态。
///
/// 调用方（features 层）负责：先查 [isAvailable]，不可用则回落云端引擎。
class LlmService {
  /// 单例实例。
  static final LlmService instance = LlmService._internal();

  LlmService._internal();

  static const _channel = MethodChannel('com.zqpd.wisemuse/llm');
  bool _loaded = false;

  /// 引擎是否在当前设备可用（SDK_INT>=30；判定在 Kotlin 侧，与 loadLibrary 同址）。
  Future<bool> isAvailable() async {
    final ok = await _channel.invokeMethod<bool>('isAvailable');
    return ok ?? false;
  }

  /// 加载 GGUF 模型（[modelPath] 为模型文件路径），返回是否成功。
  Future<bool> init(String modelPath) async {
    final ok = await _channel.invokeMethod<bool>('init', {
      'modelPath': modelPath,
    });
    _loaded = ok ?? false;
    return _loaded;
  }

  /// 模型是否已加载。
  bool get isLoaded => _loaded;

  /// 发送用户 prompt，返回完整生成文本。
  ///
  /// [predictLength] 最大生成 token 数（默认 512——普通问答足够，避免无谓等待）。
  /// 若用于长文本生成（如知识提取），调用方请自行传入更大的值。
  ///
  /// 返回前依次执行：
  /// 1. 剥离 Qwen3/Qwen3.5 类模型的 thinking 思维链块（见 [_stripThinking]）
  /// 2. 清理 MiniCPM 及其他模型的特殊 token（见 [_cleanSpecialTokens]）
  Future<String> chat(String prompt, {int predictLength = 512}) async {
    final sw = Stopwatch()..start();
    final promptLen = prompt.length;
    AppLog.d(
      'llm',
      'chat 入参: predictLength=$predictLength prompt=$promptLen chars '
          'loaded=$_loaded',
    );
    final text = await _channel.invokeMethod<String>('send', {
      'prompt': prompt,
      'predictLength': predictLength,
    });
    sw.stop();
    final rawLen = (text ?? '').length;
    var result = _stripThinking(text ?? '');
    result = _cleanSpecialTokens(result);
    final outLen = result.length;
    AppLog.d(
      'llm',
      'chat 出参: ${sw.elapsedMilliseconds}ms '
          'raw=$rawLen clean=$outLen',
    );
    if (rawLen > 0 && outLen == 0) {
      final rawHead = text!.substring(0, rawLen < 80 ? rawLen : 80);
      AppLog.w('llm', 'chat 清洗后为空！raw=$rawLen raw_head="$rawHead"');
    }
    return result;
  }

  /// 剥离 Qwen3/Qwen3.5 类 hybrid reasoning 模型的 thinking（思维链）块，
  /// 并清理 MiniCPM 等模型中可能残留的特殊 token。
  ///
  /// 判定规则：
  /// - **有闭合块**（`<|im_start|>think ... <|im_end|>` 或 `<think>...</think>`）
  ///   → 整体删除，剩余即正式回答（Qwen 标准输出）。
  /// - **无闭合块且以 think/Thinking 开头**（真机实测：思考被 predictLength 截断，
  ///   输出只有英文思维链、没有 `</think>` 和正式回答）→ 返回空字符串，由调用方
  ///   提示「模型仅输出了思考过程」，而不是把思维链残片当回答展示。
  ///
  /// 注意：底层 API（ai_chat.cpp use_jinja=false）无法透传 enable_thinking=False，
  /// 故用输出后剥离兜底；实测 gemma-2b / Hy-MT2 无 thinking，不受影响。
  static String _stripThinking(String text) {
    if (text.trim().isEmpty) return text;

    var t = text;

    // 是否存在闭合 thinking 块（模型完成了思考、后面有正式回答）
    final closed =
        RegExp(r'<\|im_start\|>think[\s\S]*?<\|im_end\|>').hasMatch(t) ||
        RegExp(r'<think>[\s\S]*?</think>').hasMatch(t);

    // 删除闭合块；先删 <|im_start|>answer 角色标记（其内容即正式回答）
    t = t.replaceAll(RegExp(r'<\|im_start\|>answer'), '');
    t = t.replaceAll(RegExp(r'<\|im_start\|>think[\s\S]*?<\|im_end\|>'), '');
    t = t.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    // 清理孤立标记
    t = t.replaceAll(
      RegExp(r'<\|im_start\|>|<\|im_end\|>|<think>|</think>'),
      '',
    );
    // 清理 MiniCPM 等特殊标记
    t = _cleanSpecialTokens(t);
    t = t.trim();

    // 无闭合块但存在打开的 thinking 标记 → 思考被截断、正式回答未生成，丢弃。
    // 判据收紧：仅匹配真正的 thinking 角色标记（`<|im_start|>think`）或
    // ` ```Thinking` 代码块开头，避免误杀 MiniCPM5 等模型以普通英文
    // "Think about..." 开头的正常回复（无特殊 token 包裹）。
    final hasOpenThinkingMarker = RegExp(
      r'<\|im_start\|>think\b|```[Tt]hinking',
    ).hasMatch(t);
    if (!closed && hasOpenThinkingMarker) {
      return '';
    }

    return t.trim();
  }

  /// 清理 MiniCPM / Llama / 通用模型的特殊 token（如 `<用户>`、`<AI>`、`<s>`、`</s>`、`<reserved_*>` 等）。
  static String _cleanSpecialTokens(String text) {
    if (text.isEmpty) return text;

    var t = text;
    // 移除 MiniCPM / ChatML / Llama 系列常见特殊标记与保留 token
    t = t.replaceAll(
      RegExp(
        r'<用户>|<AI>|<s>|<\/s>|<reserved_\d+>|<\|user\|>|<\|assistant\|>|<\|system\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>',
      ),
      '',
    );
    return t;
  }

  /// 基准测试，返回 markdown 表格字符串（模型/pp/tg t/s）。
  Future<String> bench({
    int pp = 512,
    int tg = 128,
    int pl = 1,
    int nr = 1,
  }) async {
    final s = await _channel.invokeMethod<String>('bench', {
      'pp': pp,
      'tg': tg,
      'pl': pl,
      'nr': nr,
    });
    return s ?? '';
  }

  /// 卸载模型（保留原生库）。
  Future<void> unload() async {
    await _channel.invokeMethod('unload');
    _loaded = false;
  }

  /// 销毁全部资源。
  Future<void> destroy() async {
    await _channel.invokeMethod('destroy');
    _loaded = false;
  }

  /// 重置原生推理引擎实例。
  Future<void> reset() async {
    await _channel.invokeMethod('reset');
    _loaded = false;
  }
}
