package com.zqpd.wisemuse

import io.endigo.plugins.pdfviewflutter.PDFViewFactory
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
        // [v0.2.0] 注册 PDF 解析/渲染桥（PDFBox 坐标 + PdfRenderer 出图）
        flutterEngine.plugins.add(PdfBridge())
        // [v0.2.0] 注册 ML Kit 中文 OCR 桥（Bundled 离线模型）
        flutterEngine.plugins.add(OcrBridge())
        // [v0.2.0] 注册拍照/相册选取桥（系统 intent，不依赖 CAMERA 权限）
        flutterEngine.plugins.add(PickerBridge())
        // [v0.3.0] 注册 ML Kit 翻译 + 语种识别桥（standalone SDK，模型 CDN 直连，无 GMS）
        flutterEngine.plugins.add(TranslationBridge())
        // [v0.2.0] flutter_pdfview 已 vendoring 进仓库并从 pubspec 移除，其插件自动
        // 注册（GeneratedPluginRegistrant）随之失效，必须在此手工注册平台视图，
        // 否则 PDF 原文视图空白。viewType 与 lib/vendor/flutter_pdfview 的 _kViewType 一致。
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.zqpd.wisemuse/pdfview",
            PDFViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
    }
}
