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
  /// [predictLength] 最大生成 token 数（默认官方 1024）。
  Future<String> chat(String prompt, {int predictLength = 1024}) async {
    final text = await _channel.invokeMethod<String>('send', {
      'prompt': prompt,
      'predictLength': predictLength,
    });
    return text ?? '';
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
