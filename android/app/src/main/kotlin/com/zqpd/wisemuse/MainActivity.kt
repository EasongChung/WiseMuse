package com.zqpd.wisemuse

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // [v0.1.0] 注册 Vosk 离线语音识别桥
        flutterEngine.plugins.add(VoskBridge())
    }
}
