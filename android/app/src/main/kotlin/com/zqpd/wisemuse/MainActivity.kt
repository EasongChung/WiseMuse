package com.zqpd.wisemuse

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // [v0.1.0] 注册 Vosk 离线语音识别桥
        flutterEngine.plugins.add(VoskBridge())
        // [v0.1.0] 注册系统 TextToSpeech 朗读桥
        flutterEngine.plugins.add(TtsBridge())
        // [v0.1.0] 注册 llama.android 本地 LLM 推理桥（AiChat 单例懒加载，init 才初始化）
        flutterEngine.plugins.add(LlamaBridge())
    }
}
