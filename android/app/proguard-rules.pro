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