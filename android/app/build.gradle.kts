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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
}
