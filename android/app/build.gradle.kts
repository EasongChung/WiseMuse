plugins {
    id("com.android.application")
    // AGP 9.0 起 Kotlin 由 Android 构建系统原生处理，不再单独应用 kotlin-android 插件。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zqpd.wisemuse"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zqpd.wisemuse"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 26（Android 8.0）：覆盖 2017+ 设备，生态最顺。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("KEYSTORE_PATH")
            if (!keystorePath.isNullOrEmpty()) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
                keyAlias = System.getenv("KEY_ALIAS") ?: ""
                keyPassword = System.getenv("KEY_PASSWORD") ?: ""
            }
        }
    }

    buildTypes {
        release {
            // [fix] 图片 OCR NPE 根因：Flutter 3.44.9 默认对 release 开启 R8 minify +
            // shrinkResources（FlutterPlugin.kt:217），会把 ML Kit bundled 中文模型的
            // 内部类/资源当死代码裁掉，recognizer.process() 运行时反射加载 NPE
            // （"Attempt to invoke virtual method ... getClass() on a null object"）。
            // 与 speak_reader 34092c2（2026-07-07）同坑同解：显式关闭 R8 混淆与资源压缩。
            // 保留 proguard-rules.pro 无害（minify 关闭时不生效），将来若重开 R8 仍兜底。
            isMinifyEnabled = false
            isShrinkResources = false

            val releaseSigning = signingConfigs.findByName("release")
            if (releaseSigning != null && releaseSigning.storeFile != null
                && releaseSigning.storeFile?.exists() == true) {
                signingConfig = releaseSigning
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Vosk 离线语音识别（Apache-2.0，自带 .so + Java API）
    implementation("com.alphacephei:vosk-android:0.3.75")
    // llama.android 官方 Java 桥（com.arm.aichat，vendored）依赖协程 Flow/StateFlow
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // [v0.2.0] PDFBox 字符坐标提取（CharBoxStripper / PdfBridge.extractTextPositions）。
    // AAR 无 Kotlin 源，AGP9 无 KGP 风险；需先 PDFBoxResourceLoader.init（见 PdfBridge）。
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // [v0.2.0] PDF 渲染视图（vendored flutter_pdfview 的 AndroidPdfViewer）。
    // 原由 flutter_pdfview 1.4.4 传递引入，现由 app 模块直接声明，版本与上游一致。
    implementation("io.github.oothp:android-pdf-viewer:3.2.0-beta05")
    // [v0.2.0] ML Kit 中文 OCR（Bundled 模型随 AAR 打包，无 GMS、离线可用）
    implementation("com.google.mlkit:text-recognition-chinese:16.0.0")
}
