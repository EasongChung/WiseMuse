# [v0.1.0] WiseMuse release 构建 R8 保持规则
#
# Flutter 3.44.9 的 gradle 插件默认对 release 构建开启 minify/R8，
# 会把仅通过反射访问的私有字段当作死代码剥除，运行时报
# "UnsatisfiedLinkError: Can't obtain peer field ID for class com.sun.jna.Pointer"。
# 该文件存在时 Flutter 插件自动追加到 release 的 proguardFiles。

# JNA：Pointer.peer 等字段仅供内部反射/Unsafe 使用，R8 静态分析
# 看不到引用会直接删除。必须整包保留。
-keep class com.sun.jna.** { *; }
-dontwarn com.sun.jna.**

# Vosk（JNA 接口定义 + 模型 loader），一并保留以防被裁。
-keep class org.vosk.** { *; }

# llama.android 官方 Java 桥（com.arm.aichat，vendored）：
# native 方法经 System.loadLibrary("ai-chat") 动态绑定（JNI 符号名依赖类名/包名），
# 且 InferenceEngineImpl 的 external 方法用 @FastNative 反射关联，R8 可能当死代码裁掉。
# 以下规则与官方 lib/consumer-rules.pro 逐条对齐（源码 vendoring 不自带消费侧规则）。
-keep class com.arm.aichat.* { *; }
-keep class com.arm.aichat.gguf.* { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class kotlin.Metadata { *; }

# pdfbox-android：JPXFilter 反射引用可选的 JPEG2000 解码器 com.gemalto.jp2.JP2Decoder
# （存在时才启用 JPX 解码，本项目不处理 JPX 图）。R8 静态分析发现该类不在依赖里
# 会报 "Missing classes detected"，按官方建议 -dontwarn 忽略即可。
-dontwarn com.gemalto.jp2.**