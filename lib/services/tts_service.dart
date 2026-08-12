/// [v0.1.0] 语音朗读（TTS）服务抽象接口。
///
/// 跟读放音通过该接口调用底层朗读引擎（当前为系统 TextToSpeech 原生桥）。
/// 抽象接口便于后续替换实现（如在线 TTS 或本地引擎）。
abstract class TtsService {
  /// 初始化并等待引擎就绪，返回是否可用。
  Future<bool> init();

  /// 朗读 [text]，直到播放完成、被新请求打断或失败后返回。
  ///
  /// 正常收到原生 onDone 返回 true；被 [stop] 或新的 [speak] 打断、
  /// 播放失败时返回 false。
  Future<bool> speak(String text);

  /// 停止当前朗读，并使尚未完成的 [speak] 返回 false。
  ///
  /// 返回 true 表示取消屏障已经成立；返回 false 时，调用方不得继续执行
  /// 依赖“已静音”的操作（例如启动跟读录音）。
  Future<bool> stop();
}
