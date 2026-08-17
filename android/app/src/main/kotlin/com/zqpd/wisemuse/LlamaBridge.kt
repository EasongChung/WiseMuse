package com.zqpd.wisemuse

import android.content.Context
import android.util.Log
import com.arm.aichat.AiChat
import com.arm.aichat.InferenceEngine
import com.arm.aichat.isModelLoaded
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * [v0.1.0] llama.android 本地 LLM 推理桥（MethodChannel）。
 *
 * 封装官方 com.arm.aichat 桥（AiChat 单例 / InferenceEngine）：
 * - `init(modelPath)` 加载 GGUF 模型（等待原生库初始化完成）
 * - `isLoaded()` 是否已加载模型
 * - `send(prompt, predictLength)` 发送用户 prompt，收集 token 流后整段返回
 * - `bench(pp, tg, pl, nr)` 基准测试（prompt/生成 t/s）
 * - `unload()` 卸载模型（保留原生库）/ `destroy()` 释放全部资源
 *
 * 引擎已按「SDK_INT>=30 特性开关 + 回落云端」设计（见 docs/16），
 * 但桥本身不设门槛——由 Dart 层 llm_service 判定可用性后调用。
 */
class LlamaBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "LlamaBridge"
        private const val CHANNEL = "com.zqpd.wisemuse/llm"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var engine: InferenceEngine? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            engine?.destroy()
        } catch (_: Throwable) {
        }
        engine = null
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "init" -> initModel(call.argument<String>("modelPath"), result)
            "isLoaded" -> result.success(isLoaded())
            "send" -> sendPrompt(
                call.argument<String>("prompt"),
                call.argument<Int>("predictLength") ?: InferenceEngine.DEFAULT_PREDICT_LENGTH,
                result,
            )
            "bench" -> benchModel(
                call.argument<Int>("pp") ?: 512,
                call.argument<Int>("tg") ?: 128,
                call.argument<Int>("pl") ?: 1,
                call.argument<Int>("nr") ?: 1,
                result,
            )
            "unload" -> unload(result)
            "destroy" -> destroy(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 引擎是否在当前设备可用。判定放 Kotlin 侧（与 System.loadLibrary 同址，
     * 避免 Dart 侧版本判断漂移）。
     *
     * 判定条件：
     * 1. Android 系统版本 >= 30 (Android 11+)
     * 2. 检查 nativeLibraryDir 中是否存在 libai-chat.so（区分 Standard 标准版 与 Full 增强版）
     */
    private fun isAvailable(): Boolean {
        if (android.os.Build.VERSION.SDK_INT < 30) return false
        val libDir = appContext?.applicationInfo?.nativeLibraryDir ?: return false
        val aiChatSo = java.io.File(libDir, "libai-chat.so")
        return aiChatSo.exists()
    }

    private fun initModel(modelPath: String?, result: MethodChannel.Result) {
        if (modelPath.isNullOrEmpty()) {
            result.error("bad_arg", "modelPath 不能为空", null)
            return
        }
        scope.launch {
            try {
                val ctx = appContext ?: throw IllegalStateException("appContext 缺失")
                val eng = engine ?: AiChat.getInferenceEngine(ctx).also { engine = it }
                // 引擎是单例（AiChat.getInferenceEngine 缓存 instance）：
                // 上一次 loadModel 失败后 state 会永久落在 Error，导致后续任何 init
                // 立即短路（"state=Error" 假失败，换模型也没用）。Error 状态必须先
                // cleanUp() 复位为 Initialized 才能重试（官方实现支持此分支）。
                if (eng.state.value is InferenceEngine.State.Error) {
                    Log.w(TAG, "引擎处于 Error 状态，cleanUp() 复位后重试")
                    eng.cleanUp()
                }
                // 等待原生库初始化完成（System.loadLibrary("ai-chat") 在内部协程）。
                // 仅在 Uninitialized/Initializing（首次调用）时需要等；引擎复用后已处于
                // ModelReady 等就绪态，直接进入 loadModel——若仍用 first{Initialized} 等，
                // 单例第二次 init 永远等不到 Initialized，会 30s 虚超时误报
                // （真机实测：换模型时 state=ModelReady 却被报 init_failed 超时）。
                val cur = eng.state.value
                if (cur is InferenceEngine.State.Uninitialized ||
                    cur is InferenceEngine.State.Initializing
                ) {
                    val initialized = withTimeoutOrNull(30_000) {
                        eng.state.first { st ->
                            st is InferenceEngine.State.Initialized ||
                                st is InferenceEngine.State.Error
                        } is InferenceEngine.State.Initialized
                    }
                    if (initialized != true) {
                        val st = eng.state.value.javaClass.simpleName
                        Log.e(TAG, "引擎初始化失败或超时（state=$st）")
                        result.error("init_failed", "引擎初始化失败或超时（state=$st）", null)
                        return@launch
                    }
                }
                Log.i(TAG, "原生库已就绪（state=${eng.state.value.javaClass.simpleName}），加载模型: $modelPath")
                eng.loadModel(modelPath)
                Log.i(TAG, "模型加载完成: $modelPath")
                result.success(true)
            } catch (t: Throwable) {
                Log.e(TAG, "init 失败", t)
                result.error("init_failed", t.message ?: "引擎初始化/模型加载失败", null)
            }
        }
    }

    private fun isLoaded(): Boolean {
        val st = engine?.state?.value ?: return false
        return st.isModelLoaded
    }

    private fun sendPrompt(
        prompt: String?,
        predictLength: Int,
        result: MethodChannel.Result,
    ) {
        if (prompt.isNullOrEmpty()) {
            result.error("bad_arg", "prompt 不能为空", null)
            return
        }
        val eng = engine
        if (eng == null) {
            result.error("not_init", "引擎未初始化，先调用 init", null)
            return
        }
        scope.launch {
            try {
                val sb = StringBuilder()
                eng.sendUserPrompt(prompt, predictLength).collect { sb.append(it) }
                Log.i(TAG, "生成完成，共 ${sb.length} 字符")
                result.success(sb.toString())
            } catch (t: Throwable) {
                Log.e(TAG, "send 失败", t)
                result.error("generate_failed", t.message ?: "生成失败", null)
            }
        }
    }

    private fun benchModel(
        pp: Int,
        tg: Int,
        pl: Int,
        nr: Int,
        result: MethodChannel.Result,
    ) {
        val eng = engine
        if (eng == null) {
            result.error("not_init", "引擎未初始化，先调用 init", null)
            return
        }
        scope.launch {
            try {
                Log.i(TAG, "bench pp=$pp tg=$tg pl=$pl nr=$nr")
                result.success(eng.bench(pp, tg, pl, nr))
            } catch (t: Throwable) {
                Log.e(TAG, "bench 失败", t)
                result.error("bench_failed", t.message ?: "基准测试失败", null)
            }
        }
    }

    private fun unload(result: MethodChannel.Result) {
        try {
            engine?.cleanUp()
            result.success(true)
        } catch (t: Throwable) {
            Log.e(TAG, "unload 失败", t)
            result.error("unload_failed", t.message ?: "卸载失败", null)
        }
    }

    private fun destroy(result: MethodChannel.Result) {
        try {
            engine?.destroy()
            engine = null
            result.success(true)
        } catch (t: Throwable) {
            Log.e(TAG, "destroy 失败", t)
            result.error("destroy_failed", t.message ?: "销毁失败", null)
        }
    }
}
