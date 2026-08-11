import 'package:flutter/services.dart';

/// [v0.1.0] llama.android 本地 LLM 服务（MethodChannel → LlamaBridge.kt）。
///
/// 封装本地大模型推理（AiChat/InferenceEngine 官方桥）：
/// - [isAvailable] 当前设备是否可用（SDK_INT>=30，判定在 Kotlin 侧）
/// - [init] 加载 GGUF 模型
/// - [chat] 发送用户 prompt，返回完整生成文本
/// - [bench] 基准测试（pp/tg t/s）
/// - [unload] / [destroy] 释放
///
/// 调用方（features 层）负责：先查 [isAvailable]，不可用则回落云端引擎。
class LlmService {
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
  /// [predictLength] 最大生成 token 数（默认 2048——Qwen3 系 thinking 模型
  /// 思考块会占用大量 token，1024 常被思考截断导致没有正式回答）。
  ///
  /// 返回前剥离 Qwen3/Qwen3.5 类模型的 thinking 思维链块（见 [_stripThinking]），
  /// 只保留正式回答。剥离后为空说明模型把预算全花在思考上、未产出回答。
  Future<String> chat(String prompt, {int predictLength = 2048}) async {
    final text = await _channel.invokeMethod<String>('send', {
      'prompt': prompt,
      'predictLength': predictLength,
    });
    return _stripThinking(text ?? '');
  }

  /// 剥离 Qwen3/Qwen3.5 类 hybrid reasoning 模型的 thinking（思维链）块。
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
    t = t.trim();

    // 无闭合块且剩余文本仍以 think 开头 → 思考被截断、正式回答未生成
    if (!closed &&
        RegExp(
          r'^["“”\s]*(?:<\|im_start\|>)?[Tt]hink(?:ing)?[\s:：]',
        ).hasMatch(t)) {
      return '';
    }

    return t.trim();
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
}
