/// [v0.1.0] 语音朗读（TTS）服务抽象接口。
///
/// 跟读放音通过该接口调用底层朗读引擎（当前为系统 TextToSpeech 原生桥）。
/// 抽象接口便于后续替换实现（如在线 TTS 或本地引擎）。
abstract class TtsService {
  /// 初始化并等待引擎就绪，返回是否可用。
  Future<bool> init();

  /// 朗读 [text]，阻塞到播放完成或失败，返回是否播放完成。
  Future<bool> speak(String text);

  /// 停止当前朗读。
  Future<void> stop();
}
