/// [v0.1.0] 语音识别（ASR）服务抽象接口。
///
/// 跟读验证/语音听写通过该接口调用底层识别引擎（当前为 Vosk 离线）。
/// 抽象接口便于后续接入其他引擎或替换实现。
abstract class AsrService {
  /// 加载模型（[modelPath] 为含模型文件的目录），返回是否成功。
  Future<bool> init(String modelPath);

  /// 模型是否已加载。
  bool get isLoaded;

  /// 开始录音识别（异步返回启动是否成功）。
  Future<bool> start();

  /// 停止录音并返回最终识别文本（可能为空）。
  Future<String> stop();

  /// 释放资源（模型/识别器/录音）。
  Future<void> dispose();
}
